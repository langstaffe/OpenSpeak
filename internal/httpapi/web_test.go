package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"openspeak/internal/auth"
)

func TestWebSettingsRouteAndSessionInvalidation(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	webRoot := t.TempDir()
	if err := os.WriteFile(filepath.Join(webRoot, "index.html"), []byte(`<html><head><base href="/"></head><body>OpenSpeak</body></html>`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(webRoot, "main.dart.js"), []byte(`window.openspeak=true;`), 0o600); err != nil {
		t.Fatal(err)
	}
	fontDir := filepath.Join(webRoot, "fonts", "notosanssc", "v37")
	if err := os.MkdirAll(fontDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fontDir, "subset.woff2"), []byte("font-subset"), 0o600); err != nil {
		t.Fatal(err)
	}
	env.server.cfg.WebRoot = webRoot
	if _, err := env.repo.UpdateServerTLS(t.Context(), env.os.ID, "manual", "example.test", "active", "", nil, nil); err != nil {
		t.Fatal(err)
	}
	ownerToken, _, err := auth.CreateToken(env.server.cfg.JWTSecret, auth.Claims{
		Subject: env.user.ID, OwnerServerID: env.os.ID, OwnerDeviceID: "owner-device",
	}, env.server.cfg.JWTTTL)
	if err != nil {
		t.Fatal(err)
	}

	rootBefore := httptest.NewRecorder()
	env.server.ServeHTTP(rootBefore, httptest.NewRequest(http.MethodGet, "https://example.test/", nil))
	if rootBefore.Code != http.StatusNotFound || rootBefore.Body.Len() != 0 {
		t.Fatalf("disabled root = %d %q", rootBefore.Code, rootBefore.Body.String())
	}

	enable := httptest.NewRequest(http.MethodPut, "https://example.test/api/v1/servers/"+env.os.ID+"/web-settings", strings.NewReader(`{"enabled":true,"custom_path_enabled":true,"path":"chat"}`))
	enable.Header.Set("Authorization", "Bearer "+ownerToken)
	enable.Header.Set("Content-Type", "application/json")
	enableResponse := httptest.NewRecorder()
	env.server.ServeHTTP(enableResponse, enable)
	if enableResponse.Code != http.StatusOK {
		t.Fatalf("enable status = %d, body = %s", enableResponse.Code, enableResponse.Body.String())
	}

	root := httptest.NewRecorder()
	env.server.ServeHTTP(root, httptest.NewRequest(http.MethodGet, "https://example.test/", nil))
	if root.Code != http.StatusNotFound || root.Body.Len() != 0 {
		t.Fatalf("custom-path root = %d %q", root.Code, root.Body.String())
	}
	index := httptest.NewRecorder()
	env.server.ServeHTTP(index, httptest.NewRequest(http.MethodGet, "https://example.test/chat/", nil))
	if index.Code != http.StatusOK || !strings.Contains(index.Body.String(), `<base href="/chat/">`) {
		t.Fatalf("custom index = %d %q", index.Code, index.Body.String())
	}
	head := httptest.NewRecorder()
	env.server.ServeHTTP(head, httptest.NewRequest(http.MethodHead, "https://example.test/chat/", nil))
	if head.Code != http.StatusOK || head.Body.Len() != 0 || head.Header().Get("Content-Length") == "" {
		t.Fatalf("custom index HEAD = %d, length = %q, body = %q", head.Code, head.Header().Get("Content-Length"), head.Body.String())
	}
	asset := newDeadlineResponseRecorder()
	env.server.ServeHTTP(asset, httptest.NewRequest(http.MethodGet, "https://example.test/chat/main.dart.js", nil))
	if asset.Code != http.StatusOK || !strings.Contains(asset.Body.String(), "openspeak") {
		t.Fatalf("custom asset = %d %q", asset.Code, asset.Body.String())
	}
	if !asset.writeTimeoutDisabled() {
		t.Fatal("custom asset retained the server write timeout")
	}
	font := newDeadlineResponseRecorder()
	env.server.ServeHTTP(font, httptest.NewRequest(http.MethodGet, "https://example.test/chat/fonts/notosanssc/v37/subset.woff2", nil))
	if font.Code != http.StatusOK || font.Body.String() != "font-subset" {
		t.Fatalf("custom font = %d %q", font.Code, font.Body.String())
	}
	if got := font.Header().Get("Cache-Control"); got != "public, max-age=31536000, immutable" {
		t.Fatalf("custom font cache = %q", got)
	}
	if !font.writeTimeoutDisabled() {
		t.Fatal("custom font retained the server write timeout")
	}

	login := httptest.NewRequest(http.MethodPost, "https://example.test/api/v1/auth/login", strings.NewReader(`{"display_name":"Browser user","client_type":"web"}`))
	login.Header.Set("Content-Type", "application/json")
	loginResponse := httptest.NewRecorder()
	env.server.ServeHTTP(loginResponse, login)
	if loginResponse.Code != http.StatusOK {
		t.Fatalf("web login = %d %s", loginResponse.Code, loginResponse.Body.String())
	}
	var loginResult struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(loginResponse.Body.Bytes(), &loginResult); err != nil {
		t.Fatal(err)
	}
	claims, err := auth.ParseToken(env.server.cfg.JWTSecret, loginResult.Token)
	if err != nil || claims.ClientType != "web" || claims.WebGeneration == 0 {
		t.Fatalf("web claims = %+v, err = %v", claims, err)
	}
	ownerStatus := httptest.NewRequest(http.MethodGet, "https://example.test/api/v1/servers/"+env.os.ID+"/owner/status", nil)
	ownerStatus.Header.Set("Authorization", "Bearer "+loginResult.Token)
	ownerStatusResponse := httptest.NewRecorder()
	env.server.ServeHTTP(ownerStatusResponse, ownerStatus)
	if ownerStatusResponse.Code != http.StatusForbidden {
		t.Fatalf("web owner status = %d, body = %s", ownerStatusResponse.Code, ownerStatusResponse.Body.String())
	}
	noOp := httptest.NewRequest(http.MethodPut, "https://example.test/api/v1/servers/"+env.os.ID+"/web-settings", strings.NewReader(`{"enabled":true,"custom_path_enabled":true,"path":"chat"}`))
	noOp.Header.Set("Authorization", "Bearer "+ownerToken)
	noOp.Header.Set("Content-Type", "application/json")
	noOpResponse := httptest.NewRecorder()
	env.server.ServeHTTP(noOpResponse, noOp)
	if noOpResponse.Code != http.StatusOK {
		t.Fatalf("no-op update status = %d, body = %s", noOpResponse.Code, noOpResponse.Body.String())
	}
	requestAfterNoOp := httptest.NewRequest(http.MethodGet, "https://example.test/api/v1/servers", nil)
	requestAfterNoOp.Header.Set("Authorization", "Bearer "+loginResult.Token)
	afterNoOpResponse := httptest.NewRecorder()
	env.server.ServeHTTP(afterNoOpResponse, requestAfterNoOp)
	if afterNoOpResponse.Code != http.StatusOK {
		t.Fatalf("Web token after no-op = %d, body = %s", afterNoOpResponse.Code, afterNoOpResponse.Body.String())
	}
	passwordUpdate := httptest.NewRequest(http.MethodPatch, "https://example.test/api/v1/servers/"+env.os.ID+"/settings", strings.NewReader(`{"server_password":"new-password"}`))
	passwordUpdate.Header.Set("Authorization", "Bearer "+ownerToken)
	passwordUpdate.Header.Set("Content-Type", "application/json")
	passwordUpdateResponse := httptest.NewRecorder()
	env.server.ServeHTTP(passwordUpdateResponse, passwordUpdate)
	if passwordUpdateResponse.Code != http.StatusOK {
		t.Fatalf("password update = %d, body = %s", passwordUpdateResponse.Code, passwordUpdateResponse.Body.String())
	}
	requestAfterPasswordChange := httptest.NewRequest(http.MethodGet, "https://example.test/api/v1/servers", nil)
	requestAfterPasswordChange.Header.Set("Authorization", "Bearer "+loginResult.Token)
	afterPasswordChangeResponse := httptest.NewRecorder()
	env.server.ServeHTTP(afterPasswordChangeResponse, requestAfterPasswordChange)
	if afterPasswordChangeResponse.Code != http.StatusUnauthorized {
		t.Fatalf("Web token after password change = %d, body = %s", afterPasswordChangeResponse.Code, afterPasswordChangeResponse.Body.String())
	}
	login = httptest.NewRequest(http.MethodPost, "https://example.test/api/v1/auth/login", strings.NewReader(`{"display_name":"Browser user","client_type":"web","password":"new-password"}`))
	login.Header.Set("Content-Type", "application/json")
	loginResponse = httptest.NewRecorder()
	env.server.ServeHTTP(loginResponse, login)
	if loginResponse.Code != http.StatusOK {
		t.Fatalf("Web login after password change = %d, body = %s", loginResponse.Code, loginResponse.Body.String())
	}
	if err := json.Unmarshal(loginResponse.Body.Bytes(), &loginResult); err != nil {
		t.Fatal(err)
	}

	disable := httptest.NewRequest(http.MethodPut, "https://example.test/api/v1/servers/"+env.os.ID+"/web-settings", strings.NewReader(`{"enabled":false,"custom_path_enabled":true,"path":"chat"}`))
	disable.Header.Set("Authorization", "Bearer "+ownerToken)
	disable.Header.Set("Content-Type", "application/json")
	disableResponse := httptest.NewRecorder()
	env.server.ServeHTTP(disableResponse, disable)
	if disableResponse.Code != http.StatusOK {
		t.Fatalf("disable status = %d, body = %s", disableResponse.Code, disableResponse.Body.String())
	}

	requestWithOldToken := httptest.NewRequest(http.MethodGet, "https://example.test/api/v1/servers", nil)
	requestWithOldToken.Header.Set("Authorization", "Bearer "+loginResult.Token)
	oldTokenResponse := httptest.NewRecorder()
	env.server.ServeHTTP(oldTokenResponse, requestWithOldToken)
	if oldTokenResponse.Code != http.StatusUnauthorized {
		t.Fatalf("old Web token status = %d, body = %s", oldTokenResponse.Code, oldTokenResponse.Body.String())
	}
	indexAfter := httptest.NewRecorder()
	env.server.ServeHTTP(indexAfter, httptest.NewRequest(http.MethodGet, "https://example.test/chat/", nil))
	if indexAfter.Code != http.StatusNotFound || indexAfter.Body.Len() != 0 {
		t.Fatalf("disabled index = %d %q", indexAfter.Code, indexAfter.Body.String())
	}
}

func TestNormalizeWebPath(t *testing.T) {
	for _, value := range []string{"api", "ws", "rtc", "rtc-chat", "../chat", "chat/more", ""} {
		if _, err := normalizeWebPath(value); err == nil {
			t.Fatalf("normalizeWebPath(%q) succeeded", value)
		}
	}
	if value, err := normalizeWebPath("/my-chat/"); err != nil || value != "my-chat" {
		t.Fatalf("normalizeWebPath valid = %q, %v", value, err)
	}
}

func TestWebRootEntryWithoutCustomPath(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	webRoot := t.TempDir()
	if err := os.WriteFile(filepath.Join(webRoot, "index.html"), []byte(`<base href="/"><body>OpenSpeak</body>`), 0o600); err != nil {
		t.Fatal(err)
	}
	env.server.cfg.WebRoot = webRoot
	if _, err := env.repo.UpdateWebSettings(t.Context(), true, false, "chat"); err != nil {
		t.Fatal(err)
	}

	root := httptest.NewRecorder()
	env.server.ServeHTTP(root, httptest.NewRequest(http.MethodGet, "https://example.test/", nil))
	if root.Code != http.StatusOK || !strings.Contains(root.Body.String(), `<base href="/">`) {
		t.Fatalf("root index = %d %q", root.Code, root.Body.String())
	}
}
