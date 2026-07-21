package httpapi

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/png"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"openspeak/internal/auth"
	"openspeak/internal/config"
	"openspeak/internal/database"
	"openspeak/internal/filenode"
	"openspeak/internal/realtime"
	"openspeak/internal/store"

	"github.com/gorilla/websocket"
)

type channelTestEnv struct {
	server  *Server
	repo    *store.SQLite
	db      *sql.DB
	hub     *realtime.Hub
	token   string
	user    store.User
	os      store.OSServer
	channel store.Channel
	epoch   store.ChannelEpoch
}

type deadlineResponseRecorder struct {
	*httptest.ResponseRecorder
	writeDeadlines []time.Time
}

func newDeadlineResponseRecorder() *deadlineResponseRecorder {
	return &deadlineResponseRecorder{ResponseRecorder: httptest.NewRecorder()}
}

func (r *deadlineResponseRecorder) SetWriteDeadline(deadline time.Time) error {
	r.writeDeadlines = append(r.writeDeadlines, deadline)
	return nil
}

func (r *deadlineResponseRecorder) writeTimeoutDisabled() bool {
	return len(r.writeDeadlines) > 0 && r.writeDeadlines[len(r.writeDeadlines)-1].IsZero()
}

func newChannelTestEnv(t *testing.T, mode string) channelTestEnv {
	t.Helper()
	ctx := context.Background()
	tempDir := t.TempDir()
	db, err := database.OpenSQLite(ctx, filepath.Join(tempDir, "openspeak.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	repo := store.NewSQLite(db)
	user, err := repo.CreateUser(ctx, "Tester")
	if err != nil {
		t.Fatal(err)
	}
	osServer, err := repo.CreateServer(ctx, store.OSServer{
		Name:                 "Test Server",
		EncryptionMode:       mode,
		FileRoot:             filepath.Join(tempDir, "files"),
		HistoryRetentionDays: 30,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.SetServerMember(ctx, osServer.ID, user.ID, store.RoleOwner, store.AllPermissions()); err != nil {
		t.Fatal(err)
	}
	channel, err := repo.CreateChannel(ctx, store.Channel{ServerID: osServer.ID, Name: "General"})
	if err != nil {
		t.Fatal(err)
	}
	if err := repo.AddChannelMember(ctx, channel.ID, user.ID, "member"); err != nil {
		t.Fatal(err)
	}
	epoch, err := repo.CreateEpoch(ctx, channel.ID, "test")
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{
		JWTSecret: "test-secret", JWTTTL: time.Hour, DefaultEncryptionMode: "transport",
		DirectFileRoot: filepath.Join(tempDir, "tmp", "direct_files"),
		FileRoot:       filepath.Join(tempDir, "files"),
		TLS:            config.TLSConfig{PlainPublicPort: 27410, SecurePublicPort: 27412},
	}
	token, _, err := auth.CreateToken(cfg.JWTSecret, auth.Claims{Subject: user.ID}, cfg.JWTTTL)
	if err != nil {
		t.Fatal(err)
	}
	hub := realtime.NewHub()
	hubContext, cancelHub := context.WithCancel(context.Background())
	go hub.Run(hubContext)
	t.Cleanup(cancelHub)
	return channelTestEnv{
		server:  NewServer(cfg, repo, hub),
		repo:    repo,
		db:      db,
		hub:     hub,
		token:   token,
		user:    user,
		os:      osServer,
		channel: channel,
		epoch:   epoch,
	}
}

func TestVoiceAudioBitrateSetting(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	if env.os.VoiceAudioBitrateKbps != 64 {
		t.Fatalf("default bitrate = %d", env.os.VoiceAudioBitrateKbps)
	}

	invalid := httptest.NewRequest(http.MethodPatch, "/api/v1/servers/"+env.os.ID+"/settings", strings.NewReader(`{"voice_audio_bitrate_kbps":72}`))
	invalid.Header.Set("Authorization", "Bearer "+env.token)
	invalidResponse := httptest.NewRecorder()
	env.server.ServeHTTP(invalidResponse, invalid)
	if invalidResponse.Code != http.StatusBadRequest {
		t.Fatalf("invalid status = %d, body = %s", invalidResponse.Code, invalidResponse.Body.String())
	}

	request := httptest.NewRequest(http.MethodPatch, "/api/v1/servers/"+env.os.ID+"/settings", strings.NewReader(`{"voice_audio_bitrate_kbps":96}`))
	request.Header.Set("Authorization", "Bearer "+env.token)
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	server, err := env.repo.GetServer(context.Background(), env.os.ID)
	if err != nil || server.VoiceAudioBitrateKbps != 96 {
		t.Fatalf("stored bitrate = %d, err = %v", server.VoiceAudioBitrateKbps, err)
	}
}

func TestScreenShareBitrateSetting(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	if got := env.os.ScreenShareBitrateLimits.BitrateMbps("1080p", 60); got != 16 {
		t.Fatalf("default 1080p 60 FPS bitrate = %d", got)
	}
	if _, err := env.db.ExecContext(context.Background(), `UPDATE os_servers SET screen_share_bitrate_limits_json = '' WHERE id = ?`, env.os.ID); err != nil {
		t.Fatal(err)
	}
	legacy, err := env.repo.GetServer(context.Background(), env.os.ID)
	if err != nil || legacy.ScreenShareBitrateLimits.BitrateMbps("source", 60) != 32 {
		t.Fatalf("legacy default limits = %#v, err = %v", legacy.ScreenShareBitrateLimits, err)
	}

	invalid := httptest.NewRequest(http.MethodPatch, "/api/v1/servers/"+env.os.ID+"/settings", strings.NewReader(`{"screen_share_bitrate_limits_mbps":{"720p":{"15":0,"30":4,"60":8},"1080p":{"15":4,"30":8,"60":16},"source":{"15":8,"30":16,"60":32}}}`))
	invalid.Header.Set("Authorization", "Bearer "+env.token)
	invalidResponse := httptest.NewRecorder()
	env.server.ServeHTTP(invalidResponse, invalid)
	if invalidResponse.Code != http.StatusBadRequest {
		t.Fatalf("invalid status = %d, body = %s", invalidResponse.Code, invalidResponse.Body.String())
	}

	limits := store.DefaultScreenShareBitrateLimits()
	limits.P1080.FPS60 = 25
	limits.Source.FPS60 = 60
	body, err := json.Marshal(map[string]any{"screen_share_bitrate_limits_mbps": limits})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPatch, "/api/v1/servers/"+env.os.ID+"/settings", bytes.NewReader(body))
	request.Header.Set("Authorization", "Bearer "+env.token)
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	server, err := env.repo.GetServer(context.Background(), env.os.ID)
	if err != nil || server.ScreenShareBitrateLimits.BitrateMbps("source", 60) != 60 {
		t.Fatalf("stored limits = %#v, err = %v", server.ScreenShareBitrateLimits, err)
	}

	env.server.cfg.LiveKit = config.LiveKitConfig{
		URL: "wss://voice.test", APIKey: "key", APISecret: "secret", TokenTTL: time.Hour,
	}
	env.hub.SetCurrentChannel(env.os.ID, env.user.ID, env.channel.ID)
	tokenRequest := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/screen-share-token", strings.NewReader(`{"publish":true,"resolution":"1080p","fps":60}`))
	tokenRequest.Header.Set("Authorization", "Bearer "+env.token)
	tokenResponse := httptest.NewRecorder()
	env.server.ServeHTTP(tokenResponse, tokenRequest)
	if tokenResponse.Code != http.StatusOK {
		t.Fatalf("screen token status = %d, body = %s", tokenResponse.Code, tokenResponse.Body.String())
	}
	var tokenBody map[string]any
	if err := json.Unmarshal(tokenResponse.Body.Bytes(), &tokenBody); err != nil {
		t.Fatal(err)
	}
	if got := tokenBody["max_bitrate_mbps"]; got != float64(25) {
		t.Fatalf("screen token max bitrate = %#v", got)
	}
}

func TestScreenSharePolicyUsesNineQualityOptions(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	want := map[string]bool{}
	for _, resolution := range []string{"720p", "1080p", "source"} {
		for _, fps := range []int{15, 30, 60} {
			want[resolution+":"+strconv.Itoa(fps)] = true
		}
	}
	assertMode := func(name string, mode store.ScreenShareModePolicy, enabled bool) {
		t.Helper()
		if mode.Enabled != enabled || len(mode.Allowed) != len(want) {
			t.Fatalf("%s = %#v", name, mode)
		}
		seen := map[string]bool{}
		for _, option := range mode.Allowed {
			key := option.Resolution + ":" + strconv.Itoa(option.FPS)
			if !want[key] || seen[key] {
				t.Fatalf("%s option = %#v", name, option)
			}
			seen[key] = true
		}
	}
	assertMode("p2p", env.os.ScreenSharePolicy.P2P, false)
	assertMode("relay", env.os.ScreenSharePolicy.Relay, true)

	if _, err := env.db.ExecContext(context.Background(), `UPDATE os_servers SET screen_share_policy_json = ? WHERE id = ?`, `{"p2p":{"enabled":true,"allowed":[{"resolution":"480p","fps":15}]},"relay":{"enabled":true,"allowed":[{"resolution":"720p","fps":15}]}}`, env.os.ID); err != nil {
		t.Fatal(err)
	}
	migrated, err := env.repo.GetServer(context.Background(), env.os.ID)
	if err != nil {
		t.Fatal(err)
	}
	assertMode("migrated p2p", migrated.ScreenSharePolicy.P2P, false)
	assertMode("migrated relay", migrated.ScreenSharePolicy.Relay, true)

	unsupported := store.DefaultScreenSharePolicy()
	unsupported.P2P.Enabled = true
	if err := validateScreenSharePolicy(unsupported); err == nil {
		t.Fatal("enabled p2p policy was accepted before p2p is implemented")
	}
	incomplete := store.DefaultScreenSharePolicy()
	incomplete.Relay.Allowed = incomplete.Relay.Allowed[:1]
	if err := validateScreenSharePolicy(incomplete); err == nil {
		t.Fatal("incomplete relay quality policy was accepted")
	}
}

func TestScreenShareQualityPermissionsRequireResolutionAndFPS(t *testing.T) {
	if err := validateScreenShareQualityPermissions("user", []string{
		store.PermissionVoiceScreenShare,
	}); err == nil {
		t.Fatal("screen sharing without a quality option was accepted")
	}
	if err := validateScreenShareQualityPermissions("user", []string{
		store.PermissionVoiceScreenShare,
		store.PermissionVoiceScreenShareResolution720p,
		store.PermissionVoiceScreenShareFPS15,
	}); err != nil {
		t.Fatalf("valid screen-share quality permissions rejected: %v", err)
	}

	env := newChannelTestEnv(t, "transport")
	if _, err := env.repo.SetServerRolePermissions(
		context.Background(),
		env.os.ID,
		[]string{store.PermissionVoiceScreenShare},
		[]string{store.PermissionVoiceScreenShare},
		env.user.ID,
	); err != nil {
		t.Fatal(err)
	}
	permissions, err := env.repo.GetServerRolePermissions(context.Background(), env.os.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, permission := range store.ScreenShareQualityPermissions() {
		if !permissionEnabled(permissions.Admin, permission) || !permissionEnabled(permissions.User, permission) {
			t.Fatalf("legacy permissions did not enable %q: %#v", permission, permissions)
		}
	}
}

func TestVoiceTokenRestrictsPublishSourcesByPermission(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	env.server.cfg.LiveKit = config.LiveKitConfig{
		URL: "wss://voice.test", APIKey: "key", APISecret: "secret", TokenTTL: time.Hour,
	}
	ctx := context.Background()
	member, err := env.repo.CreateUser(ctx, "Screen sharer")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(ctx, env.os.ID, member.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	if err := env.repo.AddChannelMember(ctx, env.channel.ID, member.ID, "member"); err != nil {
		t.Fatal(err)
	}
	memberToken := mustToken(t, env.server.cfg, member.ID)

	requestToken := func() (map[string]any, map[string]any) {
		t.Helper()
		request := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/voice-token", nil)
		request.Header.Set("Authorization", "Bearer "+memberToken)
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, request)
		if response.Code != http.StatusOK {
			t.Fatalf("voice token = %d, body = %s", response.Code, response.Body.String())
		}
		var body map[string]any
		if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		parts := strings.Split(body["token"].(string), ".")
		if len(parts) != 3 {
			t.Fatalf("jwt parts = %d", len(parts))
		}
		payload, err := base64.RawURLEncoding.DecodeString(parts[1])
		if err != nil {
			t.Fatal(err)
		}
		var claims map[string]any
		if err := json.Unmarshal(payload, &claims); err != nil {
			t.Fatal(err)
		}
		return body, claims["video"].(map[string]any)
	}

	if _, err := env.repo.SetServerRolePermissions(ctx, env.os.ID, store.AdminPermissions(), []string{store.PermissionVoiceJoin, store.PermissionVoiceScreenShare}, env.user.ID); err != nil {
		t.Fatal(err)
	}
	body, video := requestToken()
	if body["can_publish"] != false || body["can_share_screen"] != true || video["canPublish"] != false {
		t.Fatalf("screen-only response = %#v, video = %#v", body, video)
	}
	if _, exists := video["canPublishSources"]; exists {
		t.Fatalf("voice token exposed screen source = %#v", video)
	}
	env.hub.SetCurrentChannel(env.os.ID, member.ID, env.channel.ID)
	screenRequest := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/screen-share-token", strings.NewReader(`{"publish":true,"resolution":"1080p","fps":30}`))
	screenRequest.Header.Set("Authorization", "Bearer "+memberToken)
	screenResponse := httptest.NewRecorder()
	env.server.ServeHTTP(screenResponse, screenRequest)
	if screenResponse.Code != http.StatusOK {
		t.Fatalf("screen token = %d, body = %s", screenResponse.Code, screenResponse.Body.String())
	}
	var screenBody map[string]any
	if err := json.Unmarshal(screenResponse.Body.Bytes(), &screenBody); err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(screenBody["token"].(string), ".")
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var screenClaims map[string]any
	if err := json.Unmarshal(payload, &screenClaims); err != nil {
		t.Fatal(err)
	}
	screenVideo := screenClaims["video"].(map[string]any)
	if screenVideo["canPublish"] != true || screenVideo["canSubscribe"] != false {
		t.Fatalf("screen grant = %#v", screenVideo)
	}
	if got := screenVideo["canPublishSources"].([]any); len(got) != 1 || got[0] != "screen_share" {
		t.Fatalf("screen sources = %#v", got)
	}

	if _, err := env.repo.SetServerRolePermissions(ctx, env.os.ID, store.AdminPermissions(), []string{store.PermissionVoiceJoin, store.PermissionVoiceSpeak}, env.user.ID); err != nil {
		t.Fatal(err)
	}
	body, video = requestToken()
	if body["can_publish"] != true || body["can_share_screen"] != false || video["canPublish"] != true {
		t.Fatalf("microphone-only response = %#v, video = %#v", body, video)
	}
	if got := video["canPublishSources"].([]any); len(got) != 1 || got[0] != "microphone" {
		t.Fatalf("microphone-only sources = %#v", got)
	}

	if _, err := env.repo.SetServerRolePermissions(ctx, env.os.ID, store.AdminPermissions(), []string{store.PermissionVoiceJoin, store.PermissionVoiceScreenShare}, env.user.ID); err != nil {
		t.Fatal(err)
	}
	relayDisabled := store.DefaultScreenSharePolicy()
	relayDisabled.Relay.Enabled = false
	rawPolicy, err := json.Marshal(relayDisabled)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.db.ExecContext(ctx, `UPDATE os_servers SET screen_share_policy_json = ? WHERE id = ?`, string(rawPolicy), env.os.ID); err != nil {
		t.Fatal(err)
	}
	body, video = requestToken()
	if body["can_publish"] != false || body["can_share_screen"] != false || video["canPublish"] != false {
		t.Fatalf("relay-disabled response = %#v, video = %#v", body, video)
	}
	if _, exists := video["canPublishSources"]; exists {
		t.Fatalf("relay-disabled sources = %#v", video["canPublishSources"])
	}

	legacyRequest := httptest.NewRequest(http.MethodPost, "/api/v1/livekit/token", strings.NewReader(`{"room":"bypass","can_publish":true}`))
	legacyRequest.Header.Set("Authorization", "Bearer "+memberToken)
	legacyResponse := httptest.NewRecorder()
	env.server.ServeHTTP(legacyResponse, legacyRequest)
	if legacyResponse.Code != http.StatusNotFound {
		t.Fatalf("legacy token endpoint = %d, body = %s", legacyResponse.Code, legacyResponse.Body.String())
	}
}

func TestVoiceTokenPersistentRoomOptIn(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	env.server.cfg.LiveKit = config.LiveKitConfig{
		URL: "wss://voice.test", APIKey: "key", APISecret: "secret", TokenTTL: time.Hour,
	}

	requestToken := func(body string) map[string]any {
		t.Helper()
		request := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/voice-token", strings.NewReader(body))
		request.Header.Set("Authorization", "Bearer "+env.token)
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, request)
		if response.Code != http.StatusOK {
			t.Fatalf("voice token = %d, body = %s", response.Code, response.Body.String())
		}
		var result map[string]any
		if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		return result
	}

	persistent := requestToken(`{"persistent_room":true}`)
	if persistent["room_scope"] != "server" || persistent["room"] != liveKitServerRoomName(env.os.ID) {
		t.Fatalf("persistent room = %#v", persistent)
	}
	legacy := requestToken(`{}`)
	if legacy["room_scope"] != "channel" || legacy["room"] != liveKitRoomName(env.os.ID, env.channel.ID) {
		t.Fatalf("legacy room = %#v", legacy)
	}
}

func TestVoiceTokenFallsBackOnlyToLegacyLocalMediaNode(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	env.server.cfg.LiveKit = config.LiveKitConfig{TokenTTL: time.Hour}
	env.server.cfg.TLS.LiveKitUpstream = "127.0.0.1:27420"
	ctx := context.Background()
	if _, err := env.repo.CreateMediaNode(ctx, store.MediaNode{
		ServerID: env.os.ID, Name: "external screen relay", LiveKitURL: "wss://screen.external",
		APIKey: "external-key", APISecret: "external-secret", Enabled: true, Weight: 10,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.CreateMediaNode(ctx, store.MediaNode{
		ServerID: env.os.ID, Name: "legacy local relay", LiveKitURL: "ws://127.0.0.1:27420",
		APIKey: "local-key", APISecret: "local-secret", Enabled: true, Weight: 1,
	}); err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/voice-token", nil)
	request.Header.Set("Authorization", "Bearer "+env.token)
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusOK ||
		!strings.Contains(response.Body.String(), `"url":"ws://127.0.0.1:27420"`) ||
		!strings.Contains(response.Body.String(), `"media_node_id":""`) {
		t.Fatalf("legacy local voice token = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestExternalMediaNodeIsUsedOnlyForScreenShare(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	env.server.cfg.LiveKit = config.LiveKitConfig{
		URL: "wss://voice.local", APIKey: "voice-key", APISecret: "voice-secret", TokenTTL: time.Hour,
	}
	ctx := context.Background()
	node, err := env.repo.CreateMediaNode(ctx, store.MediaNode{
		ServerID: env.os.ID, Name: "screen relay", LiveKitURL: "wss://screen.external",
		APIKey: "screen-key", APISecret: "screen-secret", Enabled: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	env.hub.SetCurrentChannel(env.os.ID, env.user.ID, env.channel.ID)

	request := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/voice-token", nil)
	request.Header.Set("Authorization", "Bearer "+env.token)
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"url":"wss://voice.local"`) || !strings.Contains(response.Body.String(), `"media_node_id":""`) {
		t.Fatalf("voice token used external node: %d %s", response.Code, response.Body.String())
	}
	env.server.cfg.LiveKit = config.LiveKitConfig{TokenTTL: time.Hour}
	request = httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/voice-token", nil)
	request.Header.Set("Authorization", "Bearer "+env.token)
	response = httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("voice token used external-only node: %d %s", response.Code, response.Body.String())
	}

	request = httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/screen-share-token", strings.NewReader(`{"publish":true,"resolution":"1080p","fps":30}`))
	request.Header.Set("Authorization", "Bearer "+env.token)
	response = httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"url":"wss://screen.external"`) || !strings.Contains(response.Body.String(), `"media_node_id":"`+node.ID+`"`) {
		t.Fatalf("screen token did not use external node: %d %s", response.Code, response.Body.String())
	}
	var publisherBody map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &publisherBody); err != nil {
		t.Fatal(err)
	}

	viewer, err := env.repo.CreateUser(ctx, "Viewer")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(ctx, env.os.ID, viewer.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	if err := env.repo.AddChannelMember(ctx, env.channel.ID, viewer.ID, "member"); err != nil {
		t.Fatal(err)
	}
	viewerToken := mustToken(t, env.server.cfg, viewer.ID)
	env.hub.SetCurrentChannel(env.os.ID, viewer.ID, env.channel.ID)
	env.hub.SetVoiceState(realtime.VoiceState{
		ServerID: env.os.ID, UserID: env.user.ID, DisplayName: env.user.DisplayName,
		ChannelID: env.channel.ID, ScreenSharing: true, ScreenShareResolution: "1080p",
		ScreenShareFPS: 30, ScreenShareMediaNodeID: node.ID,
	})
	disabled := false
	if _, err := env.repo.UpdateMediaNode(ctx, env.os.ID, node.ID, store.MediaNodePatch{Enabled: &disabled}); err != nil {
		t.Fatal(err)
	}
	request = httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/screen-share-token", strings.NewReader(`{"publisher_user_id":"`+env.user.ID+`"}`))
	request.Header.Set("Authorization", "Bearer "+viewerToken)
	response = httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"url":"wss://screen.external"`) || !strings.Contains(response.Body.String(), `"media_node_id":"`+node.ID+`"`) {
		t.Fatalf("viewer screen token did not retain external node: %d %s", response.Code, response.Body.String())
	}
	var viewerBody map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &viewerBody); err != nil {
		t.Fatal(err)
	}
	if viewerBody["room"] != publisherBody["room"] || !strings.Contains(viewerBody["room"].(string), env.user.ID) {
		t.Fatalf("screen rooms differ: publisher=%#v viewer=%#v", publisherBody["room"], viewerBody["room"])
	}
	parts := strings.Split(viewerBody["token"].(string), ".")
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var viewerClaims map[string]any
	if err := json.Unmarshal(payload, &viewerClaims); err != nil {
		t.Fatal(err)
	}
	video := viewerClaims["video"].(map[string]any)
	if video["canPublish"] != false || video["canSubscribe"] != true {
		t.Fatalf("viewer screen grant = %#v", video)
	}

	request = httptest.NewRequest(http.MethodPatch, "/api/v1/servers/"+env.os.ID+"/media-nodes/"+node.ID, strings.NewReader(`{"livekit_url":"wss://replacement.external"}`))
	request.Header.Set("Authorization", "Bearer "+env.token)
	response = httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), `"screen_share_node_in_use"`) {
		t.Fatalf("active relay endpoint update = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestMediaNodeListClassifiesBundledLiveKitWithoutExposingSecret(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	env.server.cfg.LiveKit = config.LiveKitConfig{
		URL: "ws://127.0.0.1:27420", APIKey: "local-key", APISecret: "local-secret", TokenTTL: time.Hour,
	}
	if _, err := env.repo.CreateMediaNode(context.Background(), store.MediaNode{
		ServerID: env.os.ID, Name: "bundled", LiveKitURL: "ws://127.0.0.1:27420",
		APIKey: "local-key", APISecret: "local-secret", Enabled: true,
	}); err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "/api/v1/servers/"+env.os.ID+"/media-nodes", nil)
	request.Header.Set("Authorization", "Bearer "+env.token)
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusOK ||
		!strings.Contains(response.Body.String(), `"is_local":true`) ||
		!strings.Contains(response.Body.String(), `"api_secret_set":true`) ||
		strings.Contains(response.Body.String(), "local-secret") {
		t.Fatalf("media node list = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestEnablingE2EERotatesChannelEpochs(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	if _, err := env.repo.UpdateServerTLS(context.Background(), env.os.ID, "domain", "voice.test", "active", "", nil, nil); err != nil {
		t.Fatal(err)
	}
	before, err := env.repo.GetLatestEpoch(context.Background(), env.channel.ID)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPatch, "/api/v1/servers/"+env.os.ID+"/settings", strings.NewReader(`{"encryption_mode":"e2ee"}`))
	request.Header.Set("Authorization", "Bearer "+env.token)
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("enable e2ee = %d, body = %s", response.Code, response.Body.String())
	}
	after, err := env.repo.GetLatestEpoch(context.Background(), env.channel.ID)
	if err != nil || after.EpochNumber != before.EpochNumber+1 || after.Reason != "e2ee_enabled" {
		t.Fatalf("rotated epoch = %#v, err = %v", after, err)
	}
}

func TestE2EEMediaEnvelopeGatesVoiceTokenByDeviceAndEpoch(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	env.server.cfg.LiveKit = config.LiveKitConfig{
		URL: "wss://voice.test", APIKey: "key", APISecret: "secret", TokenTTL: time.Hour,
	}
	device := store.Device{
		ID: "dev_0123456789abcdef0123456789abcdef", UserID: env.user.ID, Label: "e2ee",
		IdentityPublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32)),
		EnvelopePublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, 32)),
	}
	if _, err := env.repo.RegisterDevice(context.Background(), device); err != nil {
		t.Fatal(err)
	}
	envelope := store.KeyEnvelope{
		RecipientUserID: env.user.ID, RecipientDeviceID: device.ID,
		Algorithm: "openspeak-envelope-v1", Ciphertext: "sealed-media-key",
	}
	if _, err := env.repo.StoreEnvelopeBatch(context.Background(), env.channel.ID, env.epoch.ID, device.ID, env.user.ID, []store.KeyEnvelope{envelope}, false); err != nil {
		t.Fatal(err)
	}
	mediaBody, _ := json.Marshal(map[string]any{
		"channel_id": env.channel.ID, "epoch_id": env.epoch.ID, "sender_device_id": device.ID,
		"envelopes": []store.KeyEnvelope{envelope},
	})
	mediaRequest := httptest.NewRequest(http.MethodPost, "/api/v1/e2ee/media-envelopes", bytes.NewReader(mediaBody))
	mediaRequest.Header.Set("Authorization", "Bearer "+env.token)
	mediaResponse := httptest.NewRecorder()
	env.server.ServeHTTP(mediaResponse, mediaRequest)
	if mediaResponse.Code != http.StatusOK {
		t.Fatalf("store media envelope = %d, body = %s", mediaResponse.Code, mediaResponse.Body.String())
	}
	mediaEnvelopes, err := env.repo.ListEnvelopes(context.Background(), device.ID, &env.channel.ID, true)
	if err != nil || len(mediaEnvelopes) != 1 || mediaEnvelopes[0].Scope != "media" {
		t.Fatalf("media envelopes = %#v, err = %v", mediaEnvelopes, err)
	}

	voiceToken := func(epochID string, participantKeys bool) *httptest.ResponseRecorder {
		body, _ := json.Marshal(map[string]any{
			"device_id": device.ID, "e2ee_epoch_id": epochID,
			"persistent_room": true, "media_key_slots": true,
			"e2ee_participant_keys": participantKeys,
		})
		request := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/voice-token", bytes.NewReader(body))
		request.Header.Set("Authorization", "Bearer "+env.token)
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, request)
		return response
	}
	response := voiceToken(env.epoch.ID, true)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"e2ee_required":true`) || !strings.Contains(response.Body.String(), `"e2ee_epoch_id":"`+env.epoch.ID+`"`) {
		t.Fatalf("voice token = %d, body = %s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Body.String(), `"room_scope":"server"`) ||
		!strings.Contains(response.Body.String(), `"room":"`+liveKitServerRoomName(env.os.ID)+`"`) ||
		!strings.Contains(response.Body.String(), `"e2ee_participant_keys":true`) {
		t.Fatalf("participant-key e2ee persistent room = %s", response.Body.String())
	}
	if !strings.Contains(response.Body.String(), `"e2ee_key_index":0`) ||
		!strings.Contains(response.Body.String(), `"e2ee_key_active":true`) ||
		!strings.Contains(response.Body.String(), `"media_key_slots":false`) {
		t.Fatalf("default media key slot state = %s", response.Body.String())
	}
	legacy := voiceToken(env.epoch.ID, false)
	if legacy.Code != http.StatusOK ||
		!strings.Contains(legacy.Body.String(), `"room_scope":"channel"`) ||
		!strings.Contains(legacy.Body.String(), `"e2ee_participant_keys":false`) {
		t.Fatalf("legacy e2ee room = %d, body = %s", legacy.Code, legacy.Body.String())
	}
	env.hub.SetCurrentChannel(env.os.ID, env.user.ID, env.channel.ID)
	screenBody, _ := json.Marshal(map[string]any{
		"publish": true, "resolution": "1080p", "fps": 30,
		"device_id": device.ID, "e2ee_epoch_id": env.epoch.ID,
	})
	screenRequest := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/screen-share-token", bytes.NewReader(screenBody))
	screenRequest.Header.Set("Authorization", "Bearer "+env.token)
	screenResponse := httptest.NewRecorder()
	env.server.ServeHTTP(screenResponse, screenRequest)
	if screenResponse.Code != http.StatusOK ||
		!strings.Contains(screenResponse.Body.String(), `"e2ee_required":true`) ||
		!strings.Contains(screenResponse.Body.String(), `"e2ee_epoch_id":"`+env.epoch.ID+`"`) {
		t.Fatalf("screen token = %d, body = %s", screenResponse.Code, screenResponse.Body.String())
	}
	if missing := voiceToken("", true); missing.Code != http.StatusBadRequest {
		t.Fatalf("missing epoch = %d, body = %s", missing.Code, missing.Body.String())
	}
	if _, err := env.repo.CreateEpoch(context.Background(), env.channel.ID, "rotated"); err != nil {
		t.Fatal(err)
	}
	if stale := voiceToken(env.epoch.ID, true); stale.Code != http.StatusConflict || !strings.Contains(stale.Body.String(), "epoch_changed") {
		t.Fatalf("stale epoch = %d, body = %s", stale.Code, stale.Body.String())
	}
}

func TestE2EEMediaKeyTransitionActivatesAfterReady(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	env.server.cfg.LiveKit = config.LiveKitConfig{
		URL: "wss://voice.test", APIKey: "key", APISecret: "secret", TokenTTL: time.Hour,
	}
	ctx := context.Background()
	secondUser, err := env.repo.CreateUser(ctx, "Second")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(ctx, env.os.ID, secondUser.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	if err := env.repo.AddChannelMember(ctx, env.channel.ID, secondUser.ID, "member"); err != nil {
		t.Fatal(err)
	}
	secondToken := mustToken(t, env.server.cfg, secondUser.ID)
	device := store.Device{
		ID: "dev_0123456789abcdef0123456789abcdef", UserID: env.user.ID, Label: "desktop",
		IdentityPublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32)),
		EnvelopePublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, 32)),
	}
	if _, err := env.repo.RegisterDevice(ctx, device); err != nil {
		t.Fatal(err)
	}
	secondDevice := store.Device{
		ID: "dev_fedcba9876543210fedcba9876543210", UserID: secondUser.ID, Label: "desktop",
		IdentityPublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{3}, 32)),
		EnvelopePublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{4}, 32)),
	}
	if _, err := env.repo.RegisterDevice(ctx, secondDevice); err != nil {
		t.Fatal(err)
	}
	storeMediaEnvelope := func(epochID string) {
		t.Helper()
		_, err := env.repo.StoreEnvelopeBatch(ctx, env.channel.ID, epochID, device.ID, env.user.ID, []store.KeyEnvelope{
			{
				RecipientUserID: env.user.ID, RecipientDeviceID: device.ID,
				Algorithm: "openspeak-envelope-v1", Ciphertext: "sealed-media-key-owner-" + epochID,
			},
			{
				RecipientUserID: secondUser.ID, RecipientDeviceID: secondDevice.ID,
				Algorithm: "openspeak-envelope-v1", Ciphertext: "sealed-media-key-second-" + epochID,
			},
		}, true)
		if err != nil {
			t.Fatal(err)
		}
	}
	storeMediaEnvelope(env.epoch.ID)
	env.hub.SetCurrentChannel(env.os.ID, env.user.ID, env.channel.ID)
	env.hub.SetVoiceState(realtime.VoiceState{
		ServerID: env.os.ID, UserID: env.user.ID, ChannelID: env.channel.ID,
	})
	env.hub.SetCurrentChannel(env.os.ID, secondUser.ID, env.channel.ID)
	env.hub.SetVoiceState(realtime.VoiceState{
		ServerID: env.os.ID, UserID: secondUser.ID, ChannelID: env.channel.ID,
	})

	requestVoiceToken := func(token, deviceID string) {
		t.Helper()
		body, _ := json.Marshal(map[string]any{
			"device_id": deviceID, "e2ee_epoch_id": env.epoch.ID,
			"media_key_slots": true,
		})
		request := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/voice-token", bytes.NewReader(body))
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, request)
		if response.Code != http.StatusOK {
			t.Fatalf("voice token = %d, body = %s", response.Code, response.Body.String())
		}
	}
	requestVoiceToken(env.token, device.ID)
	requestVoiceToken(secondToken, secondDevice.ID)

	nextEpoch, err := env.repo.CreateEpoch(ctx, env.channel.ID, "member_added")
	if err != nil {
		t.Fatal(err)
	}
	if !env.server.beginMediaKeyTransition(ctx, env.os.ID, nextEpoch) {
		t.Fatal("expected a media key slot transition")
	}
	storeMediaEnvelope(nextEpoch.ID)
	if index, active, slots := env.server.mediaKeyStatus(env.channel.ID, nextEpoch.ID); index != 1 || active || !slots {
		t.Fatalf("pending status = index %d active %v slots %v", index, active, slots)
	}

	markReady := func(token, deviceID string) *httptest.ResponseRecorder {
		t.Helper()
		readyBody, _ := json.Marshal(map[string]string{
			"channel_id": env.channel.ID,
			"epoch_id":   nextEpoch.ID,
			"device_id":  deviceID,
		})
		request := httptest.NewRequest(http.MethodPost, "/api/v1/e2ee/media-key-ready", bytes.NewReader(readyBody))
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, request)
		return response
	}
	firstReady := markReady(env.token, device.ID)
	if firstReady.Code != http.StatusOK ||
		!strings.Contains(firstReady.Body.String(), `"activated":false`) {
		t.Fatalf("first ready = %d, body = %s", firstReady.Code, firstReady.Body.String())
	}
	secondReady := markReady(secondToken, secondDevice.ID)
	if secondReady.Code != http.StatusOK ||
		!strings.Contains(secondReady.Body.String(), `"key_index":1`) ||
		!strings.Contains(secondReady.Body.String(), `"activated":true`) ||
		!strings.Contains(secondReady.Body.String(), `"media_key_slots":true`) {
		t.Fatalf("second ready = %d, body = %s", secondReady.Code, secondReady.Body.String())
	}

	legacyBody, _ := json.Marshal(map[string]string{
		"device_id": secondDevice.ID, "e2ee_epoch_id": nextEpoch.ID,
	})
	legacyRequest := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/voice-token", bytes.NewReader(legacyBody))
	legacyRequest.Header.Set("Authorization", "Bearer "+secondToken)
	legacyResponse := httptest.NewRecorder()
	env.server.ServeHTTP(legacyResponse, legacyRequest)
	if legacyResponse.Code != http.StatusOK ||
		!strings.Contains(legacyResponse.Body.String(), `"e2ee_key_index":0`) ||
		!strings.Contains(legacyResponse.Body.String(), `"media_key_slots":false`) {
		t.Fatalf("legacy fallback = %d, body = %s", legacyResponse.Code, legacyResponse.Body.String())
	}
	if _, _, slots := env.server.mediaKeyStatus(env.channel.ID, nextEpoch.ID); slots {
		t.Fatal("legacy client did not disable media key slots")
	}
}

func TestE2EEMediaDevicesDoNotGrantChannelHistoryPermission(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	ctx := context.Background()
	voiceUser, err := env.repo.CreateUser(ctx, "Voice only")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(ctx, env.os.ID, voiceUser.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	if err := env.repo.AddChannelMember(ctx, env.channel.ID, voiceUser.ID, "member"); err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerRolePermissions(ctx, env.os.ID, store.AdminPermissions(), []string{store.PermissionVoiceJoin}, env.user.ID); err != nil {
		t.Fatal(err)
	}
	for index, userID := range []string{env.user.ID, voiceUser.ID} {
		if _, err := env.repo.RegisterDevice(ctx, store.Device{
			ID: "dev_" + strings.Repeat(strconv.Itoa(index+1), 32), UserID: userID, Label: "e2ee",
			IdentityPublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{byte(index + 1)}, 32)),
			EnvelopePublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{byte(index + 3)}, 32)),
		}); err != nil {
			t.Fatal(err)
		}
	}
	contentDevices, err := env.repo.ListChannelDevices(ctx, env.channel.ID, env.epoch.ID, false)
	if err != nil {
		t.Fatal(err)
	}
	mediaDevices, err := env.repo.ListChannelDevices(ctx, env.channel.ID, env.epoch.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(contentDevices) != 1 || contentDevices[0].UserID != env.user.ID {
		t.Fatalf("content devices = %#v", contentDevices)
	}
	if len(mediaDevices) != 2 {
		t.Fatalf("media devices = %#v", mediaDevices)
	}
}

func TestInvalidLegacyE2EEDeviceKeysAreIgnored(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	ctx := context.Background()
	validDevice := store.Device{
		ID: "dev_valid0123456789abcdef0123456789", UserID: env.user.ID, Label: "valid",
		IdentityPublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32)),
		EnvelopePublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, 32)),
	}
	if _, err := env.repo.RegisterDevice(ctx, validDevice); err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.RegisterDevice(ctx, store.Device{
		ID: "dev_legacy0123456789abcdef012345678", UserID: env.user.ID, Label: "legacy",
		IdentityPublicKey: validDevice.IdentityPublicKey,
		EnvelopePublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{3}, 18)),
	}); err != nil {
		t.Fatal(err)
	}

	devices, err := env.repo.ListChannelDevices(ctx, env.channel.ID, env.epoch.ID, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 1 || devices[0].ID != validDevice.ID {
		t.Fatalf("eligible devices = %#v", devices)
	}
	if _, err := env.repo.StoreEnvelopeBatch(ctx, env.channel.ID, env.epoch.ID, validDevice.ID, env.user.ID, []store.KeyEnvelope{{
		RecipientUserID: env.user.ID, RecipientDeviceID: validDevice.ID,
		Algorithm: "openspeak-envelope-v1", Ciphertext: "sealed-key",
	}}, false); err != nil {
		t.Fatal(err)
	}
}

func TestE2EEDeviceRegistrationIsStableAndCannotBeStolen(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	deviceID := "dev_0123456789abcdef0123456789abcdef"
	identityKey := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	envelopeKey := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, 32))
	register := func(token, userID, label, identity, envelope string) *httptest.ResponseRecorder {
		body, err := json.Marshal(map[string]string{
			"device_id": deviceID, "label": label,
			"identity_public_key": identity, "envelope_public_key": envelope,
		})
		if err != nil {
			t.Fatal(err)
		}
		request := httptest.NewRequest(http.MethodPost, "/api/v1/users/"+userID+"/devices", bytes.NewReader(body))
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, request)
		return response
	}

	first := register(env.token, env.user.ID, "first", identityKey, envelopeKey)
	if first.Code != http.StatusOK {
		t.Fatalf("first registration = %d, body = %s", first.Code, first.Body.String())
	}
	second := register(env.token, env.user.ID, "updated", identityKey, envelopeKey)
	if second.Code != http.StatusOK {
		t.Fatalf("repeat registration = %d, body = %s", second.Code, second.Body.String())
	}
	var saved store.Device
	if err := json.Unmarshal(second.Body.Bytes(), &saved); err != nil {
		t.Fatal(err)
	}
	if saved.ID != deviceID || saved.Label != "updated" || saved.IdentityPublicKey != identityKey {
		t.Fatalf("saved device = %#v", saved)
	}
	changedKey := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{3}, 32))
	keyReplacement := register(env.token, env.user.ID, "replaced", changedKey, envelopeKey)
	if keyReplacement.Code != http.StatusConflict {
		t.Fatalf("key replacement = %d, body = %s", keyReplacement.Code, keyReplacement.Body.String())
	}

	other, err := env.repo.CreateUser(context.Background(), "Other")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(context.Background(), env.os.ID, other.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	otherToken, _, err := auth.CreateToken(env.server.cfg.JWTSecret, auth.Claims{Subject: other.ID}, env.server.cfg.JWTTTL)
	if err != nil {
		t.Fatal(err)
	}
	conflict := register(otherToken, other.ID, "stolen", identityKey, envelopeKey)
	if conflict.Code != http.StatusConflict {
		t.Fatalf("device theft = %d, body = %s", conflict.Code, conflict.Body.String())
	}
	invalid := register(env.token, env.user.ID, "invalid", "not-a-key", envelopeKey)
	if invalid.Code != http.StatusBadRequest {
		t.Fatalf("invalid key = %d, body = %s", invalid.Code, invalid.Body.String())
	}
	invalidX25519 := register(
		env.token,
		env.user.ID,
		"invalid-x25519",
		identityKey,
		base64.RawURLEncoding.EncodeToString(make([]byte, 32)),
	)
	if invalidX25519.Code != http.StatusBadRequest {
		t.Fatalf("invalid X25519 key = %d, body = %s", invalidX25519.Code, invalidX25519.Body.String())
	}
}

func TestLoginUsesServerPasswordAndLocalDisplayName(t *testing.T) {
	ctx := context.Background()
	tempDir := t.TempDir()
	db, err := database.OpenSQLite(ctx, filepath.Join(tempDir, "openspeak.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	repo := store.NewSQLite(db)
	osServer, err := repo.CreateServer(ctx, store.OSServer{
		Name:                 "Test Server",
		EncryptionMode:       "transport",
		FileRoot:             filepath.Join(tempDir, "files"),
		HistoryRetentionDays: 30,
	})
	if err != nil {
		t.Fatal(err)
	}
	passwordHash, err := auth.HashSecret("1234")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.UpdateServer(ctx, osServer.ID, nil, nil, nil, nil, &passwordHash, nil, nil, nil, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	hub := realtime.NewHub()
	hubContext, cancelHub := context.WithCancel(context.Background())
	go hub.Run(hubContext)
	t.Cleanup(cancelHub)
	server := NewServer(config.Config{
		JWTSecret: "test-secret",
		JWTTTL:    time.Hour,
	}, repo, hub)

	badReq := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"display_name":"Kanami","password":"wrong"}`))
	badReq.Header.Set("Content-Type", "application/json")
	badResp := httptest.NewRecorder()
	server.ServeHTTP(badResp, badReq)
	if badResp.Code != http.StatusUnauthorized {
		t.Fatalf("bad login status = %d, body = %s", badResp.Code, badResp.Body.String())
	}

	legacyReq := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"username":"Kanami","password":"1234"}`))
	legacyReq.Header.Set("Content-Type", "application/json")
	legacyResp := httptest.NewRecorder()
	server.ServeHTTP(legacyResp, legacyReq)
	if legacyResp.Code != http.StatusBadRequest {
		t.Fatalf("username-only login status = %d, body = %s", legacyResp.Code, legacyResp.Body.String())
	}

	goodReq := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"display_name":"Kanami","password":"1234"}`))
	goodReq.Header.Set("Content-Type", "application/json")
	goodResp := httptest.NewRecorder()
	server.ServeHTTP(goodResp, goodReq)
	if goodResp.Code != http.StatusOK {
		t.Fatalf("good login status = %d, body = %s", goodResp.Code, goodResp.Body.String())
	}
	var result struct {
		Token string     `json:"token"`
		User  store.User `json:"user"`
	}
	if err := json.Unmarshal(goodResp.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Token == "" || result.User.DisplayName != "Kanami" {
		t.Fatalf("unexpected login result: %#v", result)
	}
	members, err := repo.ListServerMembers(ctx, osServer.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(members) != 1 || members[0].UserID != result.User.ID || members[0].Role != store.RoleUser {
		t.Fatalf("members = %#v, user = %#v", members, result.User)
	}
}

func TestRolePermissionTemplateIsAuthoritativeForChannelMessages(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	ctx := context.Background()
	member, err := env.repo.CreateUser(ctx, "Member")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(ctx, env.os.ID, member.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	if err := env.repo.AddChannelMember(ctx, env.channel.ID, member.ID, "member"); err != nil {
		t.Fatal(err)
	}
	token := mustToken(t, env.server.cfg, member.ID)

	send := func(body string, want int) {
		t.Helper()
		request := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/messages", strings.NewReader(`{"kind":"text","encryption_mode":"none","body":"`+body+`"}`))
		request.Header.Set("Authorization", "Bearer "+token)
		request.Header.Set("Content-Type", "application/json")
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, request)
		if response.Code != want {
			t.Fatalf("send status = %d, want %d, body = %s", response.Code, want, response.Body.String())
		}
	}

	send("hello", http.StatusOK)
	if _, err := env.repo.SetServerRolePermissions(ctx, env.os.ID, store.AdminPermissions(), []string{store.PermissionChannelMessagesSendText}, env.user.ID); err != nil {
		t.Fatal(err)
	}
	send("https://openspeak.example", http.StatusOK)
	if _, err := env.repo.SetServerRolePermissions(ctx, env.os.ID, store.AdminPermissions(), []string{store.PermissionChannelMessagesView}, env.user.ID); err != nil {
		t.Fatal(err)
	}
	send("hello", http.StatusForbidden)
}

func TestChannelAccessOnlyGrantsMembershipWithoutEnteringVoice(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	ctx := context.Background()
	member, err := env.repo.CreateUser(ctx, "Member")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(ctx, env.os.ID, member.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	token := mustToken(t, env.server.cfg, member.ID)
	requestMessages := func() *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodGet, "/api/v1/channels/"+env.channel.ID+"/messages", nil)
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, request)
		return response
	}
	requestAccess := func() *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/join", strings.NewReader(`{"user_id":"`+member.ID+`","role":"admin","access_only":true}`))
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, request)
		return response
	}

	if response := requestMessages(); response.Code != http.StatusForbidden {
		t.Fatalf("messages before access = %d, body = %s", response.Code, response.Body.String())
	}
	if response := requestAccess(); response.Code != http.StatusOK {
		t.Fatalf("access = %d, body = %s", response.Code, response.Body.String())
	}
	if _, ok := env.hub.CurrentChannel(env.os.ID, member.ID); ok {
		t.Fatal("access-only request entered the voice channel")
	}
	hasAccess, err := env.repo.IsChannelMemberOrOwnerOrAdmin(ctx, env.channel.ID, member.ID)
	if err != nil || !hasAccess {
		t.Fatalf("channel access = %v, err = %v", hasAccess, err)
	}
	members, err := env.repo.ListChannelMembers(ctx, env.channel.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, channelMember := range members {
		if channelMember.UserID == member.ID && channelMember.Role != "member" {
			t.Fatalf("access-only role = %q", channelMember.Role)
		}
	}
	latest, err := env.repo.GetLatestEpoch(ctx, env.channel.ID)
	if err != nil || latest.EpochNumber != env.epoch.EpochNumber+1 || latest.Reason != "access_granted" {
		t.Fatalf("access epoch = %#v, err = %v", latest, err)
	}
	if response := requestMessages(); response.Code != http.StatusOK {
		t.Fatalf("messages after access = %d, body = %s", response.Code, response.Body.String())
	}
	if response := requestAccess(); response.Code != http.StatusOK {
		t.Fatalf("repeated access = %d, body = %s", response.Code, response.Body.String())
	}
	unchanged, err := env.repo.GetLatestEpoch(ctx, env.channel.ID)
	if err != nil || unchanged.ID != latest.ID {
		t.Fatalf("repeated access rotated epoch = %#v, err = %v", unchanged, err)
	}
	if _, err := env.repo.SetServerRolePermissions(ctx, env.os.ID, store.AdminPermissions(), []string{}, env.user.ID); err != nil {
		t.Fatal(err)
	}
	if response := requestAccess(); response.Code != http.StatusForbidden {
		t.Fatalf("access without view permission = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestChannelMessageDeleteAllowsOwnMessageOrManagePermission(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	ctx := context.Background()
	if minutes, err := env.repo.GetMessageRetractWindowMinutes(ctx, env.os.ID); err != nil || minutes != 30 {
		t.Fatalf("default retract window = %d, %v", minutes, err)
	}
	member, err := env.repo.CreateUser(ctx, "Member")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(ctx, env.os.ID, member.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	if err := env.repo.AddChannelMember(ctx, env.channel.ID, member.ID, "member"); err != nil {
		t.Fatal(err)
	}
	memberToken := mustToken(t, env.server.cfg, member.ID)
	storeMessage := func(senderID, body string) store.ChannelMessage {
		t.Helper()
		message, err := env.repo.StoreChannelMessage(ctx, store.ChannelMessage{
			ChannelID: env.channel.ID, SenderUserID: senderID, Kind: "text",
			EncryptionMode: "none", Body: body,
		})
		if err != nil {
			t.Fatal(err)
		}
		return message
	}
	deleteMessage := func(token, messageID, action string) int {
		t.Helper()
		path := "/api/v1/channels/" + env.channel.ID + "/messages/" + messageID
		if action != "" {
			path += "?action=" + action
		}
		req := httptest.NewRequest(http.MethodDelete, path, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, req)
		return response.Code
	}

	ownerMessage := storeMessage(env.user.ID, "owner message")
	if status := deleteMessage(memberToken, ownerMessage.ID, "delete"); status != http.StatusForbidden {
		t.Fatalf("delete another member's message without permission = %d", status)
	}
	memberMessage := storeMessage(member.ID, "member message")
	if status := deleteMessage(memberToken, memberMessage.ID, "retract"); status != http.StatusOK {
		t.Fatalf("retract own message = %d", status)
	}
	retracted, err := env.repo.GetChannelMessage(ctx, memberMessage.ID)
	if err != nil || retracted.Kind != "removed" || retracted.Body != "" || retracted.Metadata["removal_kind"] != "retracted" {
		t.Fatalf("retracted tombstone = %#v, %v", retracted, err)
	}
	expiredMessage := storeMessage(member.ID, "expired member message")
	if _, err := env.db.ExecContext(ctx, `UPDATE channel_messages SET created_at = datetime('now', '-31 minutes') WHERE id = ?`, expiredMessage.ID); err != nil {
		t.Fatal(err)
	}
	if status := deleteMessage(memberToken, expiredMessage.ID, "retract"); status != http.StatusForbidden {
		t.Fatalf("retract expired own message = %d", status)
	}
	if _, err := env.repo.SetServerRolePermissions(ctx, env.os.ID, store.AdminPermissions(), []string{
		store.PermissionChannelMessagesView,
		store.PermissionChannelMessagesManage,
	}, env.user.ID); err != nil {
		t.Fatal(err)
	}
	if status := deleteMessage(memberToken, ownerMessage.ID, "delete"); status != http.StatusOK {
		t.Fatalf("delete another member's message with manage permission = %d", status)
	}
	deleted, err := env.repo.GetChannelMessage(ctx, ownerMessage.ID)
	if err != nil || deleted.Metadata["removal_kind"] != "deleted" {
		t.Fatalf("moderator tombstone = %#v, %v", deleted, err)
	}
	if status := deleteMessage(memberToken, expiredMessage.ID, "delete"); status != http.StatusOK {
		t.Fatalf("delete expired own message with manage permission = %d", status)
	}
	deletedOwn, err := env.repo.GetChannelMessage(ctx, expiredMessage.ID)
	if err != nil || deletedOwn.Metadata["removal_kind"] != "deleted" {
		t.Fatalf("moderator deleting own expired message tombstone = %#v, %v", deletedOwn, err)
	}
	freshOwn := storeMessage(member.ID, "fresh moderator message")
	if status := deleteMessage(memberToken, freshOwn.ID, "delete"); status != http.StatusOK {
		t.Fatalf("delete fresh own message explicitly as moderator = %d", status)
	}
	deletedFreshOwn, err := env.repo.GetChannelMessage(ctx, freshOwn.ID)
	if err != nil || deletedFreshOwn.Metadata["removal_kind"] != "deleted" {
		t.Fatalf("explicit moderator deletion tombstone = %#v, %v", deletedFreshOwn, err)
	}
}

func TestAccountRegistrationRoutesAreRemoved(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	for _, path := range []string{"/api/v1/auth/init", "/api/v1/auth/register"} {
		req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(`{}`))
		req.Header.Set("Content-Type", "application/json")
		resp := httptest.NewRecorder()
		env.server.ServeHTTP(resp, req)
		if resp.Code != http.StatusNotFound {
			t.Fatalf("%s status = %d, body = %s", path, resp.Code, resp.Body.String())
		}
	}
}

func TestClientInstallationReusesMemberRoleAndSupportsBan(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	const installationID = "550e8400-e29b-41d4-a716-446655440000"

	login := func(displayName string) (*httptest.ResponseRecorder, store.User) {
		body := `{"display_name":"` + displayName + `","password":"","client_installation_id":"` + installationID + `"}`
		req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, req)
		var result struct {
			User store.User `json:"user"`
		}
		if response.Code == http.StatusOK {
			if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
				t.Fatal(err)
			}
		}
		return response, result.User
	}

	firstResponse, firstUser := login("First Name")
	if firstResponse.Code != http.StatusOK {
		t.Fatalf("first login = %d, body = %s", firstResponse.Code, firstResponse.Body.String())
	}

	if _, err := env.repo.SetServerMember(
		context.Background(), env.os.ID, firstUser.ID,
		store.RoleAdmin, store.AdminPermissions(),
	); err != nil {
		t.Fatal(err)
	}

	secondResponse, secondUser := login("Second Name")
	if secondResponse.Code != http.StatusOK || secondUser.ID != firstUser.ID {
		t.Fatalf("second login = %d, first = %#v, second = %#v", secondResponse.Code, firstUser, secondUser)
	}
	member, err := env.repo.GetServerMember(context.Background(), env.os.ID, firstUser.ID)
	if err != nil || member.Role != store.RoleAdmin || len(member.Permissions) == 0 {
		t.Fatalf("stable member role = %#v, err = %v", member, err)
	}

	manageRequest := httptest.NewRequest(http.MethodGet, "/api/v1/servers/"+env.os.ID+"/members/manage", nil)
	manageRequest.Header.Set("Authorization", "Bearer "+env.token)
	manageResponse := httptest.NewRecorder()
	env.server.ServeHTTP(manageResponse, manageRequest)
	if manageResponse.Code != http.StatusOK {
		t.Fatalf("manage list = %d, body = %s", manageResponse.Code, manageResponse.Body.String())
	}
	var managed []store.ManagedServerMember
	if err := json.Unmarshal(manageResponse.Body.Bytes(), &managed); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, item := range managed {
		if item.UserID == firstUser.ID {
			found = item.DisplayName == "Second Name" && !item.Legacy && item.Role == store.RoleAdmin
		}
	}
	if !found {
		t.Fatalf("managed members = %#v", managed)
	}

	banRequest := httptest.NewRequest(
		http.MethodPost,
		"/api/v1/servers/"+env.os.ID+"/members/"+firstUser.ID+"/ban",
		strings.NewReader(`{"reason":"test ban","duration_seconds":3600}`),
	)
	banRequest.Header.Set("Authorization", "Bearer "+env.token)
	banRequest.Header.Set("Content-Type", "application/json")
	banResponse := httptest.NewRecorder()
	env.server.ServeHTTP(banResponse, banRequest)
	if banResponse.Code != http.StatusOK {
		t.Fatalf("ban = %d, body = %s", banResponse.Code, banResponse.Body.String())
	}

	bannedResponse, _ := login("Third Name")
	if bannedResponse.Code != http.StatusForbidden || !strings.Contains(bannedResponse.Body.String(), "test ban") {
		t.Fatalf("banned login = %d, body = %s", bannedResponse.Code, bannedResponse.Body.String())
	}

	unbanRequest := httptest.NewRequest(http.MethodDelete, "/api/v1/servers/"+env.os.ID+"/members/"+firstUser.ID+"/ban", nil)
	unbanRequest.Header.Set("Authorization", "Bearer "+env.token)
	unbanResponse := httptest.NewRecorder()
	env.server.ServeHTTP(unbanResponse, unbanRequest)
	if unbanResponse.Code != http.StatusOK {
		t.Fatalf("unban = %d, body = %s", unbanResponse.Code, unbanResponse.Body.String())
	}
	finalResponse, finalUser := login("Final Name")
	if finalResponse.Code != http.StatusOK || finalUser.ID != firstUser.ID {
		t.Fatalf("final login = %d, user = %#v", finalResponse.Code, finalUser)
	}
}

func TestUpdateCurrentUserDisplayName(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	req := httptest.NewRequest(
		http.MethodPatch,
		"/api/v1/users/me",
		strings.NewReader(`{"display_name":"Renamed User"}`),
	)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+env.token)
	resp := httptest.NewRecorder()
	env.server.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("update display name status = %d, body = %s", resp.Code, resp.Body.String())
	}
	var result store.User
	if err := json.Unmarshal(resp.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.ID != env.user.ID || result.DisplayName != "Renamed User" {
		t.Fatalf("updated user = %#v", result)
	}
	persisted, err := env.repo.GetUser(context.Background(), env.user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if persisted.DisplayName != "Renamed User" {
		t.Fatalf("persisted display name = %q", persisted.DisplayName)
	}
}

func TestForceMuteAndDeafenReturnSingleJSONResponse(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	target, err := env.repo.CreateUser(context.Background(), "Target")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(context.Background(), env.os.ID, target.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}

	for _, action := range []string{"mute", "deafen"} {
		t.Run(action, func(t *testing.T) {
			env.hub.SetVoiceState(realtime.VoiceState{
				ServerID: env.os.ID, UserID: target.ID, DisplayName: target.DisplayName,
				ChannelID: env.channel.ID,
			})
			req := httptest.NewRequest(
				http.MethodPost,
				"/api/v1/servers/"+env.os.ID+"/members/"+target.ID+"/"+action,
				nil,
			)
			req.Header.Set("Authorization", "Bearer "+env.token)
			response := httptest.NewRecorder()
			env.server.ServeHTTP(response, req)
			if response.Code != http.StatusOK {
				t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
			}
			var state realtime.VoiceState
			if err := json.Unmarshal(response.Body.Bytes(), &state); err != nil {
				t.Fatalf("response is not one JSON value: %v, body = %q", err, response.Body.String())
			}
			if !state.Muted || action == "deafen" && !state.Deafened {
				t.Fatalf("voice state = %#v", state)
			}
		})
	}
}

func TestDeleteChannelRejectsLastChannel(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	deleteChannel := func(channelID string) *httptest.ResponseRecorder {
		t.Helper()
		request := httptest.NewRequest(http.MethodDelete, "/api/v1/channels/"+channelID, nil)
		request.Header.Set("Authorization", "Bearer "+env.token)
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, request)
		return response
	}

	response := deleteChannel(env.channel.ID)
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), `"error":"last_channel"`) {
		t.Fatalf("delete last channel = %d, body = %s", response.Code, response.Body.String())
	}
	channels, err := env.repo.ListChannels(context.Background(), env.os.ID)
	if err != nil || len(channels) != 1 || channels[0].ID != env.channel.ID {
		t.Fatalf("channels after rejected delete = %#v, err = %v", channels, err)
	}

	second, err := env.repo.CreateChannel(context.Background(), store.Channel{
		ServerID: env.os.ID,
		Name:     "Second",
	})
	if err != nil {
		t.Fatal(err)
	}
	response = deleteChannel(second.ID)
	if response.Code != http.StatusOK {
		t.Fatalf("delete non-last channel = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestUploadCurrentUserAvatarCreatesOriginalAndThumbnail(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	avatar := image.NewRGBA(image.Rect(0, 0, 2, 2))
	avatar.Set(0, 0, color.RGBA{R: 255, A: 255})
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, avatar); err != nil {
		t.Fatal(err)
	}
	pngData := encoded.Bytes()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("avatar", "avatar.png")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(pngData); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPut, "/api/v1/users/me/avatar", &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+env.token)
	resp := httptest.NewRecorder()
	env.server.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("upload status = %d, body = %s", resp.Code, resp.Body.String())
	}
	var user store.User
	if err := json.Unmarshal(resp.Body.Bytes(), &user); err != nil {
		t.Fatal(err)
	}
	if user.AvatarVersion != 1 || user.AvatarHash == "" {
		t.Fatalf("avatar metadata = %#v", user)
	}

	for _, path := range []string{
		"/api/v1/users/" + user.ID + "/avatar?v=1",
		"/api/v1/users/" + user.ID + "/avatar?size=small&v=1",
	} {
		getResp := httptest.NewRecorder()
		env.server.ServeHTTP(getResp, httptest.NewRequest(http.MethodGet, path, nil))
		if getResp.Code != http.StatusOK || getResp.Body.Len() == 0 {
			t.Fatalf("GET %s = %d (%d bytes)", path, getResp.Code, getResp.Body.Len())
		}
		if !strings.HasPrefix(getResp.Header().Get("Content-Type"), "image/") {
			t.Fatalf("GET %s content type = %q", path, getResp.Header().Get("Content-Type"))
		}
		if strings.Contains(path, "size=small") {
			if getResp.Header().Get("Content-Type") != "image/png" {
				t.Fatalf("small avatar content type = %q", getResp.Header().Get("Content-Type"))
			}
			thumbnail, err := png.Decode(bytes.NewReader(getResp.Body.Bytes()))
			if err != nil {
				t.Fatal(err)
			}
			_, _, _, alpha := thumbnail.At(avatarThumbnailSize-1, avatarThumbnailSize-1).RGBA()
			if alpha != 0 {
				t.Fatalf("transparent thumbnail pixel alpha = %d", alpha)
			}
		}
	}

	// Existing installations only have the old JPEG thumbnail. The first
	// small-avatar read must rebuild a transparent PNG from the saved original.
	thumbnailPath := filepath.Join(env.server.cfg.FileRoot, "avatars", user.ID, "small.png")
	if err := os.Remove(thumbnailPath); err != nil {
		t.Fatal(err)
	}
	lazyResp := httptest.NewRecorder()
	env.server.ServeHTTP(lazyResp, httptest.NewRequest(http.MethodGet, "/api/v1/users/"+user.ID+"/avatar?size=small&v=1", nil))
	if lazyResp.Code != http.StatusOK || lazyResp.Header().Get("Content-Type") != "image/png" {
		t.Fatalf("lazy thumbnail response = %d, %q", lazyResp.Code, lazyResp.Header().Get("Content-Type"))
	}
}

func TestUploadServerAvatarUpdatesMetadataAndServesThumbnail(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	avatar := image.NewRGBA(image.Rect(0, 0, 2, 2))
	avatar.Set(0, 0, color.RGBA{G: 255, A: 255})
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, avatar); err != nil {
		t.Fatal(err)
	}
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("avatar", "server.png")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(encoded.Bytes()); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPut, "/api/v1/servers/"+env.os.ID+"/avatar", &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+env.token)
	resp := httptest.NewRecorder()
	env.server.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("upload status = %d, body = %s", resp.Code, resp.Body.String())
	}
	var server store.OSServer
	if err := json.Unmarshal(resp.Body.Bytes(), &server); err != nil {
		t.Fatal(err)
	}
	if server.AvatarVersion != 1 || server.AvatarHash == "" {
		t.Fatalf("avatar metadata = %#v", server)
	}

	getResp := httptest.NewRecorder()
	env.server.ServeHTTP(getResp, httptest.NewRequest(
		http.MethodGet,
		"/api/v1/servers/"+server.ID+"/avatar?size=small&v=1",
		nil,
	))
	if getResp.Code != http.StatusOK || getResp.Header().Get("Content-Type") != "image/png" {
		t.Fatalf("thumbnail response = %d, %q", getResp.Code, getResp.Header().Get("Content-Type"))
	}
}

func TestParseLinkPreviewHTML(t *testing.T) {
	base, err := url.Parse("https://example.com/articles/post")
	if err != nil {
		t.Fatal(err)
	}
	preview := parseLinkPreviewHTML(`
		<html>
			<head>
				<title>Fallback Title</title>
				<meta name="description" content="Fallback description">
				<meta name="twitter:title" content="Twitter Title">
				<meta property="og:title" content="OG Title">
				<meta property="og:description" content="OG Description">
				<meta property="og:image" content="/cover.jpg">
			</head>
		</html>
	`, base)
	if preview.Title != "OG Title" {
		t.Fatalf("title = %q", preview.Title)
	}
	if preview.Description != "OG Description" {
		t.Fatalf("description = %q", preview.Description)
	}
	if preview.ImageURL != "https://example.com/cover.jpg" {
		t.Fatalf("image = %q", preview.ImageURL)
	}
}

func TestFallbackLinkPreviewForKnownSites(t *testing.T) {
	target, err := url.Parse("https://www.youtube.com")
	if err != nil {
		t.Fatal(err)
	}
	preview := fallbackLinkPreview(target)
	if preview.Title != "YouTube" {
		t.Fatalf("title = %q", preview.Title)
	}
	if !strings.Contains(preview.Description, "Enjoy the videos and music") {
		t.Fatalf("description = %q", preview.Description)
	}
	if preview.ImageURL == "" {
		t.Fatal("expected favicon image url")
	}
}

func TestLinkPreviewRejectsLocalhost(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	req := httptest.NewRequest(http.MethodGet, "/api/v1/link-preview?url=http://127.0.0.1:27410/private", nil)
	req.Header.Set("Authorization", "Bearer "+env.token)
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, req)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestChannelFileUploadUsesServerE2EE(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	_ = writer.WriteField("encryption_mode", "e2ee")
	_ = writer.WriteField("epoch_id", env.epoch.ID)
	_ = writer.WriteField("nonce", "AAAAAAAAAAA")
	_ = writer.WriteField("plaintext_size_bytes", "22")
	_ = writer.WriteField("attachment_format", attachmentEncryptionFormatV1)
	_ = writer.WriteField("chunk_size", strconv.FormatInt(attachmentEncryptionChunkSize, 10))
	_ = writer.WriteField("original_name", "音乐 文档 2026.zip")
	part, err := writer.CreateFormFile("file", "fallback.bin")
	if err != nil {
		t.Fatal(err)
	}
	ciphertext := bytes.Repeat([]byte{7}, int(encryptedAttachmentSize(22, attachmentEncryptionChunkSize)))
	if _, err := part.Write(ciphertext); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/files", &body)
	req.Header.Set("Authorization", "Bearer "+env.token)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, req)
	if response.Code != http.StatusOK {
		t.Fatalf("upload status = %d, body = %s", response.Code, response.Body.String())
	}
	var result struct {
		File    store.StoredFile     `json:"file"`
		Message store.ChannelMessage `json:"message"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.File.Kind != "channel_file" || result.Message.Kind != "file" {
		t.Fatalf("unexpected kinds: file=%q message=%q", result.File.Kind, result.Message.Kind)
	}
	if result.File.OriginalName != "音乐 文档 2026.zip" || result.Message.Metadata["original_name"] != "音乐 文档 2026.zip" {
		t.Fatalf("original filename was not preserved: file=%q metadata=%#v", result.File.OriginalName, result.Message.Metadata)
	}
	if result.File.EncryptionMode != "e2ee" || result.Message.EncryptionMode != "e2ee" {
		t.Fatalf("server mode was not enforced: file=%q message=%q", result.File.EncryptionMode, result.Message.EncryptionMode)
	}
	if result.Message.EpochID == nil || *result.Message.EpochID != env.epoch.ID || result.Message.Nonce != "AAAAAAAAAAA" {
		t.Fatalf("missing E2EE metadata: %#v", result.Message)
	}
	if result.Message.Metadata["size_bytes"] != "22" || result.Message.Metadata["ciphertext_size_bytes"] != strconv.Itoa(len(ciphertext)) || result.Message.Metadata["attachment_format"] != attachmentEncryptionFormatV1 {
		t.Fatalf("invalid E2EE attachment metadata: %#v", result.Message.Metadata)
	}
	if !strings.Contains(result.File.RelativePath, "/channel-files/") {
		t.Fatalf("unexpected relative path %q", result.File.RelativePath)
	}

	download := httptest.NewRequest(http.MethodGet, "/api/v1/files/"+result.File.ID+"/download", nil)
	download.Header.Set("Authorization", "Bearer "+env.token)
	downloadResponse := newDeadlineResponseRecorder()
	env.server.ServeHTTP(downloadResponse, download)
	if downloadResponse.Code != http.StatusOK {
		t.Fatalf("download status = %d, body = %s", downloadResponse.Code, downloadResponse.Body.String())
	}
	if !bytes.Equal(downloadResponse.Body.Bytes(), ciphertext) {
		t.Fatalf("downloaded payload = %q", downloadResponse.Body.Bytes())
	}
	if !downloadResponse.writeTimeoutDisabled() {
		t.Fatalf("download write deadline was not disabled: %#v", downloadResponse.writeDeadlines)
	}
	if disposition := downloadResponse.Header().Get("Content-Disposition"); !strings.Contains(disposition, `filename*=UTF-8''`) || !strings.Contains(disposition, "%E9%9F%B3%E4%B9%90%20%E6%96%87%E6%A1%A3%202026.zip") {
		t.Fatalf("download disposition = %q", disposition)
	}
}

func TestExternalChannelAttachmentUploadAndDownloadRedirect(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	secret := "external-node-secret"
	nodeRoot := t.TempDir()
	fileNode := &filenode.Server{Root: nodeRoot, Secret: secret}
	nodeServer := httptest.NewTLSServer(fileNode)
	defer nodeServer.Close()
	defaultTransport := http.DefaultTransport
	http.DefaultTransport = nodeServer.Client().Transport
	t.Cleanup(func() { http.DefaultTransport = defaultTransport })
	node, err := env.repo.CreateFileNode(context.Background(), store.FileNode{ServerID: env.os.ID, Name: "external", BaseURL: nodeServer.URL, Secret: secret, Enabled: true})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	if _, err := env.repo.UpdateServer(context.Background(), env.os.ID, nil, nil, nil, nil, nil, nil, nil, &enabled, &node.ID, nil, nil); err != nil {
		t.Fatal(err)
	}
	const plaintextSize = 27
	payload := bytes.Repeat([]byte{9}, int(encryptedAttachmentSize(plaintextSize, attachmentEncryptionChunkSize)))
	initBody := `{"channel_id":"` + env.channel.ID + `","kind":"file","encryption_mode":"e2ee","epoch_id":"` + env.epoch.ID + `","nonce":"AAAAAAAAAAA","plaintext_size_bytes":27,"attachment_format":"` + attachmentEncryptionFormatV1 + `","chunk_size":65536,"original_name":"music.flac","content_type":"audio/flac","size_bytes":` + strconv.Itoa(len(payload)) + `}`
	initRequest := httptest.NewRequest(http.MethodPost, "/api/v1/attachment-uploads", strings.NewReader(initBody))
	initRequest.Header.Set("Authorization", "Bearer "+env.token)
	initResponse := httptest.NewRecorder()
	env.server.ServeHTTP(initResponse, initRequest)
	if initResponse.Code != http.StatusOK {
		t.Fatalf("init status = %d, body = %s", initResponse.Code, initResponse.Body.String())
	}
	var plan struct {
		External        bool   `json:"external"`
		UploadURL       string `json:"upload_url"`
		CompletionToken string `json:"completion_token"`
	}
	if err := json.Unmarshal(initResponse.Body.Bytes(), &plan); err != nil {
		t.Fatal(err)
	}
	if !plan.External || plan.UploadURL == "" || plan.CompletionToken == "" {
		t.Fatalf("invalid external plan: %#v", plan)
	}
	uploadRequest, err := http.NewRequest(http.MethodPut, plan.UploadURL, bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	uploadRequest.ContentLength = int64(len(payload))
	uploadResponse, err := http.DefaultClient.Do(uploadRequest)
	if err != nil {
		t.Fatal(err)
	}
	uploadResponse.Body.Close()
	if uploadResponse.StatusCode != http.StatusOK {
		t.Fatalf("node upload status = %d", uploadResponse.StatusCode)
	}
	completeBody, _ := json.Marshal(map[string]string{"completion_token": plan.CompletionToken})
	completeRequest := httptest.NewRequest(http.MethodPost, "/api/v1/attachment-uploads/complete", bytes.NewReader(completeBody))
	completeRequest.Header.Set("Authorization", "Bearer "+env.token)
	completeResponse := httptest.NewRecorder()
	env.server.ServeHTTP(completeResponse, completeRequest)
	if completeResponse.Code != http.StatusOK {
		t.Fatalf("complete status = %d, body = %s", completeResponse.Code, completeResponse.Body.String())
	}
	var result struct {
		File store.StoredFile `json:"file"`
	}
	if err := json.Unmarshal(completeResponse.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.File.FileNodeID == nil || *result.File.FileNodeID != node.ID {
		t.Fatalf("file node was not persisted: %#v", result.File)
	}
	if result.File.EncryptionMode != "e2ee" || result.File.Metadata["plaintext_size_bytes"] != "27" {
		t.Fatalf("external E2EE metadata = %#v", result.File)
	}
	downloadRequest := httptest.NewRequest(http.MethodGet, "/api/v1/files/"+result.File.ID+"/download", nil)
	downloadRequest.Header.Set("Authorization", "Bearer "+env.token)
	downloadResponse := httptest.NewRecorder()
	env.server.ServeHTTP(downloadResponse, downloadRequest)
	if downloadResponse.Code != http.StatusTemporaryRedirect || !strings.HasPrefix(downloadResponse.Header().Get("Location"), nodeServer.URL) {
		t.Fatalf("download redirect = %d %q", downloadResponse.Code, downloadResponse.Header().Get("Location"))
	}
	if removed, err := fileNode.CleanupOrphans(time.Now().Add(20 * time.Minute)); err != nil || removed != 0 {
		t.Fatalf("completed upload cleanup removed=%d err=%v", removed, err)
	}
	if _, err := os.Stat(filepath.Join(nodeRoot, result.File.ObjectKey)); err != nil {
		t.Fatalf("completed external object is missing: %v", err)
	}
	if err := env.server.CleanupRetainedFile(context.Background(), result.File); err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.GetFile(context.Background(), result.File.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("cleaned file record still exists: %v", err)
	}
	if _, err := os.Stat(filepath.Join(nodeRoot, result.File.ObjectKey)); !os.IsNotExist(err) {
		t.Fatalf("cleaned external object still exists: %v", err)
	}
}

func TestAttachmentUploadFileLimitsAndExpiry(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	initUpload := func(size int64) *httptest.ResponseRecorder {
		t.Helper()
		body, err := json.Marshal(map[string]any{
			"channel_id":      env.channel.ID,
			"kind":            "file",
			"original_name":   "large.bin",
			"content_type":    "application/octet-stream",
			"size_bytes":      size,
			"encryption_mode": "none",
		})
		if err != nil {
			t.Fatal(err)
		}
		request := httptest.NewRequest(http.MethodPost, "/api/v1/attachment-uploads", bytes.NewReader(body))
		request.Header.Set("Authorization", "Bearer "+env.token)
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, request)
		return response
	}

	localResponse := initUpload(maxLocalAttachmentFileSize)
	if localResponse.Code != http.StatusOK {
		t.Fatalf("local maximum status = %d, body = %s", localResponse.Code, localResponse.Body.String())
	}
	var localPlan struct {
		External      bool  `json:"external"`
		LocalMaxBytes int64 `json:"local_max_bytes"`
	}
	if err := json.Unmarshal(localResponse.Body.Bytes(), &localPlan); err != nil {
		t.Fatal(err)
	}
	if localPlan.External || localPlan.LocalMaxBytes != maxLocalAttachmentFileSize {
		t.Fatalf("local plan = %#v", localPlan)
	}
	if response := initUpload(maxLocalAttachmentFileSize + 1); response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized local status = %d, body = %s", response.Code, response.Body.String())
	}

	node, err := env.repo.CreateFileNode(context.Background(), store.FileNode{
		ServerID: env.os.ID,
		Name:     "external",
		BaseURL:  "https://files.example.com",
		Secret:   "external-node-secret",
		Enabled:  true,
	})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	if _, err := env.repo.UpdateServer(context.Background(), env.os.ID, nil, nil, nil, nil, nil, nil, nil, &enabled, &node.ID, nil, nil); err != nil {
		t.Fatal(err)
	}

	externalResponse := initUpload(maxExternalAttachmentFileSize)
	if externalResponse.Code != http.StatusOK {
		t.Fatalf("external maximum status = %d, body = %s", externalResponse.Code, externalResponse.Body.String())
	}
	var externalPlan struct {
		External        bool   `json:"external"`
		UploadURL       string `json:"upload_url"`
		CompletionToken string `json:"completion_token"`
		LocalMaxBytes   int64  `json:"local_max_bytes"`
	}
	if err := json.Unmarshal(externalResponse.Body.Bytes(), &externalPlan); err != nil {
		t.Fatal(err)
	}
	if !externalPlan.External || externalPlan.LocalMaxBytes != maxLocalAttachmentFileSize {
		t.Fatalf("external plan = %#v", externalPlan)
	}
	uploadURL, err := url.Parse(externalPlan.UploadURL)
	if err != nil {
		t.Fatal(err)
	}
	if uploadURL.Query().Get("max") != strconv.FormatInt(maxExternalAttachmentFileSize, 10) {
		t.Fatalf("external ticket maximum = %q", uploadURL.Query().Get("max"))
	}
	ticketExpiry, err := strconv.ParseInt(uploadURL.Query().Get("exp"), 10, 64)
	if err != nil {
		t.Fatal(err)
	}
	if remaining := time.Until(time.Unix(ticketExpiry, 0)); remaining < 59*time.Minute || remaining > 61*time.Minute {
		t.Fatalf("external ticket expiry remaining = %s", remaining)
	}
	completionClaims, err := auth.ParseToken(env.server.cfg.JWTSecret, externalPlan.CompletionToken)
	if err != nil {
		t.Fatal(err)
	}
	if lifetime := time.Duration(completionClaims.Expires-completionClaims.IssuedAt) * time.Second; lifetime != 60*time.Minute {
		t.Fatalf("completion token lifetime = %s", lifetime)
	}
	if response := initUpload(maxExternalAttachmentFileSize + 1); response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized external status = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestExternalChannelAttachmentRejectsEncryptionModeChange(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	secret := "external-node-secret"
	fileNode := &filenode.Server{Root: t.TempDir(), Secret: secret}
	nodeServer := httptest.NewTLSServer(fileNode)
	defer nodeServer.Close()
	defaultTransport := http.DefaultTransport
	http.DefaultTransport = nodeServer.Client().Transport
	t.Cleanup(func() { http.DefaultTransport = defaultTransport })
	node, err := env.repo.CreateFileNode(context.Background(), store.FileNode{ServerID: env.os.ID, Name: "external", BaseURL: nodeServer.URL, Secret: secret, Enabled: true})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	if _, err := env.repo.UpdateServer(context.Background(), env.os.ID, nil, nil, nil, nil, nil, nil, nil, &enabled, &node.ID, nil, nil); err != nil {
		t.Fatal(err)
	}
	payloadSize := encryptedAttachmentSize(1, attachmentEncryptionChunkSize)
	initBody := `{"channel_id":"` + env.channel.ID + `","kind":"file","encryption_mode":"e2ee","epoch_id":"` + env.epoch.ID + `","nonce":"AAAAAAAAAAA","plaintext_size_bytes":1,"attachment_format":"` + attachmentEncryptionFormatV1 + `","chunk_size":65536,"original_name":"stale.bin","content_type":"application/octet-stream","size_bytes":` + strconv.FormatInt(payloadSize, 10) + `}`
	initRequest := httptest.NewRequest(http.MethodPost, "/api/v1/attachment-uploads", strings.NewReader(initBody))
	initRequest.Header.Set("Authorization", "Bearer "+env.token)
	initResponse := httptest.NewRecorder()
	env.server.ServeHTTP(initResponse, initRequest)
	if initResponse.Code != http.StatusOK {
		t.Fatalf("init status = %d, body = %s", initResponse.Code, initResponse.Body.String())
	}
	var plan struct {
		CompletionToken string `json:"completion_token"`
	}
	if err := json.Unmarshal(initResponse.Body.Bytes(), &plan); err != nil {
		t.Fatal(err)
	}
	mode := "transport"
	if _, err := env.repo.UpdateServer(context.Background(), env.os.ID, nil, &mode, nil, nil, nil, nil, nil, nil, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	completeBody, _ := json.Marshal(map[string]string{"completion_token": plan.CompletionToken})
	completeRequest := httptest.NewRequest(http.MethodPost, "/api/v1/attachment-uploads/complete", bytes.NewReader(completeBody))
	completeRequest.Header.Set("Authorization", "Bearer "+env.token)
	completeResponse := httptest.NewRecorder()
	env.server.ServeHTTP(completeResponse, completeRequest)
	if completeResponse.Code != http.StatusConflict || !strings.Contains(completeResponse.Body.String(), "encryption_mode_changed") {
		t.Fatalf("mode-changed completion = %d, body = %s", completeResponse.Code, completeResponse.Body.String())
	}
}

func TestStaleE2EEAttachmentIsRemoved(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	if _, err := env.repo.CreateEpoch(context.Background(), env.channel.ID, "changed"); err != nil {
		t.Fatal(err)
	}
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	_ = writer.WriteField("encryption_mode", "e2ee")
	_ = writer.WriteField("epoch_id", env.epoch.ID)
	_ = writer.WriteField("nonce", "AAAAAAAAAAA")
	_ = writer.WriteField("plaintext_size_bytes", "1")
	_ = writer.WriteField("attachment_format", attachmentEncryptionFormatV1)
	_ = writer.WriteField("chunk_size", strconv.FormatInt(attachmentEncryptionChunkSize, 10))
	part, err := writer.CreateFormFile("file", "stale.bin")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = part.Write(bytes.Repeat([]byte{1}, int(encryptedAttachmentSize(1, attachmentEncryptionChunkSize))))
	_ = writer.Close()
	request := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/files", &body)
	request.Header.Set("Authorization", "Bearer "+env.token)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), "epoch_changed") {
		t.Fatalf("stale attachment = %d, body = %s", response.Code, response.Body.String())
	}
	var stored int
	if err := env.db.QueryRow(`SELECT COUNT(*) FROM stored_files`).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored != 0 {
		t.Fatalf("stale attachment records = %d", stored)
	}
	files, err := filepath.Glob(filepath.Join(env.os.FileRoot, env.os.ID, "channel-files", "*", "*", "*", "*"))
	if err != nil || len(files) != 0 {
		t.Fatalf("stale attachment files = %v, err = %v", files, err)
	}
}

func TestChannelMessageRejectsStaleEncryptionMode(t *testing.T) {
	env := newChannelTestEnv(t, "transport")
	payload := `{"kind":"text","encryption_mode":"e2ee","epoch_id":"` + env.epoch.ID + `","nonce":"client-nonce","body":"hello"}`
	req := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/messages", strings.NewReader(payload))
	req.Header.Set("Authorization", "Bearer "+env.token)
	req.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, req)
	if response.Code != http.StatusConflict {
		t.Fatalf("stale encryption mode status = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestStoreChannelMessageAtomicallyRejectsEncryptionModeChange(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	mode := "transport"
	if _, err := env.repo.UpdateServer(context.Background(), env.os.ID, nil, &mode, nil, nil, nil, nil, nil, nil, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	_, err := env.repo.StoreChannelMessage(context.Background(), store.ChannelMessage{
		ChannelID: env.channel.ID, SenderUserID: env.user.ID, Kind: "text",
		EncryptionMode: "e2ee", EpochID: &env.epoch.ID, Body: "ciphertext", Nonce: "nonce",
	})
	if !errors.Is(err, store.ErrEncryptionMode) {
		t.Fatalf("store error = %v", err)
	}
}

func TestChannelE2EEEnvelopeBatchAndEpochAuthorization(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	ctx := context.Background()
	key := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	ownerDevice, err := env.repo.RegisterDevice(ctx, store.Device{
		ID: "dev_owner_0123456789abcdef", UserID: env.user.ID, Label: "owner",
		IdentityPublicKey: key, EnvelopePublicKey: key,
	})
	if err != nil {
		t.Fatal(err)
	}
	member, err := env.repo.CreateUser(ctx, "Member")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(ctx, env.os.ID, member.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	if err := env.repo.AddChannelMember(ctx, env.channel.ID, member.ID, "member"); err != nil {
		t.Fatal(err)
	}
	memberDevice, err := env.repo.RegisterDevice(ctx, store.Device{
		ID: "dev_member_0123456789abcdef", UserID: member.ID, Label: "member",
		IdentityPublicKey: key, EnvelopePublicKey: key,
	})
	if err != nil {
		t.Fatal(err)
	}
	memberToken, _, err := auth.CreateToken(env.server.cfg.JWTSecret, auth.Claims{Subject: member.ID}, env.server.cfg.JWTTTL)
	if err != nil {
		t.Fatal(err)
	}
	restrictedAdmin, err := env.repo.CreateUser(ctx, "Restricted admin")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(ctx, env.os.ID, restrictedAdmin.ID, store.RoleAdmin, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.RegisterDevice(ctx, store.Device{
		ID: "dev_restricted_0123456789", UserID: restrictedAdmin.ID, Label: "restricted",
		IdentityPublicKey: key, EnvelopePublicKey: key,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerRolePermissions(
		ctx,
		env.os.ID,
		[]string{},
		store.UserPermissions(),
		env.user.ID,
	); err != nil {
		t.Fatal(err)
	}

	stateRequest := httptest.NewRequest(http.MethodGet, "/api/v1/channels/"+env.channel.ID+"/e2ee", nil)
	stateRequest.Header.Set("Authorization", "Bearer "+env.token)
	stateResponse := httptest.NewRecorder()
	env.server.ServeHTTP(stateResponse, stateRequest)
	if stateResponse.Code != http.StatusOK {
		t.Fatalf("E2EE state = %d, body = %s", stateResponse.Code, stateResponse.Body.String())
	}
	var state struct {
		Epoch   store.ChannelEpoch    `json:"epoch"`
		Devices []store.ChannelDevice `json:"devices"`
	}
	if err := json.Unmarshal(stateResponse.Body.Bytes(), &state); err != nil {
		t.Fatal(err)
	}
	if state.Epoch.ID != env.epoch.ID || len(state.Devices) != 2 {
		t.Fatalf("E2EE state = %#v", state)
	}

	postBatch := func(token, senderDeviceID string, recipients []map[string]string) *httptest.ResponseRecorder {
		body, err := json.Marshal(map[string]any{
			"channel_id": env.channel.ID, "epoch_id": env.epoch.ID,
			"sender_device_id": senderDeviceID, "envelopes": recipients,
		})
		if err != nil {
			t.Fatal(err)
		}
		request := httptest.NewRequest(http.MethodPost, "/api/v1/e2ee/envelopes", bytes.NewReader(body))
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, request)
		return response
	}
	recipient := func(userID, deviceID string) map[string]string {
		return map[string]string{
			"recipient_user_id": userID, "recipient_device_id": deviceID,
			"algorithm": "openspeak-envelope-v1", "ciphertext": "signed-ciphertext",
		}
	}
	partial := postBatch(env.token, ownerDevice.ID, []map[string]string{recipient(env.user.ID, ownerDevice.ID)})
	if partial.Code != http.StatusConflict {
		t.Fatalf("partial initial batch = %d, body = %s", partial.Code, partial.Body.String())
	}
	complete := postBatch(env.token, ownerDevice.ID, []map[string]string{
		recipient(env.user.ID, ownerDevice.ID), recipient(member.ID, memberDevice.ID),
	})
	if complete.Code != http.StatusOK {
		t.Fatalf("complete batch = %d, body = %s", complete.Code, complete.Body.String())
	}
	var stored []store.KeyEnvelope
	if err := json.Unmarshal(complete.Body.Bytes(), &stored); err != nil {
		t.Fatal(err)
	}
	if len(stored) != 2 || stored[0].SenderIdentityPublicKey != key {
		t.Fatalf("stored envelopes = %#v", stored)
	}

	newDevice, err := env.repo.RegisterDevice(ctx, store.Device{
		ID: "dev_new_0123456789abcdef", UserID: member.ID, Label: "new",
		IdentityPublicKey: key, EnvelopePublicKey: key,
	})
	if err != nil {
		t.Fatal(err)
	}
	keyRequestBody, _ := json.Marshal(map[string]string{
		"channel_id": env.channel.ID, "epoch_id": env.epoch.ID, "recipient_device_id": newDevice.ID,
	})
	keyRequest := httptest.NewRequest(http.MethodPost, "/api/v1/e2ee/key-requests", bytes.NewReader(keyRequestBody))
	keyRequest.Header.Set("Authorization", "Bearer "+memberToken)
	keyRequestResponse := httptest.NewRecorder()
	env.server.ServeHTTP(keyRequestResponse, keyRequest)
	if keyRequestResponse.Code != http.StatusOK {
		t.Fatalf("key request = %d, body = %s", keyRequestResponse.Code, keyRequestResponse.Body.String())
	}
	unauthorized := postBatch(memberToken, newDevice.ID, []map[string]string{recipient(member.ID, newDevice.ID)})
	if unauthorized.Code != http.StatusForbidden {
		t.Fatalf("unkeyed sender = %d, body = %s", unauthorized.Code, unauthorized.Body.String())
	}
	fill := postBatch(memberToken, memberDevice.ID, []map[string]string{recipient(member.ID, newDevice.ID)})
	if fill.Code != http.StatusOK {
		t.Fatalf("missing-device fill = %d, body = %s", fill.Code, fill.Body.String())
	}

	readOther := httptest.NewRequest(http.MethodGet, "/api/v1/e2ee/envelopes?channel_id="+env.channel.ID+"&recipient_device_id="+ownerDevice.ID, nil)
	readOther.Header.Set("Authorization", "Bearer "+memberToken)
	readOtherResponse := httptest.NewRecorder()
	env.server.ServeHTTP(readOtherResponse, readOther)
	if readOtherResponse.Code != http.StatusForbidden {
		t.Fatalf("read another device = %d, body = %s", readOtherResponse.Code, readOtherResponse.Body.String())
	}
	if _, err := env.db.ExecContext(ctx, `
		INSERT INTO server_bans (id, server_id, user_id, installation_hash, created_by_user_id)
		VALUES ('ban_e2ee', ?, ?, 'installation', ?)
	`, env.os.ID, member.ID, env.user.ID); err != nil {
		t.Fatal(err)
	}
	rotated, err := env.repo.RotateServerChannelEpochs(ctx, env.os.ID, "member_banned")
	if err != nil {
		t.Fatal(err)
	}
	if len(rotated) != 1 || rotated[0].EpochNumber != env.epoch.EpochNumber+1 {
		t.Fatalf("rotated epochs = %#v", rotated)
	}
	stateResponse = httptest.NewRecorder()
	env.server.ServeHTTP(stateResponse, stateRequest.Clone(ctx))
	if stateResponse.Code != http.StatusOK {
		t.Fatalf("state after ban = %d, body = %s", stateResponse.Code, stateResponse.Body.String())
	}
	if err := json.Unmarshal(stateResponse.Body.Bytes(), &state); err != nil {
		t.Fatal(err)
	}
	if state.Epoch.ID != rotated[0].ID || len(state.Devices) != 1 || state.Devices[0].ID != ownerDevice.ID {
		t.Fatalf("state after ban = %#v", state)
	}
}

func TestOwnerWithoutOnlineKeyHolderStartsNewChannelEpoch(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	ctx := context.Background()
	key := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	oldDevice, err := env.repo.RegisterDevice(ctx, store.Device{
		ID: "dev_old_owner_0123456789abcdef", UserID: env.user.ID, Label: "old owner",
		IdentityPublicKey: key, EnvelopePublicKey: key,
	})
	if err != nil {
		t.Fatal(err)
	}
	envelope := store.KeyEnvelope{
		RecipientUserID: env.user.ID, RecipientDeviceID: oldDevice.ID,
		Algorithm: "openspeak-envelope-v1", Ciphertext: "old-owner-key",
	}
	if _, err := env.repo.StoreEnvelopeBatch(ctx, env.channel.ID, env.epoch.ID, oldDevice.ID, env.user.ID, []store.KeyEnvelope{envelope}, false); err != nil {
		t.Fatal(err)
	}
	recoveredDevice, err := env.repo.RegisterDevice(ctx, store.Device{
		ID: "dev_recovered_0123456789abcdef", UserID: env.user.ID, Label: "recovered owner",
		IdentityPublicKey: key, EnvelopePublicKey: key,
	})
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]string{
		"channel_id": env.channel.ID, "epoch_id": env.epoch.ID, "recipient_device_id": recoveredDevice.ID,
	})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/e2ee/key-requests", bytes.NewReader(body))
	response := httptest.NewRecorder()
	env.server.handleE2EEKeyRequest(response, request, authContext{
		User:   env.user,
		Claims: auth.Claims{OwnerServerID: env.os.ID, OwnerDeviceID: "odev_recovered"},
	}, false)
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), "key_not_required") {
		t.Fatalf("owner key recovery = %d, body = %s", response.Code, response.Body.String())
	}
	latest, err := env.repo.GetLatestEpoch(ctx, env.channel.ID)
	if err != nil || latest.EpochNumber != env.epoch.EpochNumber+1 || latest.Reason != "owner_key_recovery" {
		t.Fatalf("recovered epoch = %#v, err = %v", latest, err)
	}
}

func TestChannelMessageRejectsStaleEpoch(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	if _, err := env.repo.CreateEpoch(context.Background(), env.channel.ID, "member_changed"); err != nil {
		t.Fatal(err)
	}
	payload := `{"kind":"text","encryption_mode":"e2ee","epoch_id":"` + env.epoch.ID + `","nonce":"AAAAAAAAAAAAAAAA","body":"AAAAAAAAAAAAAAAAAAAAAA"}`
	request := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/messages", strings.NewReader(payload))
	request.Header.Set("Authorization", "Bearer "+env.token)
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), "epoch_changed") {
		t.Fatalf("stale epoch = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestChannelMessageRejectsInvalidE2EETextPayload(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	payload := `{"kind":"text","encryption_mode":"e2ee","epoch_id":"` + env.epoch.ID + `","nonce":"short","body":"not-ciphertext"}`
	request := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/messages", strings.NewReader(payload))
	request.Header.Set("Authorization", "Bearer "+env.token)
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "invalid_e2ee_payload") {
		t.Fatalf("invalid payload = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestChannelMessageRequiresEncryptionMode(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	req := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/messages", strings.NewReader(`{"kind":"text","body":"hello"}`))
	req.Header.Set("Authorization", "Bearer "+env.token)
	req.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, req)
	if response.Code != http.StatusConflict {
		t.Fatalf("missing encryption mode status = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestListChannelMessagesAcceptsLimitQuery(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	updatedUser, err := env.repo.IncrementUserAvatarVersion(context.Background(), env.user.ID, "avatar-hash")
	if err != nil {
		t.Fatal(err)
	}
	postJSON(t, env.server, env.token, "/api/v1/channels/"+env.channel.ID+"/messages", `{"kind":"text","encryption_mode":"none","body":"hello"}`)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/channels/"+env.channel.ID+"/messages?limit=50", nil)
	req.Header.Set("Authorization", "Bearer "+env.token)
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, req)
	if response.Code != http.StatusOK {
		t.Fatalf("list messages status = %d, body = %s", response.Code, response.Body.String())
	}
	var messages []store.ChannelMessage
	if err := json.Unmarshal(response.Body.Bytes(), &messages); err != nil {
		t.Fatal(err)
	}
	if len(messages) != 1 || messages[0].Body != "hello" || messages[0].SenderDisplayName != env.user.DisplayName || messages[0].SenderAvatarVersion != updatedUser.AvatarVersion {
		t.Fatalf("messages = %#v", messages)
	}
}

func TestChannelE2EEUploadRequiresMetadata(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	_ = writer.WriteField("encryption_mode", "e2ee")
	part, err := writer.CreateFormFile("file", "secret.bin")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = part.Write([]byte("ciphertext"))
	_ = writer.Close()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/channels/"+env.channel.ID+"/files", &body)
	req.Header.Set("Authorization", "Bearer "+env.token)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, req)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "missing_e2ee_metadata") {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestServerPublicFileAreaIsDisabled(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", "public.txt")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = part.Write([]byte("public payload"))
	_ = writer.Close()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/servers/"+env.os.ID+"/files", &body)
	req.Header.Set("Authorization", "Bearer "+env.token)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, req)
	if response.Code != http.StatusNotFound {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestLegacyPublicFileCannotBeDownloaded(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	legacy, err := env.repo.StoreFile(context.Background(), store.StoredFile{
		ServerID:       env.os.ID,
		UploaderUserID: env.user.ID,
		Kind:           "public",
		OriginalName:   "legacy.txt",
		ContentType:    "text/plain",
		SizeBytes:      6,
		SHA256Hex:      "unused",
		RelativePath:   "legacy.txt",
		EncryptionMode: "none",
	})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/api/v1/files/"+legacy.ID+"/download", nil)
	req.Header.Set("Authorization", "Bearer "+env.token)
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, req)
	if response.Code != http.StatusNotFound {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestDirectWebSocketMessageIsTemporaryAndTargeted(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	ctx := context.Background()
	secondUser, err := env.repo.CreateUser(ctx, "Second")
	if err != nil {
		t.Fatal(err)
	}
	thirdUser, err := env.repo.CreateUser(ctx, "Third")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(ctx, env.os.ID, secondUser.ID, store.RoleAdmin, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(ctx, env.os.ID, thirdUser.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	adminDevice, err := env.repo.RegisterDevice(ctx, store.Device{UserID: env.user.ID, Label: "admin"})
	if err != nil {
		t.Fatal(err)
	}
	secondDevice, err := env.repo.RegisterDevice(ctx, store.Device{UserID: secondUser.ID, Label: "second"})
	if err != nil {
		t.Fatal(err)
	}
	thirdDevice, err := env.repo.RegisterDevice(ctx, store.Device{UserID: thirdUser.ID, Label: "third"})
	if err != nil {
		t.Fatal(err)
	}
	secondToken, _, err := auth.CreateToken(env.server.cfg.JWTSecret, auth.Claims{Subject: secondUser.ID}, env.server.cfg.JWTTTL)
	if err != nil {
		t.Fatal(err)
	}
	thirdToken, _, err := auth.CreateToken(env.server.cfg.JWTSecret, auth.Claims{Subject: thirdUser.ID}, env.server.cfg.JWTTTL)
	if err != nil {
		t.Fatal(err)
	}

	httpServer := httptest.NewServer(env.server)
	defer httpServer.Close()
	adminWS := dialTestWebSocket(t, httpServer.URL, env.token, adminDevice.ID, env.os.ID)
	defer adminWS.Close()
	secondWS := dialTestWebSocket(t, httpServer.URL, secondToken, secondDevice.ID, env.os.ID)
	defer secondWS.Close()
	thirdWS := dialTestWebSocket(t, httpServer.URL, thirdToken, thirdDevice.ID, env.os.ID)
	defer thirdWS.Close()

	state := waitForState(t, env.server, env.token, env.os.ID, func(state ServerState) bool {
		return len(state.OnlineUsers) == 3
	})
	roles := make(map[string]string, len(state.OnlineUsers))
	for _, user := range state.OnlineUsers {
		roles[user.UserID] = user.Role
	}
	if roles[env.user.ID] != store.RoleOwner || roles[secondUser.ID] != store.RoleAdmin || roles[thirdUser.ID] != store.RoleUser {
		t.Fatalf("online user roles = %#v", roles)
	}
	if err := adminWS.WriteJSON(realtime.Event{
		Type:   "direct.message_send",
		ToUser: secondUser.ID,
		Payload: map[string]any{
			"kind": "text",
			"body": "hello second",
		},
	}); err != nil {
		t.Fatal(err)
	}

	adminEvent := readEventType(t, adminWS, "direct.message_created")
	secondEvent := readEventType(t, secondWS, "direct.message_created")
	for _, event := range []realtime.Event{adminEvent, secondEvent} {
		if event.FromUser != env.user.ID || event.ToUser != secondUser.ID || event.ServerID != env.os.ID {
			t.Fatalf("unexpected direct event routing: %#v", event)
		}
		if event.Payload["body"] != "hello second" || event.Payload["kind"] != "text" {
			t.Fatalf("unexpected direct event payload: %#v", event.Payload)
		}
	}
	messageID, _ := adminEvent.Payload["id"].(string)
	if messageID == "" {
		t.Fatalf("direct message id = %#v", adminEvent.Payload)
	}
	if err := secondWS.WriteJSON(realtime.Event{
		Type: "direct.message_delete", Payload: map[string]any{"message_id": messageID},
	}); err != nil {
		t.Fatal(err)
	}
	if err := adminWS.WriteJSON(realtime.Event{
		Type: "direct.message_delete", Payload: map[string]any{"message_id": messageID},
	}); err != nil {
		t.Fatal(err)
	}
	for _, event := range []realtime.Event{
		readEventType(t, adminWS, "direct.message_deleted"),
		readEventType(t, secondWS, "direct.message_deleted"),
	} {
		if event.Payload["message_id"] != messageID || event.Payload["deleted_by_user_id"] != env.user.ID ||
			event.FromUser != env.user.ID || event.ToUser != secondUser.ID {
			t.Fatalf("unexpected direct deletion event: %#v", event)
		}
	}

	_ = thirdWS.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
	var thirdEvent realtime.Event
	if err := thirdWS.ReadJSON(&thirdEvent); err == nil && thirdEvent.Type == "direct.message_created" {
		t.Fatalf("third user received private event: %#v", thirdEvent)
	}

	messages, err := env.repo.ListChannelMessages(ctx, env.channel.ID, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 0 {
		t.Fatalf("direct messages should not be persisted as channel messages: %d", len(messages))
	}
}

func TestDirectE2EETextAndAttachmentUseOnlineDeviceEnvelopes(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	ctx := context.Background()
	recipient, err := env.repo.CreateUser(ctx, "Recipient")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(ctx, env.os.ID, recipient.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	senderIdentity := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	senderEnvelope := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{8}, 32))
	recipientIdentity := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32))
	recipientEnvelope := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{10}, 32))
	senderDevice, err := env.repo.RegisterDevice(ctx, store.Device{
		ID: "dev_sender_0123456789abcdef", UserID: env.user.ID, Label: "sender",
		IdentityPublicKey: senderIdentity, EnvelopePublicKey: senderEnvelope,
	})
	if err != nil {
		t.Fatal(err)
	}
	recipientDevice, err := env.repo.RegisterDevice(ctx, store.Device{
		ID: "dev_recipient_0123456789ab", UserID: recipient.ID, Label: "recipient",
		IdentityPublicKey: recipientIdentity, EnvelopePublicKey: recipientEnvelope,
	})
	if err != nil {
		t.Fatal(err)
	}
	recipientToken := testUserToken(t, env.server.cfg, recipient.ID)
	httpServer := httptest.NewServer(env.server)
	defer httpServer.Close()
	senderWS := dialTestWebSocket(t, httpServer.URL, env.token, senderDevice.ID, env.os.ID)
	defer senderWS.Close()
	recipientWS := dialTestWebSocket(t, httpServer.URL, recipientToken, recipientDevice.ID, env.os.ID)
	defer recipientWS.Close()
	waitForState(t, env.server, env.token, env.os.ID, func(state ServerState) bool {
		return len(state.OnlineUsers) == 2
	})

	deviceRequest := httptest.NewRequest(http.MethodGet, "/api/v1/e2ee/direct-devices?server_id="+env.os.ID+"&to_user_id="+recipient.ID, nil)
	deviceRequest.Header.Set("Authorization", "Bearer "+env.token)
	deviceResponse := httptest.NewRecorder()
	env.server.ServeHTTP(deviceResponse, deviceRequest)
	if deviceResponse.Code != http.StatusOK {
		t.Fatalf("device state = %d, body = %s", deviceResponse.Code, deviceResponse.Body.String())
	}
	var devices []realtime.DirectDevice
	if err := json.Unmarshal(deviceResponse.Body.Bytes(), &devices); err != nil || len(devices) != 2 {
		t.Fatalf("direct devices = %#v, err = %v", devices, err)
	}
	envelopes := []realtime.DirectKeyEnvelope{
		{Algorithm: "openspeak-envelope-v1", RecipientUserID: env.user.ID, RecipientDeviceID: senderDevice.ID, Ciphertext: "sender-wrapped-key"},
		{Algorithm: "openspeak-envelope-v1", RecipientUserID: recipient.ID, RecipientDeviceID: recipientDevice.ID, Ciphertext: "recipient-wrapped-key"},
	}
	messageID := "dm_0123456789abcdef01234567"
	ciphertext := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{11}, 32))
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{12}, 12))
	if err := senderWS.WriteJSON(realtime.Event{
		Type: "direct.message_send", ToUser: recipient.ID,
		Payload: map[string]any{
			"kind": "text", "encryption_mode": "e2ee", "message_id": messageID,
			"body": ciphertext, "nonce": nonce, "sender_device_id": senderDevice.ID,
			"envelopes": envelopes,
		},
	}); err != nil {
		t.Fatal(err)
	}
	for _, event := range []realtime.Event{
		readEventType(t, senderWS, "direct.message_created"),
		readEventType(t, recipientWS, "direct.message_created"),
	} {
		if event.Payload["id"] != messageID || event.Payload["body"] != ciphertext || event.Payload["encryption_mode"] != "e2ee" || event.Payload["sender_identity_public_key"] != senderIdentity {
			t.Fatalf("encrypted text event = %#v", event.Payload)
		}
	}

	const plaintextSize = int64(23)
	fileCiphertext := bytes.Repeat([]byte{13}, int(encryptedAttachmentSize(plaintextSize, attachmentEncryptionChunkSize)))
	fileMessageID := "dm_89abcdef0123456701234567"
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	fields := map[string]string{
		"to_user_id": recipient.ID, "original_name": "private.png", "encryption_mode": "e2ee",
		"message_id": fileMessageID, "sender_device_id": senderDevice.ID,
		"nonce":                base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{14}, 8)),
		"plaintext_size_bytes": strconv.FormatInt(plaintextSize, 10),
		"attachment_format":    attachmentEncryptionFormatV1,
		"chunk_size":           strconv.FormatInt(attachmentEncryptionChunkSize, 10),
	}
	envelopeJSON, _ := json.Marshal(envelopes)
	fields["envelopes"] = string(envelopeJSON)
	for name, value := range fields {
		_ = writer.WriteField(name, value)
	}
	header := make(textproto.MIMEHeader)
	header.Set("Content-Disposition", `form-data; name="file"; filename="payload"`)
	header.Set("Content-Type", "image/png")
	part, err := writer.CreatePart(header)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = part.Write(fileCiphertext)
	_ = writer.Close()
	uploadRequest := httptest.NewRequest(http.MethodPost, "/api/v1/direct-files", &body)
	uploadRequest.Header.Set("Authorization", "Bearer "+env.token)
	uploadRequest.Header.Set("Content-Type", writer.FormDataContentType())
	uploadResponse := httptest.NewRecorder()
	env.server.ServeHTTP(uploadResponse, uploadRequest)
	if uploadResponse.Code != http.StatusOK {
		t.Fatalf("encrypted upload = %d, body = %s", uploadResponse.Code, uploadResponse.Body.String())
	}
	var uploaded directFile
	if err := json.Unmarshal(uploadResponse.Body.Bytes(), &uploaded); err != nil {
		t.Fatal(err)
	}
	if uploaded.EncryptionMode != "e2ee" || uploaded.SizeBytes != int64(len(fileCiphertext)) || uploaded.PlaintextSizeBytes != plaintextSize {
		t.Fatalf("encrypted direct file = %#v", uploaded)
	}
	for _, event := range []realtime.Event{
		readEventType(t, senderWS, "direct.message_created"),
		readEventType(t, recipientWS, "direct.message_created"),
	} {
		if event.Payload["id"] != fileMessageID || event.Payload["size_bytes"] != float64(plaintextSize) || event.Payload["ciphertext_size_bytes"] != float64(len(fileCiphertext)) || event.Payload["attachment_format"] != attachmentEncryptionFormatV1 {
			t.Fatalf("encrypted file event = %#v", event.Payload)
		}
	}
	download := downloadDirectFile(env.server, recipientToken, uploaded.ID)
	if download.Code != http.StatusOK || !bytes.Equal(download.Body.Bytes(), fileCiphertext) {
		t.Fatalf("encrypted download = %d, body length = %d", download.Code, download.Body.Len())
	}

	nodeSecret := "direct-e2ee-node-secret"
	nodeRoot := t.TempDir()
	fileNode := &filenode.Server{Root: nodeRoot, Secret: nodeSecret}
	nodeServer := httptest.NewTLSServer(fileNode)
	defer nodeServer.Close()
	defaultTransport := http.DefaultTransport
	http.DefaultTransport = nodeServer.Client().Transport
	t.Cleanup(func() { http.DefaultTransport = defaultTransport })
	node, err := env.repo.CreateFileNode(ctx, store.FileNode{
		ServerID: env.os.ID, Name: "external", BaseURL: nodeServer.URL,
		Secret: nodeSecret, Enabled: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	if _, err := env.repo.UpdateServer(ctx, env.os.ID, nil, nil, nil, nil, nil, nil, nil, &enabled, &node.ID, nil, nil); err != nil {
		t.Fatal(err)
	}
	const externalPlaintextSize = int64(31)
	externalCiphertext := bytes.Repeat([]byte{15}, int(encryptedAttachmentSize(externalPlaintextSize, attachmentEncryptionChunkSize)))
	externalMessageID := "dm_fedcba987654321001234567"
	initPayload, _ := json.Marshal(map[string]any{
		"to_user_id": recipient.ID, "kind": "file", "original_name": "private.bin",
		"content_type": "application/octet-stream", "size_bytes": len(externalCiphertext),
		"encryption_mode": "e2ee", "message_id": externalMessageID,
		"sender_device_id": senderDevice.ID, "nonce": base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{16}, 8)),
		"plaintext_size_bytes": externalPlaintextSize, "attachment_format": attachmentEncryptionFormatV1,
		"chunk_size": attachmentEncryptionChunkSize, "direct_envelopes": envelopes,
	})
	initRequest := httptest.NewRequest(http.MethodPost, "/api/v1/attachment-uploads", bytes.NewReader(initPayload))
	initRequest.Header.Set("Authorization", "Bearer "+env.token)
	initResponse := httptest.NewRecorder()
	env.server.ServeHTTP(initResponse, initRequest)
	if initResponse.Code != http.StatusOK {
		t.Fatalf("external init = %d, body = %s", initResponse.Code, initResponse.Body.String())
	}
	var plan struct {
		UploadURL       string `json:"upload_url"`
		CompletionToken string `json:"completion_token"`
	}
	if err := json.Unmarshal(initResponse.Body.Bytes(), &plan); err != nil {
		t.Fatal(err)
	}
	put, _ := http.NewRequest(http.MethodPut, plan.UploadURL, bytes.NewReader(externalCiphertext))
	put.ContentLength = int64(len(externalCiphertext))
	putResponse, err := http.DefaultClient.Do(put)
	if err != nil {
		t.Fatal(err)
	}
	putResponse.Body.Close()
	if putResponse.StatusCode != http.StatusOK {
		t.Fatalf("external put = %d", putResponse.StatusCode)
	}
	completeBody, _ := json.Marshal(map[string]string{"completion_token": plan.CompletionToken})
	completeRequest := httptest.NewRequest(http.MethodPost, "/api/v1/attachment-uploads/complete", bytes.NewReader(completeBody))
	completeRequest.Header.Set("Authorization", "Bearer "+env.token)
	completeResponse := httptest.NewRecorder()
	env.server.ServeHTTP(completeResponse, completeRequest)
	if completeResponse.Code != http.StatusOK {
		t.Fatalf("external complete = %d, body = %s", completeResponse.Code, completeResponse.Body.String())
	}
	var externalFile directFile
	if err := json.Unmarshal(completeResponse.Body.Bytes(), &externalFile); err != nil {
		t.Fatal(err)
	}
	if externalFile.FileNodeID != node.ID || externalFile.EncryptionMode != "e2ee" {
		t.Fatalf("external direct file = %#v", externalFile)
	}
	for _, event := range []realtime.Event{
		readEventType(t, senderWS, "direct.message_created"),
		readEventType(t, recipientWS, "direct.message_created"),
	} {
		if event.Payload["id"] != externalMessageID || event.Payload["size_bytes"] != float64(externalPlaintextSize) {
			t.Fatalf("external encrypted event = %#v", event.Payload)
		}
	}
	messages, err := env.repo.ListChannelMessages(ctx, env.channel.ID, 10)
	if err != nil || len(messages) != 0 {
		t.Fatalf("direct E2EE persistence = %d messages, err = %v", len(messages), err)
	}
}

func TestE2EEServerRejectsKeylessWebSocketDevice(t *testing.T) {
	env := newChannelTestEnv(t, "e2ee")
	device, err := env.repo.RegisterDevice(context.Background(), store.Device{UserID: env.user.ID, Label: "legacy"})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(env.server)
	defer httpServer.Close()
	u, _ := url.Parse(httpServer.URL)
	u.Scheme = "ws"
	u.Path = "/ws"
	query := u.Query()
	query.Set("token", env.token)
	query.Set("device_id", device.ID)
	query.Set("server_id", env.os.ID)
	u.RawQuery = query.Encode()
	conn, response, err := websocket.DefaultDialer.Dial(u.String(), nil)
	if conn != nil {
		conn.Close()
	}
	if err == nil || response == nil || response.StatusCode != http.StatusConflict {
		t.Fatalf("keyless websocket err=%v response=%v", err, response)
	}
}

func TestDirectFileUploadDownloadTargetingExpiryAndNoPersistence(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	ctx := context.Background()
	secondUser, err := env.repo.CreateUser(ctx, "Second")
	if err != nil {
		t.Fatal(err)
	}
	thirdUser, err := env.repo.CreateUser(ctx, "Third")
	if err != nil {
		t.Fatal(err)
	}
	for _, user := range []store.User{secondUser, thirdUser} {
		if _, err := env.repo.SetServerMember(ctx, env.os.ID, user.ID, store.RoleUser, nil); err != nil {
			t.Fatal(err)
		}
	}
	adminDevice, err := env.repo.RegisterDevice(ctx, store.Device{UserID: env.user.ID, Label: "admin"})
	if err != nil {
		t.Fatal(err)
	}
	secondDevice, err := env.repo.RegisterDevice(ctx, store.Device{UserID: secondUser.ID, Label: "second"})
	if err != nil {
		t.Fatal(err)
	}
	thirdDevice, err := env.repo.RegisterDevice(ctx, store.Device{UserID: thirdUser.ID, Label: "third"})
	if err != nil {
		t.Fatal(err)
	}
	secondToken := testUserToken(t, env.server.cfg, secondUser.ID)
	thirdToken := testUserToken(t, env.server.cfg, thirdUser.ID)

	httpServer := httptest.NewServer(env.server)
	defer httpServer.Close()
	adminWS := dialTestWebSocket(t, httpServer.URL, env.token, adminDevice.ID, env.os.ID)
	defer adminWS.Close()
	secondWS := dialTestWebSocket(t, httpServer.URL, secondToken, secondDevice.ID, env.os.ID)
	defer secondWS.Close()
	thirdWS := dialTestWebSocket(t, httpServer.URL, thirdToken, thirdDevice.ID, env.os.ID)
	defer thirdWS.Close()
	waitForState(t, env.server, env.token, env.os.ID, func(state ServerState) bool {
		return len(state.OnlineUsers) == 3
	})

	payload := []byte("temporary image bytes")
	uploadResponse := uploadDirectFile(t, env.server, env.token, secondUser.ID, "picture.png", "image/png", payload)
	if uploadResponse.Code != http.StatusOK {
		t.Fatalf("upload status = %d, body = %s", uploadResponse.Code, uploadResponse.Body.String())
	}
	var uploaded directFile
	if err := json.Unmarshal(uploadResponse.Body.Bytes(), &uploaded); err != nil {
		t.Fatal(err)
	}
	if uploaded.ServerID != env.os.ID || uploaded.FromUserID != env.user.ID || uploaded.ToUserID != secondUser.ID {
		t.Fatalf("uploaded metadata = %#v", uploaded)
	}
	if uploaded.OriginalName != "picture.png" || uploaded.ContentType != "image/png" || uploaded.SizeBytes != int64(len(payload)) {
		t.Fatalf("uploaded file metadata = %#v", uploaded)
	}

	for _, event := range []realtime.Event{
		readEventType(t, adminWS, "direct.message_created"),
		readEventType(t, secondWS, "direct.message_created"),
	} {
		if event.ServerID != env.os.ID || event.FromUser != env.user.ID || event.ToUser != secondUser.ID {
			t.Fatalf("event routing = %#v", event)
		}
		if event.Payload["kind"] != "image" || event.Payload["file_id"] != uploaded.ID ||
			event.Payload["original_name"] != "picture.png" || event.Payload["content_type"] != "image/png" ||
			event.Payload["size_bytes"] != float64(len(payload)) {
			t.Fatalf("event payload = %#v", event.Payload)
		}
		if event.Payload["id"] == "" || event.Payload["expires_at"] != nil {
			t.Fatalf("event id/expiry payload = %#v", event.Payload)
		}
	}
	_ = thirdWS.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
	var thirdEvent realtime.Event
	if err := thirdWS.ReadJSON(&thirdEvent); err == nil && thirdEvent.Type == "direct.message_created" {
		t.Fatalf("third user received private file event: %#v", thirdEvent)
	}

	for _, access := range []struct {
		name  string
		token string
		want  int
	}{
		{name: "sender", token: env.token, want: http.StatusOK},
		{name: "recipient", token: secondToken, want: http.StatusOK},
		{name: "third party", token: thirdToken, want: http.StatusForbidden},
	} {
		t.Run(access.name, func(t *testing.T) {
			response := downloadDirectFile(env.server, access.token, uploaded.ID)
			if response.Code != access.want {
				t.Fatalf("download status = %d, body = %s", response.Code, response.Body.String())
			}
			if access.want == http.StatusOK {
				if !response.writeTimeoutDisabled() {
					t.Fatalf("download write deadline was not disabled: %#v", response.writeDeadlines)
				}
				if !bytes.Equal(response.Body.Bytes(), payload) {
					t.Fatalf("download body = %q", response.Body.Bytes())
				}
				if response.Header().Get("Content-Type") != "image/png" ||
					response.Header().Get("Content-Length") != strconv.Itoa(len(payload)) ||
					!strings.Contains(response.Header().Get("Content-Disposition"), "picture.png") {
					t.Fatalf("download headers = %#v", response.Header())
				}
			}
		})
	}

	messages, err := env.repo.ListChannelMessages(ctx, env.channel.ID, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 0 {
		t.Fatalf("direct file created %d channel messages", len(messages))
	}
	if _, err := env.repo.GetFile(ctx, uploaded.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("direct file was written to stored_files: %v", err)
	}

	expiredPath := uploaded.Path
	_ = adminWS.Close()
	expiredEvent := readEventType(t, secondWS, "direct.file_expired")
	if expiredEvent.ServerID != env.os.ID || expiredEvent.FromUser != env.user.ID || expiredEvent.ToUser != secondUser.ID ||
		expiredEvent.Payload["file_id"] != uploaded.ID || expiredEvent.Payload["reason"] != "sender_offline" {
		t.Fatalf("expired event = %#v", expiredEvent)
	}
	expiredResponse := downloadDirectFile(env.server, env.token, uploaded.ID)
	if expiredResponse.Code != http.StatusGone {
		t.Fatalf("expired download status = %d, body = %s", expiredResponse.Code, expiredResponse.Body.String())
	}
	if _, ok := env.server.directFiles.get(uploaded.ID); ok {
		t.Fatal("expired file metadata was not removed")
	}
	if _, err := os.Stat(expiredPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expired file still exists: %v", err)
	}
}

func TestDirectFileDownloadDisablesWriteTimeout(t *testing.T) {
	payload := []byte("temporary file payload")
	path := filepath.Join(t.TempDir(), "direct-file")
	if err := os.WriteFile(path, payload, 0o600); err != nil {
		t.Fatal(err)
	}

	server := &Server{directFiles: newDirectFileStore(t.TempDir())}
	file := directFile{
		ID:           "direct-file",
		FromUserID:   "sender",
		ToUserID:     "recipient",
		Path:         path,
		OriginalName: "music.flac",
		ContentType:  "audio/flac",
		SizeBytes:    int64(len(payload)),
	}
	server.directFiles.files[file.ID] = file

	request := httptest.NewRequest(http.MethodGet, "/api/v1/direct-files/"+file.ID+"/download", nil)
	response := newDeadlineResponseRecorder()
	server.handleDirectFileDownload(response, request, authContext{User: store.User{ID: file.FromUserID}}, file.ID)

	if response.Code != http.StatusOK {
		t.Fatalf("download status = %d, body = %s", response.Code, response.Body.String())
	}
	if !bytes.Equal(response.Body.Bytes(), payload) {
		t.Fatalf("download body = %q", response.Body.Bytes())
	}
	if !response.writeTimeoutDisabled() {
		t.Fatalf("download write deadline was not disabled: %#v", response.writeDeadlines)
	}
}

func TestDirectFileUploadRejectsOfflineRecipient(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	ctx := context.Background()
	recipient, err := env.repo.CreateUser(ctx, "Offline")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(ctx, env.os.ID, recipient.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	device, err := env.repo.RegisterDevice(ctx, store.Device{UserID: env.user.ID, Label: "sender"})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(env.server)
	defer httpServer.Close()
	senderWS := dialTestWebSocket(t, httpServer.URL, env.token, device.ID, env.os.ID)
	defer senderWS.Close()
	waitForState(t, env.server, env.token, env.os.ID, func(state ServerState) bool {
		return userOnline(state, env.user.ID)
	})
	response := uploadDirectFile(t, env.server, env.token, recipient.ID, "offline.txt", "text/plain", []byte("no delivery"))
	if response.Code != http.StatusConflict {
		t.Fatalf("upload status = %d, body = %s", response.Code, response.Body.String())
	}
	if len(env.server.directFiles.files) != 0 {
		t.Fatal("offline upload created temporary file metadata")
	}
}

func uploadDirectFile(t *testing.T, server *Server, token, toUserID, name, contentType string, payload []byte) *httptest.ResponseRecorder {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	if err := writer.WriteField("to_user_id", toUserID); err != nil {
		t.Fatal(err)
	}
	if err := writer.WriteField("original_name", name); err != nil {
		t.Fatal(err)
	}
	header := make(textproto.MIMEHeader)
	header.Set("Content-Disposition", `form-data; name="file"; filename="upload"`)
	header.Set("Content-Type", contentType)
	part, err := writer.CreatePart(header)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/v1/direct-files", &body)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	response := httptest.NewRecorder()
	server.ServeHTTP(response, req)
	return response
}

func downloadDirectFile(server *Server, token, fileID string) *deadlineResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "/api/v1/direct-files/"+fileID+"/download", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	response := newDeadlineResponseRecorder()
	server.ServeHTTP(response, req)
	return response
}

func testUserToken(t *testing.T, cfg config.Config, userID string) string {
	t.Helper()
	token, _, err := auth.CreateToken(cfg.JWTSecret, auth.Claims{Subject: userID}, cfg.JWTTTL)
	if err != nil {
		t.Fatal(err)
	}
	return token
}

func readEventType(t *testing.T, conn *websocket.Conn, eventType string) realtime.Event {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		_ = conn.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		var event realtime.Event
		if err := conn.ReadJSON(&event); err != nil {
			continue
		}
		if event.Type == eventType {
			return event
		}
	}
	t.Fatalf("timed out waiting for event %q", eventType)
	return realtime.Event{}
}

func TestTwoWebSocketClientsStateAndDisconnectCleanup(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	ctx := context.Background()
	secondUser, err := env.repo.CreateUser(ctx, "Second")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerMember(ctx, env.os.ID, secondUser.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	if err := env.repo.AddChannelMember(ctx, env.channel.ID, secondUser.ID, "member"); err != nil {
		t.Fatal(err)
	}
	secondChannel, err := env.repo.CreateChannel(ctx, store.Channel{ServerID: env.os.ID, Name: "Side"})
	if err != nil {
		t.Fatal(err)
	}
	if err := env.repo.AddChannelMember(ctx, secondChannel.ID, env.user.ID, "member"); err != nil {
		t.Fatal(err)
	}

	adminDevice, err := env.repo.RegisterDevice(ctx, store.Device{UserID: env.user.ID, Label: "admin"})
	if err != nil {
		t.Fatal(err)
	}
	secondDevice, err := env.repo.RegisterDevice(ctx, store.Device{UserID: secondUser.ID, Label: "second"})
	if err != nil {
		t.Fatal(err)
	}
	secondToken, _, err := auth.CreateToken(env.server.cfg.JWTSecret, auth.Claims{Subject: secondUser.ID}, env.server.cfg.JWTTTL)
	if err != nil {
		t.Fatal(err)
	}

	httpServer := httptest.NewServer(env.server)
	defer httpServer.Close()
	adminWS := dialTestWebSocket(t, httpServer.URL, env.token, adminDevice.ID, env.os.ID)
	defer adminWS.Close()
	secondWS := dialTestWebSocket(t, httpServer.URL, secondToken, secondDevice.ID, env.os.ID)

	waitForState(t, env.server, env.token, env.os.ID, func(state ServerState) bool {
		return len(state.OnlineUsers) == 2
	})

	postJSON(t, env.server, env.token, "/api/v1/channels/"+env.channel.ID+"/join", `{"user_id":"`+env.user.ID+`"}`)
	postJSON(t, env.server, secondToken, "/api/v1/channels/"+env.channel.ID+"/join", `{"user_id":"`+secondUser.ID+`"}`)
	state := waitForState(t, env.server, env.token, env.os.ID, func(state ServerState) bool {
		return userInChannel(state, env.user.ID, env.channel.ID) && userInChannel(state, secondUser.ID, env.channel.ID)
	})
	if state.CurrentUser.CurrentChannelID == nil || *state.CurrentUser.CurrentChannelID != env.channel.ID {
		t.Fatalf("current user channel = %#v", state.CurrentUser.CurrentChannelID)
	}

	putJSON(t, env.server, env.token, "/api/v1/servers/"+env.os.ID+"/voice-state", `{"channel_id":"`+env.channel.ID+`","muted":true,"deafened":false,"speaking":true,"screen_sharing":true,"screen_share_resolution":"1080p","screen_share_fps":30}`)
	state = waitForState(t, env.server, env.token, env.os.ID, func(state ServerState) bool {
		for _, voice := range state.VoiceStates {
			if voice.UserID == env.user.ID && voice.ChannelID == env.channel.ID && voice.Muted && voice.Speaking && voice.ScreenSharing && voice.ScreenShareResolution == "1080p" && voice.ScreenShareFPS == 30 {
				return true
			}
		}
		return false
	})
	if len(state.VoiceStates) != 1 {
		t.Fatalf("voice states = %d, want 1", len(state.VoiceStates))
	}
	request := httptest.NewRequest(http.MethodPut, "/api/v1/servers/"+env.os.ID+"/voice-state", strings.NewReader(`{"channel_id":"`+env.channel.ID+`","muted":true,"deafened":false,"speaking":false,"screen_sharing":true,"screen_share_resolution":"720p","screen_share_fps":15}`))
	request.Header.Set("Authorization", "Bearer "+secondToken)
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), `"screen_share_in_progress"`) {
		t.Fatalf("concurrent screen share = %d, body = %s", response.Code, response.Body.String())
	}

	postJSON(t, env.server, env.token, "/api/v1/channels/"+secondChannel.ID+"/join", `{"user_id":"`+env.user.ID+`"}`)
	state = waitForState(t, env.server, env.token, env.os.ID, func(state ServerState) bool {
		return userInChannel(state, env.user.ID, secondChannel.ID) && len(state.VoiceStates) == 0
	})
	if userInChannel(state, env.user.ID, env.channel.ID) {
		t.Fatal("user remained in old channel after switching channels")
	}
	if _, err := env.repo.SetServerRolePermissions(ctx, env.os.ID, store.AdminPermissions(), []string{
		store.PermissionVoiceJoin,
		store.PermissionVoiceScreenShare,
		store.PermissionVoiceScreenShareResolution720p,
		store.PermissionVoiceScreenShareFPS15,
	}, env.user.ID); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{
		"missing":   `{"channel_id":"` + env.channel.ID + `","muted":true,"deafened":false,"speaking":false,"screen_sharing":true}`,
		"forbidden": `{"channel_id":"` + env.channel.ID + `","muted":true,"deafened":false,"speaking":false,"screen_sharing":true,"screen_share_resolution":"1080p","screen_share_fps":30}`,
	} {
		request := httptest.NewRequest(http.MethodPut, "/api/v1/servers/"+env.os.ID+"/voice-state", strings.NewReader(body))
		request.Header.Set("Authorization", "Bearer "+secondToken)
		response := httptest.NewRecorder()
		env.server.ServeHTTP(response, request)
		want := http.StatusForbidden
		if name == "missing" {
			want = http.StatusBadRequest
		}
		if response.Code != want {
			t.Fatalf("%s quality status = %d, body = %s", name, response.Code, response.Body.String())
		}
	}
	putJSON(t, env.server, secondToken, "/api/v1/servers/"+env.os.ID+"/voice-state", `{"channel_id":"`+env.channel.ID+`","muted":true,"deafened":false,"speaking":false,"screen_sharing":true,"screen_share_resolution":"720p","screen_share_fps":15}`)
	waitForState(t, env.server, env.token, env.os.ID, func(state ServerState) bool {
		for _, voice := range state.VoiceStates {
			if voice.UserID == secondUser.ID {
				return voice.ScreenSharing && voice.ScreenShareResolution == "720p" && voice.ScreenShareFPS == 15
			}
		}
		return false
	})
	relayDisabled := store.DefaultScreenSharePolicy()
	relayDisabled.Relay.Enabled = false
	if _, err := env.repo.UpdateServer(ctx, env.os.ID, nil, nil, nil, nil, nil, &relayDisabled, nil, nil, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	env.server.enforceScreenSharePermissions(ctx, env.os.ID)
	waitForState(t, env.server, env.token, env.os.ID, func(state ServerState) bool {
		for _, voice := range state.VoiceStates {
			if voice.UserID == secondUser.ID {
				return !voice.ScreenSharing
			}
		}
		return false
	})
	request = httptest.NewRequest(http.MethodPut, "/api/v1/servers/"+env.os.ID+"/voice-state", strings.NewReader(`{"channel_id":"`+env.channel.ID+`","muted":true,"deafened":false,"speaking":false,"screen_sharing":true,"screen_share_resolution":"720p","screen_share_fps":15}`))
	request.Header.Set("Authorization", "Bearer "+secondToken)
	response = httptest.NewRecorder()
	env.server.ServeHTTP(response, request)
	if response.Code != http.StatusOK || strings.Contains(response.Body.String(), `"screen_sharing":true`) {
		t.Fatalf("relay-disabled voice state = %d, body = %s", response.Code, response.Body.String())
	}
	relayEnabled := store.DefaultScreenSharePolicy()
	if _, err := env.repo.UpdateServer(ctx, env.os.ID, nil, nil, nil, nil, nil, &relayEnabled, nil, nil, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := env.repo.SetServerRolePermissions(ctx, env.os.ID, store.AdminPermissions(), []string{store.PermissionVoiceJoin}, env.user.ID); err != nil {
		t.Fatal(err)
	}
	putJSON(t, env.server, secondToken, "/api/v1/servers/"+env.os.ID+"/voice-state", `{"channel_id":"`+env.channel.ID+`","muted":true,"deafened":false,"speaking":false,"screen_sharing":true}`)
	waitForState(t, env.server, env.token, env.os.ID, func(state ServerState) bool {
		for _, voice := range state.VoiceStates {
			if voice.UserID == secondUser.ID {
				return !voice.ScreenSharing
			}
		}
		return false
	})

	if err := secondWS.Close(); err != nil {
		t.Fatal(err)
	}
	waitForState(t, env.server, env.token, env.os.ID, func(state ServerState) bool {
		return !userOnline(state, secondUser.ID) && !userInChannel(state, secondUser.ID, env.channel.ID)
	})
}

func dialTestWebSocket(t *testing.T, baseURL, token, deviceID, serverID string) *websocket.Conn {
	t.Helper()
	u, err := url.Parse(baseURL)
	if err != nil {
		t.Fatal(err)
	}
	u.Scheme = "ws"
	u.Path = "/ws"
	query := u.Query()
	query.Set("token", token)
	query.Set("device_id", deviceID)
	query.Set("server_id", serverID)
	u.RawQuery = query.Encode()
	conn, _, err := websocket.DefaultDialer.Dial(u.String(), nil)
	if err != nil {
		t.Fatal(err)
	}
	return conn
}

func postJSON(t *testing.T, server *Server, token, path, body string) {
	t.Helper()
	requestJSON(t, server, http.MethodPost, token, path, body)
}

func putJSON(t *testing.T, server *Server, token, path, body string) {
	t.Helper()
	requestJSON(t, server, http.MethodPut, token, path, body)
}

func requestJSON(t *testing.T, server *Server, method, token, path, body string) {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	server.ServeHTTP(response, req)
	if response.Code != http.StatusOK {
		t.Fatalf("%s %s status = %d, body = %s", method, path, response.Code, response.Body.String())
	}
}

func waitForState(t *testing.T, server *Server, token, serverID string, accept func(ServerState) bool) ServerState {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	var last ServerState
	for time.Now().Before(deadline) {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/servers/"+serverID+"/state", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		server.ServeHTTP(response, req)
		if response.Code != http.StatusOK {
			t.Fatalf("state status = %d, body = %s", response.Code, response.Body.String())
		}
		if err := json.Unmarshal(response.Body.Bytes(), &last); err != nil {
			t.Fatal(err)
		}
		if accept(last) {
			return last
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("state did not match before timeout: %#v", last)
	return last
}

func userOnline(state ServerState, userID string) bool {
	for _, user := range state.OnlineUsers {
		if user.UserID == userID {
			return true
		}
	}
	return false
}

func userInChannel(state ServerState, userID, channelID string) bool {
	for _, user := range state.OnlineUsers {
		if user.UserID == userID && user.CurrentChannelID != nil && *user.CurrentChannelID == channelID {
			return true
		}
	}
	return false
}

func TestCurrentChannelDoesNotChangePersistentAccess(t *testing.T) {
	env := newChannelTestEnv(t, "none")
	env.hub.SetCurrentChannel(env.os.ID, env.user.ID, env.channel.ID)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/servers/"+env.os.ID+"/state", nil)
	req.Header.Set("Authorization", "Bearer "+env.token)
	response := httptest.NewRecorder()
	env.server.ServeHTTP(response, req)
	if response.Code != http.StatusOK {
		t.Fatalf("state status = %d, body = %s", response.Code, response.Body.String())
	}
	var state ServerState
	if err := json.Unmarshal(response.Body.Bytes(), &state); err != nil {
		t.Fatal(err)
	}
	if state.CurrentUser.CurrentChannelID == nil || *state.CurrentUser.CurrentChannelID != env.channel.ID {
		t.Fatalf("current channel = %#v", state.CurrentUser.CurrentChannelID)
	}
	if state.CurrentUser.SelectedChannelID == nil || *state.CurrentUser.SelectedChannelID != env.channel.ID {
		t.Fatalf("selected channel = %#v", state.CurrentUser.SelectedChannelID)
	}

	env.hub.ClearCurrentChannel(env.os.ID, env.user.ID)
	members, err := env.repo.ListChannelMembers(context.Background(), env.channel.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, member := range members {
		if member.UserID == env.user.ID {
			return
		}
	}
	t.Fatal("clearing current channel revoked persistent channel access")
}
