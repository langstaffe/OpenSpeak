package httpapi

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/gorilla/websocket"

	"openspeak/internal/auth"
	"openspeak/internal/config"
	"openspeak/internal/filenode"
	"openspeak/internal/realtime"
	"openspeak/internal/store"
)

type tlsCandidate struct {
	ExpiresAt time.Time
	rollback  func()
	commit    func() error
}

type pendingTLSApply struct {
	Token             string
	CertificateType   string
	Identifier        string
	ExpiresAt         time.Time
	RequestedByUserID string
	Previous          store.OSServer
	rollback          func()
	commit            func() error
}

type pendingEncryptionDowngrade struct {
	Token             string
	ServerID          string
	RequestedByUserID string
	PlainURL          string
	ExpiresAt         time.Time
}

type tlsDisableError struct {
	status int
	code   string
	err    error
}

func (e *tlsDisableError) Error() string { return e.err.Error() }

func (s *Server) recordTLSFailure(ctx context.Context, previous store.OSServer, certificateType, identifier, message string) {
	if previous.TLSStatus == "active" || previous.TLSStatus == "discovery" {
		_, _ = s.repo.UpdateServerTLS(ctx, previous.ID, previous.TLSCertificateType, previous.TLSIdentifier, previous.TLSStatus, message, previous.TLSExpiresAt, nil)
		return
	}
	_, _ = s.repo.UpdateServerTLS(ctx, previous.ID, certificateType, identifier, "error", message, nil, nil)
}

var domainLabelPattern = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)

var nonPublicPrefixes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"), netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("192.0.0.0/24"), netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"), netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"), netip.MustParsePrefix("224.0.0.0/4"),
	netip.MustParsePrefix("240.0.0.0/4"), netip.MustParsePrefix("2001:db8::/32"),
}

func normalizeTLSIdentifier(certificateType, value string) (string, error) {
	certificateType = strings.ToLower(strings.TrimSpace(certificateType))
	value = strings.ToLower(strings.TrimSpace(strings.TrimSuffix(value, ".")))
	switch certificateType {
	case "ip":
		addr, err := netip.ParseAddr(value)
		if err != nil || !isPublicIP(addr) {
			return "", errors.New("IP 证书只能使用固定、可公开访问的公网 IP")
		}
		return addr.String(), nil
	case "domain":
		if len(value) == 0 || len(value) > 253 || net.ParseIP(value) != nil {
			return "", errors.New("请输入有效的公网域名")
		}
		for _, label := range strings.Split(value, ".") {
			if !domainLabelPattern.MatchString(label) {
				return "", errors.New("请输入有效的公网域名")
			}
		}
		return value, nil
	default:
		return "", errors.New("certificate_type 必须是 domain 或 ip")
	}
}

func isPublicIP(addr netip.Addr) bool {
	if !addr.IsValid() || !addr.IsGlobalUnicast() || addr.IsPrivate() || addr.IsLoopback() || addr.IsLinkLocalUnicast() || addr.IsUnspecified() {
		return false
	}
	for _, prefix := range nonPublicPrefixes {
		if prefix.Contains(addr) {
			return false
		}
	}
	return true
}

func (s *Server) applyTLS(ctx context.Context, server store.OSServer, certificateType, identifier string, observedPublicIP netip.Addr, verifyLocalLiveKit bool) (tlsCandidate, error) {
	identifier, err := normalizeTLSIdentifier(certificateType, identifier)
	if err != nil {
		return tlsCandidate{}, err
	}
	currentPublicIPs := make([]netip.Addr, 0, 3)
	if observedPublicIP.IsValid() {
		currentPublicIPs = append(currentPublicIPs, observedPublicIP)
	}
	publicIPCtx, cancelPublicIP := context.WithTimeout(ctx, 10*time.Second)
	detectedPublicIPs, detectErr := detectPublicIPs(publicIPCtx)
	cancelPublicIP()
	if detectErr != nil && len(currentPublicIPs) == 0 {
		return tlsCandidate{}, fmt.Errorf("无法检测当前服务器公网 IP: %w", detectErr)
	}
	for _, address := range detectedPublicIPs {
		if !hasMatchingIP(currentPublicIPs, []netip.Addr{address}) {
			currentPublicIPs = append(currentPublicIPs, address)
		}
	}
	if certificateType == "domain" {
		lookupCtx, cancelLookup := context.WithTimeout(ctx, 10*time.Second)
		addresses, err := net.DefaultResolver.LookupNetIP(lookupCtx, "ip", identifier)
		cancelLookup()
		if err != nil || len(addresses) == 0 {
			return tlsCandidate{}, errors.New("域名尚未解析到公网 IP")
		}
		public := false
		for _, address := range addresses {
			public = public || isPublicIP(address)
		}
		if !public {
			return tlsCandidate{}, errors.New("域名没有解析到公网 IP")
		}
		if !hasMatchingIP(addresses, currentPublicIPs) {
			return tlsCandidate{}, fmt.Errorf("域名没有解析到当前服务器公网 IP %s", joinIPs(currentPublicIPs))
		}
	} else if !hasMatchingIP([]netip.Addr{netip.MustParseAddr(identifier)}, currentPublicIPs) {
		return tlsCandidate{}, fmt.Errorf("输入的 IP 与当前服务器公网 IP %s 不一致", joinIPs(currentPublicIPs))
	}
	clockCtx, cancelClock := context.WithTimeout(ctx, 10*time.Second)
	err = checkSystemClock(clockCtx)
	cancelClock()
	if err != nil {
		return tlsCandidate{}, err
	}
	probeToken, err := auth.RandomToken(24)
	if err != nil {
		return tlsCandidate{}, err
	}
	s.tlsProbeToken.Store(probeToken)
	defer s.tlsProbeToken.Store("")

	adminURL := strings.TrimRight(s.cfg.TLS.CaddyAdminURL, "/")
	oldConfig, err := caddyRequest(ctx, http.MethodGet, adminURL, "/config/", "", nil)
	if err != nil {
		return tlsCandidate{}, fmt.Errorf("无法连接本机 Caddy 管理接口: %w", err)
	}
	oldFile, oldFileErr := os.ReadFile(s.cfg.TLS.CaddyConfigPath)
	oldFileExists := oldFileErr == nil
	if oldFileErr != nil && !errors.Is(oldFileErr, os.ErrNotExist) && strings.TrimSpace(s.cfg.TLS.CaddyConfigPath) != "" {
		return tlsCandidate{}, fmt.Errorf("无法读取当前 Caddy 配置: %w", oldFileErr)
	}
	finalCaddyfile := buildCaddyfile(certificateType, identifier, s.cfg.TLS.BackendUpstream, s.cfg.TLS.LiveKitUpstream, s.cfg.TLS.PlainPublicPort, s.cfg.TLS.SecurePublicPort)
	candidateCaddyfile := finalCaddyfile
	if (server.TLSStatus == "active" || server.TLSStatus == "discovery") && server.TLSIdentifier != "" && server.TLSIdentifier != identifier {
		oldSite := buildTLSSite(server.TLSCertificateType, server.TLSIdentifier, s.cfg.TLS.BackendUpstream, s.cfg.TLS.LiveKitUpstream, s.cfg.TLS.SecurePublicPort)
		candidateCaddyfile += oldSite
		finalCaddyfile += oldSite
	}
	if _, err := caddyRequest(ctx, http.MethodPost, adminURL, "/load", "text/caddyfile", []byte(candidateCaddyfile)); err != nil {
		return tlsCandidate{}, fmt.Errorf("Caddy 无法加载 TLS 配置: %w", err)
	}
	rollback := func() {
		_, _ = caddyRequest(context.Background(), http.MethodPost, adminURL, "/load", "application/json", oldConfig)
		if strings.TrimSpace(s.cfg.TLS.CaddyConfigPath) != "" {
			if oldFileExists {
				_ = writeTLSConfigFile(s.cfg.TLS.CaddyConfigPath, oldFile)
			} else {
				_ = os.Remove(s.cfg.TLS.CaddyConfigPath)
			}
		}
	}

	verifyCtx, cancel := context.WithTimeout(ctx, s.cfg.TLS.ApplyTimeout)
	defer cancel()
	var lastErr error
	for verifyCtx.Err() == nil {
		expiresAt, err := s.verifyTLS(verifyCtx, identifier, verifyLocalLiveKit, probeToken)
		if err == nil {
			return tlsCandidate{
				ExpiresAt: expiresAt,
				rollback:  rollback,
				commit: func() error {
					if _, err := caddyRequest(context.Background(), http.MethodPost, adminURL, "/load", "text/caddyfile", []byte(finalCaddyfile)); err != nil {
						return err
					}
					return writeTLSConfigFile(s.cfg.TLS.CaddyConfigPath, []byte(finalCaddyfile))
				},
			}, nil
		}
		lastErr = err
		select {
		case <-verifyCtx.Done():
		case <-time.After(2 * time.Second):
		}
	}
	rollback()
	return tlsCandidate{}, fmt.Errorf("HTTPS/WSS 自检失败，已恢复原配置: %w", lastErr)
}

func checkSystemClock(ctx context.Context) error {
	request, _ := http.NewRequestWithContext(ctx, http.MethodHead, "https://acme-v02.api.letsencrypt.org/directory", nil)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return fmt.Errorf("无法连接 ACME 服务: %w", err)
	}
	response.Body.Close()
	serverTime, err := http.ParseTime(response.Header.Get("Date"))
	if err != nil {
		return errors.New("ACME 服务没有返回可验证的时间")
	}
	difference := time.Since(serverTime)
	if difference < 0 {
		difference = -difference
	}
	if difference > 5*time.Minute {
		return errors.New("服务器系统时间误差超过 5 分钟，请先启用时间同步")
	}
	return nil
}

func fetchPublicIP(ctx context.Context, endpoint string) (netip.Addr, error) {
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	response, err := (&http.Client{Timeout: 10 * time.Second}).Do(request)
	if err != nil {
		return netip.Addr{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return netip.Addr{}, fmt.Errorf("public IP service returned HTTP %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 128))
	if err != nil {
		return netip.Addr{}, err
	}
	address, err := netip.ParseAddr(strings.TrimSpace(string(data)))
	if err != nil || !isPublicIP(address) {
		return netip.Addr{}, errors.New("public IP service returned an invalid address")
	}
	return address, nil
}

func detectPublicIPs(ctx context.Context) ([]netip.Addr, error) {
	type result struct {
		index   int
		address netip.Addr
		err     error
	}
	endpoints := []string{"https://api.ipify.org", "https://api6.ipify.org"}
	results := make(chan result, len(endpoints))
	for index, endpoint := range endpoints {
		go func() {
			address, err := fetchPublicIP(ctx, endpoint)
			results <- result{index: index, address: address, err: err}
		}()
	}
	ordered := make([]netip.Addr, len(endpoints))
	var failures []error
	for range endpoints {
		result := <-results
		if result.err != nil {
			failures = append(failures, result.err)
			continue
		}
		ordered[result.index] = result.address
	}
	addresses := make([]netip.Addr, 0, len(ordered))
	for _, address := range ordered {
		if address.IsValid() && !hasMatchingIP(addresses, []netip.Addr{address}) {
			addresses = append(addresses, address)
		}
	}
	if len(addresses) == 0 {
		return nil, errors.Join(failures...)
	}
	return addresses, nil
}

func detectPublicIP(ctx context.Context) (netip.Addr, error) {
	addresses, err := detectPublicIPs(ctx)
	if err != nil {
		return netip.Addr{}, err
	}
	return addresses[0], nil
}

func publicIPFromHost(hostPort string) (netip.Addr, bool) {
	host := strings.TrimSpace(hostPort)
	if parsedHost, _, err := net.SplitHostPort(host); err == nil {
		host = parsedHost
	} else {
		host = strings.Trim(host, "[]")
	}
	address, err := netip.ParseAddr(host)
	return address, err == nil && isPublicIP(address)
}

func resolvePublicIPFromHost(ctx context.Context, hostPort string) (netip.Addr, bool) {
	if address, ok := publicIPFromHost(hostPort); ok {
		return address, true
	}
	host := strings.TrimSpace(hostPort)
	if parsedHost, _, err := net.SplitHostPort(host); err == nil {
		host = parsedHost
	} else {
		host = strings.Trim(host, "[]")
	}
	if host == "" || net.ParseIP(host) != nil {
		return netip.Addr{}, false
	}
	addresses, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return netip.Addr{}, false
	}
	for _, wantIPv4 := range []bool{true, false} {
		for _, address := range addresses {
			if address.Is4() == wantIPv4 && isPublicIP(address) {
				return address, true
			}
		}
	}
	return netip.Addr{}, false
}

func hasMatchingIP(left, right []netip.Addr) bool {
	for _, a := range left {
		for _, b := range right {
			if a == b {
				return true
			}
		}
	}
	return false
}

func joinIPs(addresses []netip.Addr) string {
	values := make([]string, 0, len(addresses))
	for _, address := range addresses {
		values = append(values, address.String())
	}
	return strings.Join(values, " / ")
}

func conflictingTLSIdentifier(servers []store.OSServer, serverID, identifier string) string {
	for _, server := range servers {
		if server.ID != serverID && (server.TLSStatus == "active" || server.TLSStatus == "discovery") && server.TLSIdentifier != identifier {
			return server.TLSIdentifier
		}
	}
	return ""
}

func (s *Server) RunTLSMonitor(ctx context.Context) {
	check := func() {
		servers, err := s.repo.ListServers(ctx)
		if err != nil {
			return
		}
		s.tlsApplyMu.Lock()
		syncErr := s.syncTLSGateway(ctx, servers)
		s.tlsApplyMu.Unlock()
		if syncErr != nil {
			slog.Error("TLS gateway reconciliation failed", "error", syncErr)
		}
		for _, server := range servers {
			if server.TLSStatus != "active" || server.TLSIdentifier == "" {
				continue
			}
			checkCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
			var verifyErr error
			if node, err := s.repo.SelectMediaNode(checkCtx, server.ID); err == nil {
				if !s.isLocalLiveKitNode(node, server.TLSIdentifier) {
					verifyErr = checkSecureService(checkCtx, node.LiveKitURL, "")
				}
			} else if !errors.Is(err, store.ErrNotFound) {
				verifyErr = err
			}
			var expiresAt time.Time
			if verifyErr == nil {
				expiresAt, verifyErr = s.verifyTLS(checkCtx, server.TLSIdentifier, true, "")
			}
			cancel()
			if verifyErr == nil {
				_, _ = s.repo.UpdateServerTLS(ctx, server.ID, server.TLSCertificateType, server.TLSIdentifier, "active", "", &expiresAt, nil)
			} else {
				_, _ = s.repo.UpdateServerTLS(ctx, server.ID, server.TLSCertificateType, server.TLSIdentifier, "active", verifyErr.Error(), server.TLSExpiresAt, nil)
			}
		}
	}
	select {
	case <-ctx.Done():
		return
	case <-time.After(5 * time.Second):
		check()
	}
	ticker := time.NewTicker(6 * time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			check()
		}
	}
}

func (s *Server) syncTLSGateway(ctx context.Context, servers []store.OSServer) error {
	var gateway *store.OSServer
	active := false
	for index := range servers {
		server := &servers[index]
		if server.TLSIdentifier == "" || (server.TLSStatus != "active" && server.TLSStatus != "discovery") {
			continue
		}
		if gateway == nil || server.TLSStatus == "active" {
			gateway = server
			active = server.TLSStatus == "active"
		}
		if active {
			break
		}
	}
	if gateway == nil {
		return nil
	}
	secureURL := secureServerURL(gateway.TLSIdentifier, s.cfg.TLS.SecurePublicPort)
	current, err := os.ReadFile(s.cfg.TLS.CaddyConfigPath)
	if err == nil && bytes.Contains(current, []byte(secureURL+" {")) && bytes.Contains(current, []byte("disable_tlsalpn_challenge")) {
		return nil
	}
	var expected string
	if active {
		expected = buildCaddyfile(gateway.TLSCertificateType, gateway.TLSIdentifier, s.cfg.TLS.BackendUpstream, s.cfg.TLS.LiveKitUpstream, s.cfg.TLS.PlainPublicPort, s.cfg.TLS.SecurePublicPort)
	} else {
		expected = buildPlainCaddyfile(gateway.TLSCertificateType, gateway.TLSIdentifier, s.cfg.TLS.BackendUpstream, s.cfg.TLS.LiveKitUpstream, s.cfg.TLS.PlainPublicPort, s.cfg.TLS.SecurePublicPort)
	}
	adminURL := strings.TrimRight(s.cfg.TLS.CaddyAdminURL, "/")
	if _, err := caddyRequest(ctx, http.MethodPost, adminURL, "/load", "text/caddyfile", []byte(expected)); err != nil {
		return err
	}
	return writeTLSConfigFile(s.cfg.TLS.CaddyConfigPath, []byte(expected))
}

func caddyRenewalAt(caddyConfigPath, identifier string) *time.Time {
	if strings.TrimSpace(caddyConfigPath) == "" || strings.TrimSpace(identifier) == "" {
		return nil
	}
	storageRoot := filepath.Join(filepath.Dir(filepath.Dir(caddyConfigPath)), ".local", "share", "caddy", "certificates")
	metadataFiles, _ := filepath.Glob(filepath.Join(storageRoot, "*", identifier, identifier+".json"))
	var latest *time.Time
	for _, metadataFile := range metadataFiles {
		data, err := os.ReadFile(metadataFile)
		if err != nil {
			continue
		}
		var metadata struct {
			IssuerData struct {
				RenewalInfo struct {
					SelectedTime time.Time `json:"_selectedTime"`
				} `json:"renewal_info"`
			} `json:"issuer_data"`
		}
		if json.Unmarshal(data, &metadata) != nil || metadata.IssuerData.RenewalInfo.SelectedTime.IsZero() {
			continue
		}
		selected := metadata.IssuerData.RenewalInfo.SelectedTime.UTC()
		if latest == nil || selected.After(*latest) {
			latest = &selected
		}
	}
	return latest
}

func writeTLSConfigFile(path string, data []byte) error {
	if strings.TrimSpace(path) == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".Caddyfile-*")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer os.Remove(name)
	if err := temporary.Chmod(0o640); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}

func buildCaddyfile(certificateType, identifier, backend, livekit string, plainPort, securePort int) string {
	config := caddyGlobalOptions(certificateType, identifier)
	config += buildTLSSite(certificateType, identifier, backend, livekit, securePort)
	if !strings.HasSuffix(backend, fmt.Sprintf(":%d", plainPort)) {
		config += fmt.Sprintf("\nhttp://:%d {\n\treverse_proxy %s\n}\n", plainPort, backend)
	}
	return config
}

func buildPlainCaddyfile(certificateType, identifier, backend, livekit string, plainPort, securePort int) string {
	config := caddyGlobalOptions(certificateType, identifier)
	config += buildTLSDiscoverySite(certificateType, identifier, backend, securePort)
	if !upstreamUsesPort(backend, plainPort) {
		config += fmt.Sprintf("\nhttp://:%d {\n\treverse_proxy /rtc* %s\n\treverse_proxy %s\n}\n", plainPort, livekit, backend)
	}
	return config
}

// DisableTLSFromHost is the root-only recovery path used by openspeakctl when
// an expired certificate prevents the normal owner-confirmed downgrade flow.
func DisableTLSFromHost(ctx context.Context, cfg config.Config, repo Repository, serverID string) (store.OSServer, string, error) {
	server, err := repo.GetServer(ctx, serverID)
	if err != nil {
		return store.OSServer{}, "", err
	}
	if !canDisableTLS(server) {
		return store.OSServer{}, "", errors.New("server is not using active TLS")
	}
	servers, err := repo.ListServers(ctx)
	if err != nil {
		return store.OSServer{}, "", err
	}
	for _, other := range servers {
		if other.ID != serverID && other.TLSStatus == "active" {
			return store.OSServer{}, "", errors.New("another server still uses the shared TLS gateway")
		}
	}
	return disableServerTLS(ctx, cfg.TLS, repo, server)
}

func canDisableTLS(server store.OSServer) bool {
	return server.TLSStatus == "active" &&
		(server.EncryptionMode == "transport" || server.EncryptionMode == "e2ee")
}

func disableServerTLS(ctx context.Context, cfg config.TLSConfig, repo Repository, server store.OSServer) (store.OSServer, string, error) {
	adminURL := strings.TrimRight(cfg.CaddyAdminURL, "/")
	oldConfig, err := caddyRequest(ctx, http.MethodGet, adminURL, "/config/", "", nil)
	if err != nil {
		return store.OSServer{}, "", &tlsDisableError{status: http.StatusBadGateway, code: "caddy_unavailable", err: fmt.Errorf("无法连接本机 Caddy 管理接口: %w", err)}
	}
	oldFile, oldFileErr := os.ReadFile(cfg.CaddyConfigPath)
	if oldFileErr != nil && !errors.Is(oldFileErr, os.ErrNotExist) && strings.TrimSpace(cfg.CaddyConfigPath) != "" {
		return store.OSServer{}, "", &tlsDisableError{status: http.StatusInternalServerError, code: "caddy_config_unreadable", err: fmt.Errorf("无法读取当前 Caddy 配置: %w", oldFileErr)}
	}
	plainConfig := []byte(buildPlainCaddyfile(server.TLSCertificateType, server.TLSIdentifier, cfg.BackendUpstream, cfg.LiveKitUpstream, cfg.PlainPublicPort, cfg.SecurePublicPort))
	if _, err := caddyRequest(ctx, http.MethodPost, adminURL, "/load", "text/caddyfile", plainConfig); err != nil {
		return store.OSServer{}, "", &tlsDisableError{status: http.StatusBadGateway, code: "downgrade_apply_failed", err: fmt.Errorf("Caddy 无法加载 HTTP 配置: %w", err)}
	}
	rollback := func() {
		_, _ = caddyRequest(context.Background(), http.MethodPost, adminURL, "/load", "application/json", oldConfig)
		if oldFileErr == nil {
			_ = writeTLSConfigFile(cfg.CaddyConfigPath, oldFile)
		} else if errors.Is(oldFileErr, os.ErrNotExist) {
			_ = os.Remove(cfg.CaddyConfigPath)
		}
	}
	if err := writeTLSConfigFile(cfg.CaddyConfigPath, plainConfig); err != nil {
		rollback()
		return store.OSServer{}, "", &tlsDisableError{status: http.StatusInternalServerError, code: "downgrade_commit_failed", err: fmt.Errorf("无法持久化 HTTP 网关配置: %w", err)}
	}
	mode := "none"
	updated, err := repo.UpdateServerTLS(ctx, server.ID, server.TLSCertificateType, server.TLSIdentifier, "discovery", "", server.TLSExpiresAt, &mode)
	if err != nil {
		rollback()
		return store.OSServer{}, "", err
	}
	return updated, plainServerURL(server.TLSIdentifier, cfg.PlainPublicPort), nil
}

func buildTLSDiscoverySite(certificateType, identifier, backend string, securePort int) string {
	return fmt.Sprintf("%s {%s\n\treverse_proxy %s\n}\n", secureServerURL(identifier, securePort), caddyTLSBlock(certificateType), backend)
}

func plainServerURL(identifier string, port int) string {
	return fmt.Sprintf("http://%s:%d", tlsURLHost(identifier), port)
}

func plainLiveKitURL(identifier, upstream string) string {
	_, port, err := net.SplitHostPort(upstream)
	if err != nil || port == "" {
		return ""
	}
	return fmt.Sprintf("ws://%s:%s", tlsURLHost(identifier), port)
}

func upstreamUsesPort(upstream string, port int) bool {
	_, value, err := net.SplitHostPort(upstream)
	return err == nil && value == fmt.Sprint(port)
}

func buildTLSSite(certificateType, identifier, backend, livekit string, securePort int) string {
	return fmt.Sprintf(`%s {%s
	reverse_proxy /rtc* %s
	reverse_proxy %s
}
`, secureServerURL(identifier, securePort), caddyTLSBlock(certificateType), livekit, backend)
}

func caddyGlobalOptions(certificateType, identifier string) string {
	config := "{\n\tauto_https disable_redirects\n"
	if certificateType == "ip" {
		config += fmt.Sprintf("\tdefault_sni %s\n", identifier)
	}
	return config + "}\n\n"
}

func caddyTLSBlock(certificateType string) string {
	profile := ""
	if certificateType == "ip" {
		profile = "\n\t\t\tprofile shortlived"
	}
	return "\n\ttls {\n\t\tissuer acme {\n\t\t\tdisable_tlsalpn_challenge" + profile + "\n\t\t}\n\t}\n"
}

func (s *Server) activeTLSURL() string {
	value, _ := s.tlsSecureURL.Load().(string)
	return value
}

func canonicalTLSHost(requestHost, secureURL string) bool {
	expected, err := url.Parse(secureURL)
	if err != nil || expected.Hostname() == "" {
		return false
	}
	host := requestHost
	if parsedHost, _, splitErr := net.SplitHostPort(requestHost); splitErr == nil {
		host = parsedHost
	} else {
		host = strings.Trim(requestHost, "[]")
	}
	return strings.EqualFold(host, expected.Hostname())
}

func requestMatchesURL(r *http.Request, expectedURL string) bool {
	expected, err := url.Parse(expectedURL)
	if err != nil || expected.Hostname() == "" {
		return false
	}
	host := r.Host
	requestPort := ""
	if parsedHost, parsedPort, splitErr := net.SplitHostPort(r.Host); splitErr == nil {
		host, requestPort = parsedHost, parsedPort
	} else {
		host = strings.Trim(r.Host, "[]")
	}
	expectedPort := expected.Port()
	if expectedPort == "" {
		if expected.Scheme == "https" {
			expectedPort = "443"
		} else if expected.Scheme == "http" {
			expectedPort = "80"
		}
	}
	if requestPort == "" {
		if requestIsSecure(r) {
			requestPort = "443"
		} else {
			requestPort = "80"
		}
	}
	return strings.EqualFold(host, expected.Hostname()) && requestPort == expectedPort
}

func tlsURLHost(identifier string) string {
	if strings.Contains(identifier, ":") {
		return "[" + identifier + "]"
	}
	return identifier
}

func secureServerURL(identifier string, port int) string {
	return fmt.Sprintf("https://%s:%d", tlsURLHost(identifier), port)
}

func secureLiveKitURL(identifier string, port int) string {
	return fmt.Sprintf("wss://%s:%d", tlsURLHost(identifier), port)
}

func caddyRequest(ctx context.Context, method, adminURL, path, contentType string, body []byte) ([]byte, error) {
	parsed, err := url.Parse(adminURL)
	if err != nil {
		return nil, err
	}
	target := strings.TrimRight(adminURL, "/") + path
	client := http.DefaultClient
	var transport *http.Transport
	if parsed.Scheme == "unix" {
		if parsed.Path == "" {
			return nil, errors.New("Caddy admin unix socket path is empty")
		}
		transport = &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", parsed.Path)
		}}
		defer transport.CloseIdleConnections()
		client = &http.Client{Transport: transport}
		target = "http://localhost" + path
	}
	req, err := http.NewRequestWithContext(ctx, method, target, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	response, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %d: %s", response.StatusCode, strings.TrimSpace(string(data)))
	}
	return data, nil
}

func (s *Server) verifyTLS(ctx context.Context, identifier string, verifyLocalLiveKit bool, probeToken string) (time.Time, error) {
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12, ServerName: identifier}
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	transport := &http.Transport{
		TLSClientConfig: tlsConfig,
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, network, s.cfg.TLS.VerifyAddr)
		},
	}
	defer transport.CloseIdleConnections()
	baseURL := secureServerURL(identifier, s.cfg.TLS.SecurePublicPort)
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/api/health", nil)
	response, err := transport.RoundTrip(request)
	if err != nil {
		return time.Time{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || response.TLS == nil || len(response.TLS.PeerCertificates) == 0 {
		return time.Time{}, fmt.Errorf("HTTPS health 返回 HTTP %d", response.StatusCode)
	}
	if verifyLocalLiveKit {
		rtcRequest, _ := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/rtc", nil)
		rtcResponse, rtcErr := transport.RoundTrip(rtcRequest)
		if rtcErr != nil {
			return time.Time{}, fmt.Errorf("LiveKit 安全信令路由自检失败: %w", rtcErr)
		}
		rtcResponse.Body.Close()
		if rtcResponse.StatusCode >= http.StatusInternalServerError {
			return time.Time{}, fmt.Errorf("LiveKit 安全信令路由返回 HTTP %d", rtcResponse.StatusCode)
		}
	}

	wsDialer := websocket.Dialer{
		TLSClientConfig: tlsConfig,
		NetDialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, network, s.cfg.TLS.VerifyAddr)
		},
	}
	wsURL := secureLiveKitURL(identifier, s.cfg.TLS.SecurePublicPort) + "/ws"
	if probeToken != "" {
		wsURL += "?tls_probe=" + url.QueryEscape(probeToken)
	}
	conn, wsResponse, wsErr := wsDialer.DialContext(ctx, wsURL, nil)
	if conn != nil {
		_ = conn.Close()
	}
	if wsResponse != nil {
		defer wsResponse.Body.Close()
	}
	if wsErr != nil && (wsResponse == nil || wsResponse.StatusCode != http.StatusUnauthorized) {
		return time.Time{}, fmt.Errorf("WSS 路由自检失败: %w", wsErr)
	}
	return response.TLS.PeerCertificates[0].NotAfter.UTC(), nil
}

func secureEndpoint(rawURL, scheme string) bool {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	return err == nil && strings.EqualFold(parsed.Scheme, scheme) && parsed.Host != ""
}

func checkSecureService(ctx context.Context, rawURL, healthPath string) error {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || parsed.Host == "" {
		return errors.New("invalid secure service URL")
	}
	if parsed.Scheme == "wss" {
		parsed.Scheme = "https"
	}
	if parsed.Scheme != "https" {
		return errors.New("secure service must use HTTPS/WSS")
	}
	if healthPath != "" {
		parsed.Path = strings.TrimRight(parsed.Path, "/") + healthPath
	}
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	response, err := (&http.Client{Timeout: 10 * time.Second}).Do(request)
	if err != nil {
		return err
	}
	response.Body.Close()
	if response.TLS == nil ||
		(healthPath != "" && (response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices)) ||
		(healthPath == "" && response.StatusCode >= http.StatusInternalServerError) {
		return fmt.Errorf("secure service returned HTTP %d", response.StatusCode)
	}
	return nil
}

func checkFileNode(ctx context.Context, baseURL, secret string) error {
	if err := checkSecureService(ctx, baseURL, "/health"); err != nil {
		return err
	}
	probeURL, err := filenode.SignedURL(baseURL, secret, filenode.Ticket{
		Operation: "get", ObjectKey: "openspeak_probe", ExpiresAt: time.Now().Add(time.Minute),
		Name: "probe", ContentType: "application/octet-stream",
	})
	if err != nil {
		return err
	}
	request, _ := http.NewRequestWithContext(ctx, http.MethodHead, probeURL, nil)
	response, err := (&http.Client{Timeout: 10 * time.Second}).Do(request)
	if err != nil {
		return err
	}
	response.Body.Close()
	if response.TLS == nil || (response.StatusCode != http.StatusNotFound && (response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices)) {
		return fmt.Errorf("file node rejected credentials with HTTP %d", response.StatusCode)
	}
	return nil
}

func (s *Server) validateNodeTransport(ctx context.Context, serverID, rawURL, scheme string) error {
	if scheme == "https" && !secureEndpoint(rawURL, scheme) {
		return errors.New("external attachment nodes require HTTPS")
	}
	server, err := s.repo.GetServer(ctx, serverID)
	if err != nil {
		return err
	}
	if server.TLSStatus == "active" && !secureEndpoint(rawURL, scheme) {
		return fmt.Errorf("transport encryption requires %s", strings.ToUpper(scheme))
	}
	return nil
}

func (s *Server) isLocalLiveKitNode(node store.MediaNode, tlsIdentifier string) bool {
	if node.APIKey != "" && node.APISecret != "" &&
		node.APIKey == s.cfg.LiveKit.APIKey && node.APISecret == s.cfg.LiveKit.APISecret {
		return true
	}
	parsed, err := url.Parse(node.LiveKitURL)
	if err != nil || parsed.Hostname() == "" {
		return false
	}
	host := strings.TrimSuffix(strings.ToLower(parsed.Hostname()), ".")
	identifier := strings.Trim(strings.TrimSuffix(strings.ToLower(tlsIdentifier), "."), "[]")
	address := net.ParseIP(host)
	localHost := host == identifier || host == "localhost" || (address != nil && address.IsLoopback())
	if !localHost {
		return false
	}
	_, upstreamPort, err := net.SplitHostPort(s.cfg.TLS.LiveKitUpstream)
	if err != nil || upstreamPort == "" {
		return false
	}
	nodePort := parsed.Port()
	if nodePort == "" {
		if parsed.Scheme == "wss" {
			nodePort = "443"
		} else {
			nodePort = "80"
		}
	}
	return nodePort == upstreamPort
}

func (s *Server) handleTLSApply(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) {
	if !s.requireNotBanned(w, r, authCtx, serverID) || !s.requireOwnerDevice(w, authCtx, serverID) {
		return
	}
	var req struct {
		CertificateType string `json:"certificate_type"`
		Identifier      string `json:"identifier"`
		ChallengeID     string `json:"challenge_id"`
		Signature       string `json:"signature"`
	}
	if !decodeJSON(w, r, &req) || !s.verifyFreshOwnerProof(w, authCtx, serverID, req.ChallengeID, req.Signature) {
		return
	}
	certificateType := strings.ToLower(strings.TrimSpace(req.CertificateType))
	identifier, err := normalizeTLSIdentifier(certificateType, req.Identifier)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_tls_identifier", err.Error())
		return
	}
	server, err := s.repo.GetServer(r.Context(), serverID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	servers, err := s.repo.ListServers(r.Context())
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if conflict := conflictingTLSIdentifier(servers, serverID, identifier); conflict != "" {
		writeError(w, http.StatusConflict, "tls_identifier_conflict", "同一 OpenSpeak 实例的所有服务器必须共用 TLS 连接地址："+conflict)
		return
	}
	fileNodes, err := s.repo.ListFileNodes(r.Context(), serverID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	for _, node := range fileNodes {
		if !secureEndpoint(node.BaseURL, "https") {
			writeError(w, http.StatusConflict, "insecure_file_node", "启用传输层加密前，所有附件节点都必须使用 HTTPS；请修改节点 "+node.Name)
			return
		}
	}
	if server.AttachmentExternalEnabled && server.AttachmentFileNodeID != nil {
		node, err := s.repo.GetFileNode(r.Context(), serverID, *server.AttachmentFileNodeID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		if err := checkFileNode(r.Context(), node.BaseURL, node.Secret); err != nil {
			writeError(w, http.StatusBadGateway, "file_node_unavailable", "外部附件节点 HTTPS 健康检查失败: "+err.Error())
			return
		}
	}
	selectedMediaNode, selectMediaNodeErr := s.repo.SelectMediaNode(r.Context(), serverID)
	selectedIsLocal := selectMediaNodeErr == nil && (s.isLocalLiveKitNode(selectedMediaNode, identifier) || s.isLocalLiveKitNode(selectedMediaNode, server.TLSIdentifier))
	if selectMediaNodeErr == nil && !selectedIsLocal {
		if !secureEndpoint(selectedMediaNode.LiveKitURL, "wss") {
			writeError(w, http.StatusConflict, "insecure_media_node", "启用传输层加密前，外部 LiveKit 节点必须使用 WSS；请修改节点 "+selectedMediaNode.Name)
			return
		}
		if err := checkSecureService(r.Context(), selectedMediaNode.LiveKitURL, ""); err != nil {
			writeError(w, http.StatusBadGateway, "media_node_unavailable", "外部 LiveKit 安全信令检查失败: "+err.Error())
			return
		}
	} else if selectMediaNodeErr != nil && !errors.Is(selectMediaNodeErr, store.ErrNotFound) {
		writeResult(w, nil, selectMediaNodeErr)
		return
	}
	mediaNodes, err := s.repo.ListMediaNodes(r.Context(), serverID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	for _, node := range mediaNodes {
		if !node.Enabled || node.Draining || (node.ID == selectedMediaNode.ID && selectedIsLocal) {
			continue
		}
		if !secureEndpoint(node.LiveKitURL, "wss") {
			writeError(w, http.StatusConflict, "insecure_media_node", "启用传输层加密前，外部 LiveKit 节点必须使用 WSS；请修改节点 "+node.Name)
			return
		}
	}

	s.tlsApplyMu.Lock()
	defer s.tlsApplyMu.Unlock()
	s.tlsPendingMu.Lock()
	changePending := s.hasPendingEncryptionChangeLocked()
	s.tlsPendingMu.Unlock()
	if changePending {
		writeError(w, http.StatusConflict, "tls_confirmation_pending", "已有证书正在等待 HTTPS 客户端确认")
		return
	}
	resolveHostCtx, cancelResolveHost := context.WithTimeout(r.Context(), 5*time.Second)
	observedPublicIP, _ := resolvePublicIPFromHost(resolveHostCtx, r.Host)
	cancelResolveHost()
	candidate, err := s.applyTLS(r.Context(), server, certificateType, identifier, observedPublicIP, true)
	if err != nil {
		s.recordTLSFailure(r.Context(), server, certificateType, identifier, err.Error())
		writeError(w, http.StatusBadGateway, "tls_apply_failed", err.Error())
		return
	}
	token, err := auth.RandomToken(32)
	if err != nil {
		candidate.rollback()
		writeResult(w, nil, err)
		return
	}
	if server.TLSStatus != "active" {
		if _, err := s.repo.UpdateServerTLS(r.Context(), serverID, certificateType, identifier, "pending", "", &candidate.ExpiresAt, nil); err != nil {
			candidate.rollback()
			writeResult(w, nil, err)
			return
		}
	}
	pending := pendingTLSApply{Token: token, CertificateType: certificateType, Identifier: identifier, ExpiresAt: candidate.ExpiresAt, RequestedByUserID: authCtx.User.ID, Previous: server, rollback: candidate.rollback, commit: candidate.commit}
	s.tlsPendingMu.Lock()
	s.tlsPending[serverID] = pending
	s.tlsPendingMu.Unlock()
	time.AfterFunc(2*time.Minute, func() { s.expirePendingTLS(serverID, token) })
	writeJSON(w, http.StatusOK, map[string]any{
		"confirmation_token": token,
		"secure_url":         secureServerURL(identifier, s.cfg.TLS.SecurePublicPort),
		"expires_at":         candidate.ExpiresAt,
		"confirm_before":     time.Now().UTC().Add(2 * time.Minute),
	})
}

func (s *Server) handleTLSPublicIP(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) {
	if !s.requireNotBanned(w, r, authCtx, serverID) || !s.requireOwnerDevice(w, authCtx, serverID) {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()
	if address, ok := resolvePublicIPFromHost(ctx, r.Host); ok {
		writeJSON(w, http.StatusOK, map[string]string{"public_ip": address.String()})
		return
	}
	address, err := detectPublicIP(ctx)
	if err != nil {
		writeError(w, http.StatusBadGateway, "public_ip_detection_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"public_ip": address.String()})
}

func (s *Server) handleTLSConfirm(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) {
	if !requestIsSecure(r) || !s.requireNotBanned(w, r, authCtx, serverID) || !s.requireOwnerDevice(w, authCtx, serverID) {
		if !requestIsSecure(r) {
			writeError(w, http.StatusUpgradeRequired, "https_required", "TLS confirmation must use HTTPS")
		}
		return
	}
	var req struct {
		ConfirmationToken string `json:"confirmation_token"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	s.tlsApplyMu.Lock()
	defer s.tlsApplyMu.Unlock()
	s.tlsPendingMu.Lock()
	pending, ok := s.tlsPending[serverID]
	if ok && pending.Token == req.ConfirmationToken && pending.RequestedByUserID == authCtx.User.ID {
		if requestMatchesURL(r, secureServerURL(pending.Identifier, s.cfg.TLS.SecurePublicPort)) {
			delete(s.tlsPending, serverID)
		} else {
			s.tlsPendingMu.Unlock()
			writeError(w, http.StatusConflict, "tls_confirmation_url_mismatch", "TLS confirmation must use the candidate HTTPS address")
			return
		}
	} else {
		ok = false
	}
	s.tlsPendingMu.Unlock()
	if !ok {
		writeError(w, http.StatusUnauthorized, "invalid_tls_confirmation", "TLS confirmation expired or is invalid")
		return
	}
	if err := pending.commit(); err != nil {
		pending.rollback()
		s.recordTLSFailure(r.Context(), pending.Previous, pending.CertificateType, pending.Identifier, "无法持久化 Caddy 配置: "+err.Error())
		writeError(w, http.StatusInternalServerError, "tls_commit_failed", "无法持久化 Caddy 配置，已恢复原配置")
		return
	}
	mode := "transport"
	updated, err := s.repo.UpdateServerTLS(r.Context(), serverID, pending.CertificateType, pending.Identifier, "active", "", &pending.ExpiresAt, &mode)
	if err != nil {
		pending.rollback()
		s.recordTLSFailure(r.Context(), pending.Previous, pending.CertificateType, pending.Identifier, err.Error())
		writeResult(w, nil, err)
		return
	}
	s.tlsRequired.Store(true)
	s.tlsSecureURL.Store(secureServerURL(pending.Identifier, s.cfg.TLS.SecurePublicPort))
	s.audit(r.Context(), serverID, authCtx.User.ID, "server.tls_enabled", pending.Identifier, map[string]string{"certificate_type": pending.CertificateType})
	writeJSON(w, http.StatusOK, updated)
	s.hub.NotifyAndDisconnectServer(serverID, realtime.Event{
		Type: "server.tls_enabled", ServerID: serverID,
		Payload: map[string]any{"secure_url": secureServerURL(pending.Identifier, s.cfg.TLS.SecurePublicPort)},
	})
}

func (s *Server) handleEncryptionDowngradeApply(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) {
	if !requestIsSecure(r) || !s.requireNotBanned(w, r, authCtx, serverID) || !s.requireOwnerDevice(w, authCtx, serverID) {
		if !requestIsSecure(r) {
			writeError(w, http.StatusUpgradeRequired, "https_required", "加密降级必须从 HTTPS 发起")
		}
		return
	}
	var req struct {
		ChallengeID string `json:"challenge_id"`
		Signature   string `json:"signature"`
	}
	if !decodeJSON(w, r, &req) || !s.verifyFreshOwnerProof(w, authCtx, serverID, req.ChallengeID, req.Signature) {
		return
	}
	s.tlsApplyMu.Lock()
	defer s.tlsApplyMu.Unlock()
	s.tlsPendingMu.Lock()
	changePending := s.hasPendingEncryptionChangeLocked()
	s.tlsPendingMu.Unlock()
	if changePending {
		writeError(w, http.StatusConflict, "encryption_change_pending", "已有加密切换正在等待客户端确认")
		return
	}
	server, err := s.repo.GetServer(r.Context(), serverID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if !canDisableTLS(server) {
		writeError(w, http.StatusConflict, "transport_mode_required", "只有正在使用传输层或端到端加密的服务器可以降级")
		return
	}
	servers, err := s.repo.ListServers(r.Context())
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	for _, other := range servers {
		if other.ID != serverID && other.TLSStatus == "active" {
			writeError(w, http.StatusConflict, "shared_tls_gateway", "同一进程仍有其他服务器使用 TLS，不能移除共享网关")
			return
		}
	}
	token, err := auth.RandomToken(32)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	plainURL := plainServerURL(server.TLSIdentifier, s.cfg.TLS.PlainPublicPort)
	pending := pendingEncryptionDowngrade{
		Token: token, ServerID: serverID, RequestedByUserID: authCtx.User.ID,
		PlainURL: plainURL, ExpiresAt: time.Now().UTC().Add(2 * time.Minute),
	}
	s.tlsPendingMu.Lock()
	s.downgradePending[token] = pending
	s.tlsPendingMu.Unlock()
	time.AfterFunc(2*time.Minute, func() {
		s.tlsPendingMu.Lock()
		delete(s.downgradePending, token)
		s.tlsPendingMu.Unlock()
	})
	writeJSON(w, http.StatusOK, map[string]any{
		"confirmation_token": token, "plain_url": plainURL, "confirm_before": pending.ExpiresAt,
	})
}

func (s *Server) handleEncryptionDowngradeConfirm(w http.ResponseWriter, r *http.Request) {
	if requestIsSecure(r) {
		writeError(w, http.StatusBadRequest, "http_required", "降级确认必须通过 HTTP 地址完成")
		return
	}
	var req struct {
		ConfirmationToken string `json:"confirmation_token"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	s.tlsApplyMu.Lock()
	defer s.tlsApplyMu.Unlock()
	s.tlsPendingMu.Lock()
	pending, ok := s.downgradePending[req.ConfirmationToken]
	if !ok || !time.Now().Before(pending.ExpiresAt) {
		ok = false
	}
	s.tlsPendingMu.Unlock()
	if !ok {
		writeError(w, http.StatusUnauthorized, "invalid_downgrade_confirmation", "降级确认已过期或无效")
		return
	}
	if !requestMatchesURL(r, pending.PlainURL) {
		writeError(w, http.StatusConflict, "downgrade_confirmation_url_mismatch", "降级确认必须通过服务器返回的 HTTP 地址完成")
		return
	}

	server, err := s.repo.GetServer(r.Context(), pending.ServerID)
	if err != nil || !canDisableTLS(server) {
		writeError(w, http.StatusConflict, "transport_mode_changed", "服务器已不再处于待降级的加密状态")
		return
	}
	updated, plainURL, err := disableServerTLS(r.Context(), s.cfg.TLS, s.repo, server)
	if err != nil {
		var disableErr *tlsDisableError
		if errors.As(err, &disableErr) {
			writeError(w, disableErr.status, disableErr.code, disableErr.Error())
			return
		}
		writeResult(w, nil, err)
		return
	}
	s.tlsRequired.Store(false)
	s.tlsSecureURL.Store(secureServerURL(server.TLSIdentifier, s.cfg.TLS.SecurePublicPort))
	s.tlsPlainURL.Store(plainURL)
	s.tlsPendingMu.Lock()
	delete(s.downgradePending, req.ConfirmationToken)
	s.tlsPendingMu.Unlock()
	s.audit(r.Context(), pending.ServerID, pending.RequestedByUserID, "server.encryption_downgraded", pending.ServerID, nil)
	writeJSON(w, http.StatusOK, updated)
	s.hub.NotifyAndDisconnectServer(pending.ServerID, realtime.Event{
		Type: "server.encryption_changed", ServerID: pending.ServerID,
		Payload: map[string]any{"encryption_mode": "none", "plain_url": pending.PlainURL},
	})
}

func (s *Server) hasPendingEncryptionChangeLocked() bool {
	return len(s.tlsPending) != 0 || len(s.downgradePending) != 0
}

func (s *Server) expirePendingTLS(serverID, token string) {
	s.tlsApplyMu.Lock()
	defer s.tlsApplyMu.Unlock()
	s.tlsPendingMu.Lock()
	pending, ok := s.tlsPending[serverID]
	if ok && pending.Token == token {
		delete(s.tlsPending, serverID)
	} else {
		ok = false
	}
	s.tlsPendingMu.Unlock()
	if !ok {
		return
	}
	pending.rollback()
	s.recordTLSFailure(context.Background(), pending.Previous, pending.CertificateType, pending.Identifier, "HTTPS 客户端未在两分钟内确认，已恢复原配置")
}
