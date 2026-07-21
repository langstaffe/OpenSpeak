package httpapi

import (
	"context"
	"errors"
	"html"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
)

const linkPreviewMaxBytes = 2 << 20

type linkPreview struct {
	URL         string `json:"url"`
	Domain      string `json:"domain"`
	Title       string `json:"title,omitempty"`
	Description string `json:"description,omitempty"`
	ImageURL    string `json:"imageUrl,omitempty"`
}

type linkPreviewCache struct {
	ttl     time.Duration
	mu      sync.Mutex
	entries map[string]linkPreviewCacheEntry
}

type linkPreviewCacheEntry struct {
	preview   linkPreview
	expiresAt time.Time
}

func newLinkPreviewCache(ttl time.Duration) *linkPreviewCache {
	return &linkPreviewCache{ttl: ttl, entries: make(map[string]linkPreviewCacheEntry)}
}

func (c *linkPreviewCache) get(key string) (linkPreview, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.entries[key]
	if !ok {
		return linkPreview{}, false
	}
	if time.Now().After(entry.expiresAt) {
		delete(c.entries, key)
		return linkPreview{}, false
	}
	return entry.preview, true
}

func (c *linkPreviewCache) set(key string, preview linkPreview) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[key] = linkPreviewCacheEntry{
		preview:   preview,
		expiresAt: time.Now().Add(c.ttl),
	}
}

func (s *Server) handleLinkPreview(w http.ResponseWriter, r *http.Request, _ authContext, parts []string) {
	if len(parts) != 0 || r.Method != http.MethodGet {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}
	rawURL := strings.TrimSpace(r.URL.Query().Get("url"))
	if rawURL == "" {
		writeError(w, http.StatusBadRequest, "missing_url", "url is required")
		return
	}
	validURL, err := validateLinkPreviewURL(r.Context(), rawURL)
	if err != nil {
		writeError(w, http.StatusBadRequest, "unsafe_url", err.Error())
		return
	}
	key := validURL.String()
	if cached, ok := s.linkPreviews.get(key); ok {
		writeJSON(w, http.StatusOK, cached)
		return
	}
	preview, err := fetchLinkPreview(r.Context(), validURL)
	if err != nil {
		preview = fallbackLinkPreview(validURL)
	}
	s.linkPreviews.set(key, preview)
	writeJSON(w, http.StatusOK, preview)
}

func fetchLinkPreview(parent context.Context, target *url.URL) (linkPreview, error) {
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()

	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(address)
			if err != nil {
				return nil, err
			}
			ips, err := resolvePreviewIPs(ctx, host)
			if err != nil {
				return nil, err
			}
			dialer := &net.Dialer{Timeout: 5 * time.Second}
			return dialer.DialContext(ctx, network, net.JoinHostPort(ips[0].String(), port))
		},
		ResponseHeaderTimeout: 5 * time.Second,
	}
	defer transport.CloseIdleConnections()

	client := &http.Client{
		Transport: transport,
		Timeout:   5 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return errors.New("too many redirects")
			}
			_, err := validateLinkPreviewURL(req.Context(), req.URL.String())
			return err
		},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return linkPreview{}, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (compatible; OpenSpeakLinkPreview/1.0; +https://openspeak.local)")
	req.Header.Set("Accept", "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1")
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
	resp, err := client.Do(req)
	if err != nil {
		return linkPreview{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return linkPreview{}, errors.New("preview target returned non-success status")
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, linkPreviewMaxBytes))
	if err != nil {
		return linkPreview{}, err
	}
	finalURL := resp.Request.URL
	preview := parseLinkPreviewHTML(string(body), finalURL)
	preview.URL = target.String()
	preview.Domain = target.Hostname()
	if preview.ImageURL != "" {
		if imageURL, err := finalURL.Parse(preview.ImageURL); err == nil {
			preview.ImageURL = imageURL.String()
		}
	}
	return mergeLinkPreviewFallback(preview, fallbackLinkPreview(finalURL)), nil
}

func validateLinkPreviewURL(ctx context.Context, rawURL string) (*url.URL, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return nil, errors.New("invalid url")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, errors.New("only http and https urls are allowed")
	}
	if parsed.Hostname() == "" {
		return nil, errors.New("url host is required")
	}
	if parsed.User != nil {
		return nil, errors.New("urls with user info are not allowed")
	}
	if err := validateLinkPreviewHost(ctx, parsed.Hostname()); err != nil {
		return nil, err
	}
	return parsed, nil
}

func validateLinkPreviewHost(ctx context.Context, host string) error {
	_, err := resolvePreviewIPs(ctx, host)
	return err
}

func resolvePreviewIPs(ctx context.Context, host string) ([]net.IP, error) {
	host = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(host)), ".")
	if host == "" {
		return nil, errors.New("url host is required")
	}
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || host == "0.0.0.0" {
		return nil, errors.New("local hosts are not allowed")
	}
	if ip := net.ParseIP(host); ip != nil {
		if isBlockedPreviewIP(ip) {
			return nil, errors.New("private or local addresses are not allowed")
		}
		return []net.IP{ip}, nil
	}
	addrs, err := net.DefaultResolver.LookupIPAddr(ctx, host)
	if err != nil {
		return nil, errors.New("url host could not be resolved")
	}
	if len(addrs) == 0 {
		return nil, errors.New("url host did not resolve")
	}
	ips := make([]net.IP, 0, len(addrs))
	for _, addr := range addrs {
		if isBlockedPreviewIP(addr.IP) {
			return nil, errors.New("private or local addresses are not allowed")
		}
		ips = append(ips, addr.IP)
	}
	return ips, nil
}

func isBlockedPreviewIP(ip net.IP) bool {
	return ip.IsLoopback() ||
		ip.IsPrivate() ||
		ip.IsUnspecified() ||
		ip.IsLinkLocalUnicast() ||
		ip.IsLinkLocalMulticast() ||
		ip.IsMulticast()
}

var (
	titleTagPattern = regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`)
	metaTagPattern  = regexp.MustCompile(`(?is)<meta\s+[^>]*>`)
	attrPattern     = regexp.MustCompile(`(?is)([a-zA-Z_:.-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>/]+))`)
	spacePattern    = regexp.MustCompile(`\s+`)
)

func parseLinkPreviewHTML(doc string, baseURL *url.URL) linkPreview {
	meta := map[string]string{}
	for _, tag := range metaTagPattern.FindAllString(doc, -1) {
		attrs := parseHTMLAttrs(tag)
		key := strings.ToLower(firstNonEmpty(attrs["property"], attrs["name"]))
		content := cleanPreviewText(attrs["content"])
		if key != "" && content != "" {
			meta[key] = content
		}
	}
	title := firstNonEmpty(meta["og:title"], meta["twitter:title"])
	if title == "" {
		if match := titleTagPattern.FindStringSubmatch(doc); len(match) == 2 {
			title = cleanPreviewText(match[1])
		}
	}
	description := firstNonEmpty(
		meta["og:description"],
		meta["twitter:description"],
		meta["description"],
	)
	imageURL := firstNonEmpty(meta["og:image"], meta["twitter:image"])
	if imageURL != "" && baseURL != nil {
		if parsed, err := baseURL.Parse(imageURL); err == nil {
			imageURL = parsed.String()
		}
	}
	return linkPreview{
		Title:       title,
		Description: description,
		ImageURL:    imageURL,
	}
}

func fallbackLinkPreview(target *url.URL) linkPreview {
	host := strings.TrimPrefix(strings.ToLower(target.Hostname()), "www.")
	preview := linkPreview{
		URL:      target.String(),
		Domain:   target.Hostname(),
		Title:    target.Hostname(),
		ImageURL: faviconPreviewURL(target.Hostname()),
	}
	switch host {
	case "youtube.com", "youtu.be":
		preview.Title = "YouTube"
		preview.Description = "Enjoy the videos and music you love, upload original content, and share it all with friends, family, and the world on YouTube."
	case "zhihu.com":
		preview.Title = "知乎 - 有问题，就会有答案"
		preview.Description = "知乎，中文互联网高质量的问答社区和创作者聚集的原创内容平台。"
	}
	return preview
}

func mergeLinkPreviewFallback(preview linkPreview, fallback linkPreview) linkPreview {
	if preview.URL == "" {
		preview.URL = fallback.URL
	}
	if preview.Domain == "" {
		preview.Domain = fallback.Domain
	}
	if preview.Title == "" {
		preview.Title = fallback.Title
	}
	if preview.Description == "" {
		preview.Description = fallback.Description
	}
	if preview.ImageURL == "" {
		preview.ImageURL = fallback.ImageURL
	}
	return preview
}

func faviconPreviewURL(host string) string {
	host = strings.TrimSpace(host)
	if host == "" {
		return ""
	}
	return "https://www.google.com/s2/favicons?domain=" + url.QueryEscape(host) + "&sz=128"
}

func parseHTMLAttrs(tag string) map[string]string {
	attrs := map[string]string{}
	for _, match := range attrPattern.FindAllStringSubmatch(tag, -1) {
		if len(match) < 6 {
			continue
		}
		value := firstNonEmpty(match[3], match[4], match[5])
		attrs[strings.ToLower(match[1])] = html.UnescapeString(value)
	}
	return attrs
}

func cleanPreviewText(value string) string {
	value = html.UnescapeString(value)
	value = strings.TrimSpace(spacePattern.ReplaceAllString(value, " "))
	runes := []rune(value)
	if len(runes) > 500 {
		return string(runes[:500])
	}
	return value
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}
