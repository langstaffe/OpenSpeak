package httpapi

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"openspeak/internal/store"
)

var webPathPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

func normalizeWebPath(value string) (string, error) {
	value = strings.Trim(strings.TrimSpace(value), "/")
	if !webPathPattern.MatchString(value) {
		return "", errors.New("网页路径只能包含字母、数字、下划线和连字符，长度为 1–64 个字符")
	}
	lower := strings.ToLower(value)
	switch {
	case lower == "api", lower == "ws", strings.HasPrefix(lower, "rtc"):
		return "", errors.New("网页路径不能使用 api、ws 或 rtc")
	default:
		return value, nil
	}
}

func (s *Server) webAssetsAvailable() bool {
	info, err := os.Stat(filepath.Join(s.cfg.WebRoot, "index.html"))
	return err == nil && !info.IsDir()
}

func (s *Server) webAccessURL(settings store.WebSettings) string {
	base := strings.TrimRight(s.activeTLSURL(), "/")
	if base == "" {
		return ""
	}
	if settings.CustomPathEnabled {
		return base + "/" + settings.Path + "/"
	}
	return base + "/"
}

func (s *Server) webSettingsResponse(settings store.WebSettings) map[string]any {
	return map[string]any{
		"enabled":             settings.Enabled,
		"custom_path_enabled": settings.CustomPathEnabled,
		"path":                settings.Path,
		"updated_at":          settings.UpdatedAt,
		"assets_available":    s.webAssetsAvailable(),
		"access_url":          s.webAccessURL(settings),
	}
}

func (s *Server) handleWebSettings(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) {
	if !s.requireNotBanned(w, r, authCtx, serverID) || !s.requireOwnerDevice(w, authCtx, serverID) {
		return
	}
	switch r.Method {
	case http.MethodGet:
		settings, err := s.repo.GetWebSettings(r.Context())
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		writeJSON(w, http.StatusOK, s.webSettingsResponse(settings))
	case http.MethodPut:
		var req struct {
			Enabled           bool   `json:"enabled"`
			CustomPathEnabled bool   `json:"custom_path_enabled"`
			Path              string `json:"path"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		current, err := s.repo.GetWebSettings(r.Context())
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		pathValue := req.Path
		if strings.TrimSpace(pathValue) == "" {
			pathValue = current.Path
		}
		path, err := normalizeWebPath(pathValue)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid_web_path", err.Error())
			return
		}
		if req.Enabled {
			server, err := s.repo.GetServer(r.Context(), serverID)
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			if server.TLSStatus != "active" {
				writeError(w, http.StatusConflict, "tls_required", "启用网页端前必须先启用 HTTPS")
				return
			}
			if !s.webAssetsAvailable() {
				writeError(w, http.StatusConflict, "web_assets_missing", "服务器未安装网页端资源")
				return
			}
		}
		if current.Enabled == req.Enabled &&
			current.CustomPathEnabled == req.CustomPathEnabled &&
			current.Path == path {
			writeJSON(w, http.StatusOK, s.webSettingsResponse(current))
			return
		}
		settings, err := s.repo.UpdateWebSettings(r.Context(), req.Enabled, req.CustomPathEnabled, path)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		s.audit(r.Context(), serverID, authCtx.User.ID, "web.settings_updated", "", map[string]string{
			"enabled":             boolString(settings.Enabled),
			"custom_path_enabled": boolString(settings.CustomPathEnabled),
			"path":                settings.Path,
		})
		s.hub.DisconnectClientType("web", "web.settings_changed")
		writeJSON(w, http.StatusOK, s.webSettingsResponse(settings))
	default:
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	}
}

func boolString(value bool) string {
	if value {
		return "true"
	}
	return "false"
}

func (s *Server) serveWeb(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return false
	}
	settings, err := s.repo.GetWebSettings(r.Context())
	if err != nil || !settings.Enabled || !requestIsSecure(r) || !s.webAssetsAvailable() {
		return false
	}

	prefix := "/"
	if settings.CustomPathEnabled {
		prefix = "/" + settings.Path + "/"
		if r.URL.Path == strings.TrimSuffix(prefix, "/") {
			http.Redirect(w, r, prefix, http.StatusTemporaryRedirect)
			return true
		}
		if !strings.HasPrefix(r.URL.Path, prefix) {
			return false
		}
	}
	relative := strings.TrimPrefix(r.URL.Path, prefix)
	if relative == "" {
		relative = "index.html"
	}
	clean := filepath.Clean(filepath.FromSlash(relative))
	if clean == "." || filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return false
	}
	asset := filepath.Join(s.cfg.WebRoot, clean)
	info, statErr := os.Stat(asset)
	if statErr != nil || info.IsDir() {
		return false
	}
	if clean == "index.html" {
		raw, readErr := os.ReadFile(asset)
		if readErr != nil {
			return false
		}
		base := prefix
		body := strings.Replace(string(raw), `<base href="/">`, `<base href="`+base+`">`, 1)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		if r.Method == http.MethodHead {
			return true
		}
		_, _ = w.Write([]byte(body))
		return true
	}
	w.Header().Set("Cache-Control", "no-cache")
	disableDownloadWriteTimeout(w)
	http.ServeFile(w, r, asset)
	return true
}
