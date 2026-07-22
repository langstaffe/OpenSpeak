package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"openspeak/internal/config"
	"openspeak/internal/filenode"
	"openspeak/internal/store"
)

func TestTLSIdentifierValidationAndCaddyConfig(t *testing.T) {
	for _, value := range []string{"127.0.0.1", "10.0.0.1", "192.168.1.1", "100.64.0.1", "203.0.113.1"} {
		if _, err := normalizeTLSIdentifier("ip", value); err == nil {
			t.Fatalf("normalizeTLSIdentifier(ip, %q) accepted a non-public address", value)
		}
	}
	if got, err := normalizeTLSIdentifier("ip", "1.1.1.1"); err != nil || got != "1.1.1.1" {
		t.Fatalf("public IPv4 rejected: got %q, err %v", got, err)
	}
	if got, err := normalizeTLSIdentifier("domain", "Voice.Example.COM."); err != nil || got != "voice.example.com" {
		t.Fatalf("domain normalization failed: got %q, err %v", got, err)
	}
	if _, err := normalizeTLSIdentifier("domain", "https://example.com"); err == nil {
		t.Fatal("domain accepted a URL")
	}

	config := buildCaddyfile("ip", "2001:4860:4860::8888", "127.0.0.1:27411", "127.0.0.1:27420", 27410, 27412)
	for _, required := range []string{"auto_https disable_redirects", "default_sni 2001:4860:4860::8888", "https://[2001:4860:4860::8888]:27412", "disable_tlsalpn_challenge", "profile shortlived", "encode zstd gzip", "reverse_proxy /rtc* 127.0.0.1:27420", "reverse_proxy 127.0.0.1:27411"} {
		if !strings.Contains(config, required) {
			t.Fatalf("Caddy config missing %q:\n%s", required, config)
		}
	}
	if !strings.Contains(config, "http://:27410") {
		t.Fatal("Caddy config dropped the plaintext discovery endpoint")
	}
	if got := tlsURLHost("2001:4860:4860::8888"); got != "[2001:4860:4860::8888]" {
		t.Fatalf("IPv6 URL host = %q", got)
	}
}

func TestCaddyRenewalAtReadsSelectedTime(t *testing.T) {
	root := t.TempDir()
	identifier := "voice.example.com"
	metadataPath := filepath.Join(root, ".local", "share", "caddy", "certificates", "issuer", identifier, identifier+".json")
	if err := os.MkdirAll(filepath.Dir(metadataPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(metadataPath, []byte(`{"issuer_data":{"renewal_info":{"_selectedTime":"2026-07-19T00:08:41Z"}}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	got := caddyRenewalAt(filepath.Join(root, "caddy", "Caddyfile"), identifier)
	if got == nil || got.Format(time.RFC3339) != "2026-07-19T00:08:41Z" {
		t.Fatalf("renewal time = %v", got)
	}
}

func TestBuildPlainCaddyfileKeepsOnlyHTTPGateway(t *testing.T) {
	config := buildPlainCaddyfile("domain", "voice.example.com", "127.0.0.1:27411", "127.0.0.1:27420", 28080, 28443)
	if !strings.Contains(config, "http://:28080") || !strings.Contains(config, "reverse_proxy 127.0.0.1:27411") || !strings.Contains(config, "reverse_proxy /rtc* 127.0.0.1:27420") {
		t.Fatalf("plain Caddyfile = %q", config)
	}
	if !strings.Contains(config, "https://voice.example.com:28443") || !strings.Contains(config, "disable_tlsalpn_challenge") || !strings.Contains(config, "encode zstd gzip") {
		t.Fatalf("plain Caddyfile dropped HTTPS discovery alias: %q", config)
	}
}

func TestBuildPlainCaddyfileDoesNotStealLegacyBackendPort(t *testing.T) {
	config := buildPlainCaddyfile("domain", "voice.example.com", "127.0.0.1:27410", "127.0.0.1:27420", 27410, 27412)
	if strings.Contains(config, "http://:27410") {
		t.Fatalf("legacy backend port was rebound by Caddy: %q", config)
	}
	if got := plainLiveKitURL("voice.example.com", "127.0.0.1:27420"); got != "ws://voice.example.com:27420" {
		t.Fatalf("legacy LiveKit URL = %q", got)
	}
}

func TestSyncTLSGatewayMigratesActiveGatewayToSecurePort(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	var loaded []byte
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		loaded, _ = io.ReadAll(r.Body)
	}))
	defer admin.Close()
	caddyPath := filepath.Join(t.TempDir(), "Caddyfile")
	legacyConfig := strings.ReplaceAll(
		buildCaddyfile("domain", "voice.example.com", "127.0.0.1:27411", "127.0.0.1:27420", 27410, 27412),
		"\tencode zstd gzip\n", "",
	)
	if err := os.WriteFile(caddyPath, []byte(legacyConfig), 0o600); err != nil {
		t.Fatal(err)
	}
	env.server.cfg.TLS = config.TLSConfig{
		CaddyAdminURL: admin.URL, CaddyConfigPath: caddyPath,
		BackendUpstream: "127.0.0.1:27411", LiveKitUpstream: "127.0.0.1:27420",
		PlainPublicPort: 27410, SecurePublicPort: 27412,
	}
	servers := []store.OSServer{{
		TLSStatus: "active", TLSCertificateType: "domain", TLSIdentifier: "voice.example.com",
	}}
	if err := env.server.syncTLSGateway(context.Background(), servers); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(loaded, []byte("https://voice.example.com:27412")) || !bytes.Contains(loaded, []byte("disable_tlsalpn_challenge")) {
		t.Fatalf("migrated Caddyfile = %s", loaded)
	}
}

func TestConfirmationRequiresAdvertisedURL(t *testing.T) {
	secure := httptest.NewRequest(http.MethodPost, "https://new.example.com:27412/confirm", nil)
	secure.Header.Set("X-Forwarded-Proto", "https")
	if !requestMatchesURL(secure, "https://new.example.com:27412") {
		t.Fatal("candidate HTTPS URL was rejected")
	}
	secure.Host = "old.example.com"
	if requestMatchesURL(secure, "https://new.example.com:27412") {
		t.Fatal("old HTTPS alias was accepted")
	}
	plain := httptest.NewRequest(http.MethodPost, "http://voice.example.com:27410/confirm", nil)
	if !requestMatchesURL(plain, "http://voice.example.com:27410") {
		t.Fatal("advertised HTTP URL was rejected")
	}
	plain.Host = "voice.example.com:27411"
	if requestMatchesURL(plain, "http://voice.example.com:27410") {
		t.Fatal("wrong HTTP port was accepted")
	}
}

func TestEncryptionChangesAreProcessWidePending(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	env.server.tlsPending["another-server"] = pendingTLSApply{}
	if !env.server.hasPendingEncryptionChangeLocked() {
		t.Fatal("TLS transition on another server was ignored")
	}
}

func TestActiveTransportAndE2EEServersCanDisableTLS(t *testing.T) {
	for _, mode := range []string{"transport", "e2ee"} {
		if !canDisableTLS(store.OSServer{TLSStatus: "active", EncryptionMode: mode}) {
			t.Fatalf("active %s server cannot disable TLS", mode)
		}
	}
	for _, server := range []store.OSServer{
		{TLSStatus: "active", EncryptionMode: "none"},
		{TLSStatus: "discovery", EncryptionMode: "transport"},
	} {
		if canDisableTLS(server) {
			t.Fatalf("ineligible server can disable TLS: %#v", server)
		}
	}
}

func TestDiscoveryAliasRedirectsSecureClientsToPlainHTTP(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	env.server.tlsSecureURL.Store("https://voice.example.com")
	env.server.tlsPlainURL.Store("http://voice.example.com:28080")

	health := httptest.NewRequest(http.MethodGet, "https://voice.example.com/api/health", nil)
	health.RemoteAddr = "127.0.0.1:1234"
	health.Header.Set("X-Forwarded-Proto", "https")
	healthResponse := httptest.NewRecorder()
	env.server.ServeHTTP(healthResponse, health)
	if healthResponse.Code != http.StatusOK || !strings.Contains(healthResponse.Body.String(), `"plain_url":"http://voice.example.com:28080"`) {
		t.Fatalf("discovery health status = %d, body = %s", healthResponse.Code, healthResponse.Body.String())
	}

	apiRequest := httptest.NewRequest(http.MethodGet, "https://voice.example.com/api/v1/servers", nil)
	apiRequest.RemoteAddr = "127.0.0.1:1234"
	apiRequest.Header.Set("X-Forwarded-Proto", "https")
	apiResponse := httptest.NewRecorder()
	env.server.ServeHTTP(apiResponse, apiRequest)
	if apiResponse.Code != http.StatusUpgradeRequired || !strings.Contains(apiResponse.Body.String(), `"plain_url":"http://voice.example.com:28080"`) {
		t.Fatalf("discovery API status = %d, body = %s", apiResponse.Code, apiResponse.Body.String())
	}
}

func TestDiscoveryAliasAllowsOnlyCurrentTLSProbe(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	env.server.tlsSecureURL.Store("https://voice.example.com")
	env.server.tlsPlainURL.Store("http://voice.example.com:28080")
	env.server.tlsProbeToken.Store("current-probe")

	request := httptest.NewRequest(http.MethodGet, "https://voice.example.com/ws?tls_probe=current-probe", nil)
	request.RemoteAddr = "127.0.0.1:1234"
	request.Header.Set("X-Forwarded-Proto", "https")
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("valid TLS probe status = %d, body = %s", response.Code, response.Body.String())
	}

	request = httptest.NewRequest(http.MethodGet, "https://voice.example.com/ws?tls_probe=stale-probe", nil)
	request.RemoteAddr = "127.0.0.1:1234"
	request.Header.Set("X-Forwarded-Proto", "https")
	response = httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusUpgradeRequired {
		t.Fatalf("stale TLS probe status = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestDiscoveryAliasAllowsSecureTLSConfirmation(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	env.server.tlsSecureURL.Store("https://voice.example.com")
	env.server.tlsPlainURL.Store("http://voice.example.com:28080")

	request := httptest.NewRequest(http.MethodPost, "https://voice.example.com/api/v1/servers/"+env.os.ID+"/tls/confirm", strings.NewReader(`{"confirmation_token":"invalid"}`))
	request.RemoteAddr = "127.0.0.1:1234"
	request.Header.Set("X-Forwarded-Proto", "https")
	request.Header.Set("Authorization", "Bearer "+env.token)
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code == http.StatusUpgradeRequired {
		t.Fatalf("TLS confirmation was redirected to plaintext: %s", response.Body.String())
	}
}

func TestDowngradeConfirmRejectsInvalidTokenOverHTTP(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	env.server.tlsRequired.Store(true)
	env.server.tlsSecureURL.Store("https://voice.example.com")
	request := httptest.NewRequest(http.MethodPost, "http://voice.example.com:27410/api/v1/encryption/downgrade/confirm", strings.NewReader(`{"confirmation_token":"invalid"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("invalid downgrade token status = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestE2EEDowngradeConfirmKeepsTokenWhenCaddyIsUnavailable(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	expiresAt := time.Now().Add(24 * time.Hour)
	mode := "e2ee"
	if _, err := env.repo.UpdateServerTLS(context.Background(), env.os.ID, "domain", "voice.example.com", "active", "", &expiresAt, &mode); err != nil {
		t.Fatal(err)
	}
	env.server.tlsRequired.Store(true)
	env.server.tlsSecureURL.Store("https://voice.example.com")
	env.server.downgradePending["retry-token"] = pendingEncryptionDowngrade{
		Token: "retry-token", ServerID: env.os.ID, RequestedByUserID: env.user.ID,
		PlainURL: "http://voice.example.com:27410", ExpiresAt: time.Now().Add(time.Minute),
	}

	request := httptest.NewRequest(http.MethodPost, "http://voice.example.com:27410/api/v1/encryption/downgrade/confirm", strings.NewReader(`{"confirmation_token":"retry-token"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusBadGateway {
		t.Fatalf("Caddy failure status = %d, body = %s", response.Code, response.Body.String())
	}
	if _, ok := env.server.downgradePending["retry-token"]; !ok {
		t.Fatal("retry token was consumed after a failed Caddy request")
	}
}

func TestDisableTLSFromHostAppliesPlainGatewayAndDatabaseState(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	expiresAt := time.Now().Add(24 * time.Hour)
	mode := "transport"
	if _, err := env.repo.UpdateServerTLS(context.Background(), env.os.ID, "domain", "voice.example.com", "active", "", &expiresAt, &mode); err != nil {
		t.Fatal(err)
	}
	var loadedConfig []byte
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/config/":
			_, _ = w.Write([]byte(`{}`))
		case r.Method == http.MethodPost && r.URL.Path == "/load":
			loadedConfig, _ = io.ReadAll(r.Body)
		default:
			http.NotFound(w, r)
		}
	}))
	defer admin.Close()
	root := t.TempDir()
	caddyPath := filepath.Join(root, "caddy", "Caddyfile")
	if err := os.MkdirAll(filepath.Dir(caddyPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(caddyPath, []byte("old config"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{TLS: config.TLSConfig{
		CaddyAdminURL: admin.URL, CaddyConfigPath: caddyPath,
		BackendUpstream: "127.0.0.1:27411", LiveKitUpstream: "127.0.0.1:27420", PlainPublicPort: 27410, SecurePublicPort: 27412,
	}}
	updated, plainURL, err := DisableTLSFromHost(context.Background(), cfg, env.repo, env.os.ID)
	if err != nil {
		t.Fatal(err)
	}
	if updated.EncryptionMode != "none" || updated.TLSStatus != "discovery" {
		t.Fatalf("server mode/status = %s/%s", updated.EncryptionMode, updated.TLSStatus)
	}
	if plainURL != "http://voice.example.com:27410" {
		t.Fatalf("plain URL = %q", plainURL)
	}
	if !bytes.Contains(loadedConfig, []byte("http://:27410")) {
		t.Fatalf("Caddy did not receive plaintext config: %s", loadedConfig)
	}
	savedConfig, err := os.ReadFile(caddyPath)
	if err != nil || !bytes.Equal(savedConfig, loadedConfig) {
		t.Fatalf("saved Caddy config = %q, err = %v", savedConfig, err)
	}
}

func TestTLSAddressMatchingSupportsEitherIPFamily(t *testing.T) {
	resolved := []netip.Addr{
		netip.MustParseAddr("198.51.100.20"),
		netip.MustParseAddr("2001:db8::20"),
	}
	current := []netip.Addr{
		netip.MustParseAddr("203.0.113.10"),
		netip.MustParseAddr("2001:db8::20"),
	}
	if !hasMatchingIP(resolved, current) {
		t.Fatal("matching IPv6 address was ignored when IPv4 differed")
	}
	if hasMatchingIP(resolved, []netip.Addr{netip.MustParseAddr("203.0.113.10")}) {
		t.Fatal("different public addresses matched")
	}
}

func TestPublicIPFromServerHost(t *testing.T) {
	for input, expected := range map[string]string{
		"1.1.1.1:27410":              "1.1.1.1",
		"[2606:4700:4700::1111]:443": "2606:4700:4700::1111",
	} {
		address, ok := publicIPFromHost(input)
		if !ok || address.String() != expected {
			t.Fatalf("publicIPFromHost(%q) = %q, %v", input, address, ok)
		}
	}
	for _, input := range []string{"192.168.1.10:27410", "localhost:27410", "voice.example.com"} {
		if _, ok := publicIPFromHost(input); ok {
			t.Fatalf("publicIPFromHost(%q) accepted a non-public IP", input)
		}
	}
}

func TestTLSIdentifierCannotReplaceAnotherServerGateway(t *testing.T) {
	servers := []store.OSServer{
		{ID: "srv_a", TLSStatus: "active", TLSIdentifier: "voice.example.com"},
		{ID: "srv_b", TLSStatus: "disabled"},
	}
	if got := conflictingTLSIdentifier(servers, "srv_b", "other.example.com"); got != "voice.example.com" {
		t.Fatalf("conflict = %q", got)
	}
	if got := conflictingTLSIdentifier(servers, "srv_b", "voice.example.com"); got != "" {
		t.Fatalf("shared gateway was rejected: %q", got)
	}
}

func TestActiveTLSAdvertisesUpgradeAndRejectsInsecureNodes(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	expiresAt := time.Now().Add(24 * time.Hour)
	mode := "transport"
	if _, err := env.repo.UpdateServerTLS(context.Background(), env.os.ID, "domain", "voice.example.com", "active", "", &expiresAt, &mode); err != nil {
		t.Fatal(err)
	}
	env.server.tlsRequired.Store(true)
	env.server.tlsSecureURL.Store("https://voice.example.com:27412")
	healthRequest := httptest.NewRequest(http.MethodGet, "/api/health", nil)
	healthResponse := httptest.NewRecorder()
	env.server.ServeHTTP(healthResponse, healthRequest)
	var health map[string]any
	if err := json.Unmarshal(healthResponse.Body.Bytes(), &health); err != nil {
		t.Fatal(err)
	}
	if health["secure_url"] != "https://voice.example.com:27412" {
		t.Fatalf("health secure_url = %q", health["secure_url"])
	}

	request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{}`))
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusUpgradeRequired {
		t.Fatalf("status = %d", response.Code)
	}
	var body map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["secure_url"] != "https://voice.example.com:27412" {
		t.Fatalf("secure_url = %q", body["secure_url"])
	}
	oldHostRequest := httptest.NewRequest(http.MethodGet, "http://old.example.com/api/v1/servers", nil)
	oldHostRequest.Host = "old.example.com"
	oldHostRequest.RemoteAddr = "127.0.0.1:1234"
	oldHostRequest.Header.Set("X-Forwarded-Proto", "https")
	oldHostResponse := httptest.NewRecorder()
	env.server.ServeHTTP(oldHostResponse, oldHostRequest)
	if oldHostResponse.Code != http.StatusUpgradeRequired {
		t.Fatalf("old TLS host status = %d", oldHostResponse.Code)
	}
	if err := env.server.validateNodeTransport(context.Background(), env.os.ID, "ws://media.example.com", "wss"); err == nil {
		t.Fatal("active transport accepted an insecure media node")
	}
	setNone := httptest.NewRequest(http.MethodPatch, "https://voice.example.com/api/v1/servers/"+env.os.ID+"/settings", strings.NewReader(`{"encryption_mode":"none"}`))
	setNone.Header.Set("Authorization", "Bearer "+env.token)
	setNone.Header.Set("Content-Type", "application/json")
	setNoneResponse := httptest.NewRecorder()
	env.server.ServeHTTP(setNoneResponse, setNone)
	if setNoneResponse.Code != http.StatusConflict {
		t.Fatalf("insecure downgrade returned %d", setNoneResponse.Code)
	}
}

func TestActiveTLSCannotEnableOrSelectLegacyInsecureNodes(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	ctx := context.Background()
	media, err := env.repo.CreateMediaNode(ctx, store.MediaNode{
		ServerID: env.os.ID, Name: "legacy media", LiveKitURL: "ws://media.example.com",
		APIKey: "key", APISecret: "secret", Enabled: false,
	})
	if err != nil {
		t.Fatal(err)
	}
	file, err := env.repo.CreateFileNode(ctx, store.FileNode{
		ServerID: env.os.ID, Name: "legacy files", BaseURL: "http://files.example.com",
		Secret: "secret", Enabled: false,
	})
	if err != nil {
		t.Fatal(err)
	}
	expiresAt := time.Now().Add(24 * time.Hour)
	mode := "transport"
	if _, err := env.repo.UpdateServerTLS(ctx, env.os.ID, "domain", "voice.example.com", "active", "", &expiresAt, &mode); err != nil {
		t.Fatal(err)
	}

	request := func(method, path, body string) int {
		req := httptest.NewRequest(method, path, bytes.NewBufferString(body))
		req.Header.Set("Authorization", "Bearer "+env.token)
		req.Header.Set("Content-Type", "application/json")
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, req)
		return response.Code
	}
	if status := request(http.MethodPatch, "/api/v1/servers/"+env.os.ID+"/media-nodes/"+media.ID, `{"enabled":true}`); status != http.StatusConflict {
		t.Fatalf("enabling insecure media node returned %d", status)
	}
	if status := request(http.MethodPatch, "/api/v1/servers/"+env.os.ID+"/file-nodes/"+file.ID, `{"enabled":true}`); status != http.StatusConflict {
		t.Fatalf("enabling insecure file node returned %d", status)
	}
	enabled := true
	if _, err := env.repo.UpdateFileNode(ctx, env.os.ID, file.ID, store.FileNodePatch{Enabled: &enabled}); err != nil {
		t.Fatal(err)
	}
	settingsBody := `{"attachment_external_enabled":true,"attachment_file_node_id":"` + file.ID + `"}`
	if status := request(http.MethodPatch, "/api/v1/servers/"+env.os.ID+"/settings", settingsBody); status != http.StatusConflict {
		t.Fatalf("selecting insecure file node returned %d", status)
	}
}

func TestFileNodesRequireHTTPSEvenWithoutTransportMode(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	request := httptest.NewRequest(http.MethodPost, "/api/v1/servers/"+env.os.ID+"/file-nodes", strings.NewReader(`{"name":"files","base_url":"http://files.example.com","secret":"secret"}`))
	request.Header.Set("Authorization", "Bearer "+env.token)
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("insecure file node status = %d, body = %s", response.Code, response.Body.String())
	}
	if _, err := normalizeFileNodeURL("https://files.example.com/path"); err != nil {
		t.Fatalf("HTTPS file node rejected: %v", err)
	}
}

func TestFileNodeCheckRequiresHealthAndMatchingSecret(t *testing.T) {
	nodeServer := httptest.NewTLSServer(&filenode.Server{Root: t.TempDir(), Secret: "matching-secret"})
	defer nodeServer.Close()
	previousTransport := http.DefaultTransport
	http.DefaultTransport = nodeServer.Client().Transport
	defer func() { http.DefaultTransport = previousTransport }()

	if err := checkFileNode(context.Background(), nodeServer.URL, "matching-secret"); err != nil {
		t.Fatalf("valid file node rejected: %v", err)
	}
	if err := checkFileNode(context.Background(), nodeServer.URL, "wrong-secret"); err == nil {
		t.Fatal("file node accepted the wrong shared secret")
	}
	if err := checkSecureService(context.Background(), nodeServer.URL+"/missing", "/health"); err == nil {
		t.Fatal("file node health check accepted HTTP 404")
	}

	env := newChannelTestEnv(t, "none")
	create := func(secret string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodPost, "/api/v1/servers/"+env.os.ID+"/file-nodes", strings.NewReader(`{"name":"files","base_url":"`+nodeServer.URL+`","secret":"`+secret+`"}`))
		request.Header.Set("Authorization", "Bearer "+env.token)
		request.Header.Set("Content-Type", "application/json")
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, request)
		return response
	}
	if response := create("matching-secret"); response.Code != http.StatusOK {
		t.Fatalf("valid file node create status = %d, body = %s", response.Code, response.Body.String())
	}
	if response := create("wrong-secret"); response.Code != http.StatusBadGateway {
		t.Fatalf("wrong file node secret status = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestLocalLiveKitNodeUsesCaddyTLS(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	env.server.cfg.LiveKit.APIKey = "local-key"
	env.server.cfg.LiveKit.APISecret = "local-secret"
	env.server.cfg.TLS.LiveKitUpstream = "127.0.0.1:27420"
	local := store.MediaNode{APIKey: "local-key", APISecret: "local-secret", LiveKitURL: "ws://1.1.1.1:27420"}
	if !env.server.isLocalLiveKitNode(local, "") {
		t.Fatal("bundled LiveKit node was treated as an external insecure node")
	}
	local.APISecret = "other-secret"
	if !env.server.isLocalLiveKitNode(local, "1.1.1.1") {
		t.Fatal("same-host LiveKit node was treated as external")
	}
	local.LiveKitURL = "ws://8.8.8.8:27420"
	if env.server.isLocalLiveKitNode(local, "1.1.1.1") {
		t.Fatal("external LiveKit node was treated as local")
	}
	local.LiveKitURL = "ws://1.1.1.1:27421"
	if env.server.isLocalLiveKitNode(local, "1.1.1.1") {
		t.Fatal("same-host node on a different upstream port was treated as local")
	}
}

func TestSecureRequestOnlyTrustsLocalTLSProxy(t *testing.T) {
	request := httptest.NewRequest("GET", "http://openspeak.test/ws", nil)
	request.Header.Set("X-Forwarded-Proto", "https")
	request.RemoteAddr = "203.0.113.20:1234"
	if requestIsSecure(request) {
		t.Fatal("remote client spoofed X-Forwarded-Proto")
	}
	request.RemoteAddr = "127.0.0.1:1234"
	if !requestIsSecure(request) {
		t.Fatal("local Caddy proxy was not trusted")
	}
}

func TestCaddyRequestUsesPermissionedUnixSocket(t *testing.T) {
	placeholder, err := os.CreateTemp("", "openspeak-caddy-*.sock")
	if err != nil {
		t.Fatal(err)
	}
	socketPath := placeholder.Name()
	_ = placeholder.Close()
	_ = os.Remove(socketPath)
	t.Cleanup(func() { _ = os.Remove(socketPath) })
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/config/" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(`{"ok":true}`))
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close() })

	data, err := caddyRequest(context.Background(), http.MethodGet, "unix://"+socketPath, "/config/", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"ok":true}` {
		t.Fatalf("response = %s", data)
	}
}
