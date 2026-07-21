package httpapi

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"openspeak/internal/auth"
	"openspeak/internal/config"
	"openspeak/internal/database"
	"openspeak/internal/realtime"
	"openspeak/internal/store"
)

func TestOwnerClaimPairKickAndReset(t *testing.T) {
	ctx := context.Background()
	db, err := database.OpenSQLite(ctx, filepath.Join(t.TempDir(), "openspeak.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	repo := store.NewSQLite(db)
	owner, err := repo.CreateUser(ctx, "Owner")
	if err != nil {
		t.Fatal(err)
	}
	serverRecord, err := repo.CreateServer(ctx, store.OSServer{
		Name: "Owner Test", EncryptionMode: "transport",
		FileRoot: t.TempDir(), HistoryRetentionDays: 30,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.SetServerMember(ctx, serverRecord.ID, owner.ID, store.RoleOwner, store.AllPermissions()); err != nil {
		t.Fatal(err)
	}
	claimKey := "test-owner-claim-key"
	if _, err := repo.CreateOwnerSecurity(
		ctx, serverRecord.ID, owner.ID, auth.SecretHash(claimKey),
		time.Now().UTC().Add(time.Hour),
	); err != nil {
		t.Fatal(err)
	}
	guest, err := repo.CreateUser(ctx, "Guest")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.SetServerMember(ctx, serverRecord.ID, guest.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{JWTSecret: "owner-test-secret", JWTTTL: time.Hour}
	guestToken := mustToken(t, cfg, guest.ID)
	hub := realtime.NewHub()
	hubCtx, cancelHub := context.WithCancel(ctx)
	go hub.Run(hubCtx)
	t.Cleanup(cancelHub)
	api := NewServer(cfg, repo, hub)

	deviceAPublic, deviceAPrivate := generateOwnerKey(t)
	ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverRecord.ID+"/owner/claim", guestToken, map[string]any{
			"claim_key":           claimKey,
			"recovery_public_key": "removed",
			"device":              ownerTestDevice("Legacy Device", deviceAPublic),
		}, http.StatusBadRequest)
	claim := ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverRecord.ID+"/owner/claim", guestToken, map[string]any{
			"claim_key": claimKey,
			"device":    ownerTestDevice("Device A", deviceAPublic),
		}, http.StatusOK)
	ownerTokenA := claim["token"].(string)
	deviceA := claim["owner_device"].(map[string]any)["id"].(string)
	if claim["user"].(map[string]any)["display_name"] != "Guest" {
		t.Fatalf("owner session did not preserve local nickname: %#v", claim["user"])
	}

	status := ownerRequest(t, api, http.MethodGet,
		"/api/v1/servers/"+serverRecord.ID+"/owner/status", ownerTokenA, nil, http.StatusOK)
	if status["claimed"] != true || status["is_owner"] != true {
		t.Fatalf("unexpected owner status: %#v", status)
	}
	permissions := ownerRequest(t, api, http.MethodGet,
		"/api/v1/servers/"+serverRecord.ID+"/permissions", ownerTokenA, nil, http.StatusOK)
	if len(permissions["admin"].([]any)) == 0 || len(permissions["user"].([]any)) == 0 {
		t.Fatalf("default role permissions missing: %#v", permissions)
	}
	ownerRequest(t, api, http.MethodPut,
		"/api/v1/servers/"+serverRecord.ID+"/permissions", guestToken,
		map[string]any{"admin": []string{store.PermissionMemberView}, "user": []string{}}, http.StatusForbidden)
	ownerRequest(t, api, http.MethodPut,
		"/api/v1/servers/"+serverRecord.ID+"/permissions", ownerTokenA,
		map[string]any{"admin": []string{store.PermissionVoiceScreenShare}, "user": []string{}}, http.StatusBadRequest)
	updatedPermissions := ownerRequest(t, api, http.MethodPut,
		"/api/v1/servers/"+serverRecord.ID+"/permissions", ownerTokenA,
		map[string]any{
			"admin": []string{store.PermissionMemberView, store.PermissionMemberKick},
			"user":  []string{store.PermissionChannelMessagesView},
		}, http.StatusOK)
	if len(updatedPermissions["admin"].([]any)) != 2+len(store.ScreenShareQualityPermissions()) ||
		len(updatedPermissions["user"].([]any)) != 1+len(store.ScreenShareQualityPermissions()) {
		t.Fatalf("unexpected updated role permissions: %#v", updatedPermissions)
	}
	ownerRequest(t, api, http.MethodPut,
		"/api/v1/servers/"+serverRecord.ID+"/members/"+guest.ID,
		ownerTokenA, map[string]any{"role": store.RoleAdmin, "permissions": []string{}}, http.StatusOK)
	ownerRequest(t, api, http.MethodPut,
		"/api/v1/servers/"+serverRecord.ID+"/members/"+guest.ID,
		guestToken, map[string]any{"role": store.RoleUser, "permissions": []string{}}, http.StatusForbidden)
	ownerRequest(t, api, http.MethodPut,
		"/api/v1/servers/"+serverRecord.ID+"/members/"+guest.ID,
		ownerTokenA, map[string]any{"role": store.RoleUser, "permissions": []string{}}, http.StatusOK)
	ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverRecord.ID+"/owner/pairing-codes", ownerTokenA,
		map[string]any{}, http.StatusUnauthorized)
	ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverRecord.ID+"/owner/claim", guestToken, map[string]any{
			"claim_key": claimKey,
			"device":    ownerTestDevice("Duplicate", deviceAPublic),
		}, http.StatusConflict)

	pairing := ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverRecord.ID+"/owner/pairing-codes", ownerTokenA,
		ownerProofBody(t, api, serverRecord.ID, ownerTokenA, deviceA, deviceAPrivate), http.StatusOK)
	if pairing["expires_in_seconds"].(float64) != 300 {
		t.Fatalf("pairing TTL = %#v", pairing["expires_in_seconds"])
	}
	pairingCode := pairing["code"].(string)
	guestB, err := repo.CreateUser(ctx, "Guest B")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.SetServerMember(ctx, serverRecord.ID, guestB.ID, store.RoleUser, nil); err != nil {
		t.Fatal(err)
	}
	guestBToken := mustToken(t, cfg, guestB.ID)
	deviceBPublic, deviceBPrivate := generateOwnerKey(t)
	pair := ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverRecord.ID+"/owner/pair", guestBToken, map[string]any{
			"code": pairingCode, "device": ownerTestDevice("Device B", deviceBPublic),
		}, http.StatusOK)
	ownerTokenB := pair["token"].(string)
	deviceB := pair["owner_device"].(map[string]any)["id"].(string)
	ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverRecord.ID+"/owner/pair", guestBToken, map[string]any{
			"code": pairingCode, "device": ownerTestDevice("Duplicate B", deviceBPublic),
		}, http.StatusUnauthorized)

	ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverRecord.ID+"/owner/devices/"+deviceA+"/kick",
		ownerTokenB,
		ownerProofBody(t, api, serverRecord.ID, ownerTokenB, deviceB, deviceBPrivate), http.StatusOK)
	ownerRequest(t, api, http.MethodGet,
		"/api/v1/servers/"+serverRecord.ID+"/owner/devices",
		ownerTokenA, nil, http.StatusUnauthorized)
	ownerTokenA = authenticateOwnerDevice(t, api, serverRecord.ID, guestToken, deviceA, deviceAPrivate)

	ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverRecord.ID+"/owner/challenges", guestToken,
		map[string]any{"method": "recovery"}, http.StatusBadRequest)
	ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverRecord.ID+"/owner/recover", guestToken,
		map[string]any{}, http.StatusNotFound)
	ownerRequest(t, api, http.MethodDelete,
		"/api/v1/servers/"+serverRecord.ID+"/owner/devices/"+deviceA,
		ownerTokenB,
		ownerProofBody(t, api, serverRecord.ID, ownerTokenB, deviceB, deviceBPrivate), http.StatusOK)
	ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverRecord.ID+"/owner/challenges", guestToken,
		map[string]any{"method": "device", "device_id": deviceA}, http.StatusUnauthorized)

	resetKey := "new-reset-claim"
	if _, err := repo.ResetOwnerCredentials(
		ctx, serverRecord.ID, auth.SecretHash(resetKey), time.Now().UTC().Add(time.Hour),
	); err != nil {
		t.Fatal(err)
	}
	ownerRequest(t, api, http.MethodGet,
		"/api/v1/servers/"+serverRecord.ID+"/owner/devices",
		ownerTokenB, nil, http.StatusUnauthorized)
	normalOwnerToken := mustToken(t, cfg, owner.ID)
	resetStatus := ownerRequest(t, api, http.MethodGet,
		"/api/v1/servers/"+serverRecord.ID+"/owner/status",
		normalOwnerToken, nil, http.StatusOK)
	if resetStatus["claimed"] != false || resetStatus["claim_available"] != true {
		t.Fatalf("unexpected reset owner status: %#v", resetStatus)
	}
	resetDevicePublic, _ := generateOwnerKey(t)
	resetClaim := ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverRecord.ID+"/owner/claim", normalOwnerToken, map[string]any{
			"claim_key": resetKey,
			"device":    ownerTestDevice("Reset Device", resetDevicePublic),
		}, http.StatusOK)
	if resetClaim["token"] == "" {
		t.Fatal("missing owner token after reset claim")
	}

	_ = deviceB
	_ = deviceBPrivate
}

func ownerProofBody(t *testing.T, api http.Handler, serverID, ownerToken, deviceID string, privateKey ed25519.PrivateKey) map[string]any {
	t.Helper()
	challenge := ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverID+"/owner/challenges", ownerToken,
		map[string]any{"method": "device", "device_id": deviceID}, http.StatusOK)
	return map[string]any{
		"challenge_id": challenge["id"],
		"signature":    signOwnerChallenge(t, privateKey, challenge["challenge"].(string)),
	}
}

func TestServerCreationReturnsOneTimeOwnerClaimKey(t *testing.T) {
	ctx := context.Background()
	db, err := database.OpenSQLite(ctx, filepath.Join(t.TempDir(), "openspeak.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	repo := store.NewSQLite(db)
	hub := realtime.NewHub()
	hubCtx, cancelHub := context.WithCancel(ctx)
	go hub.Run(hubCtx)
	t.Cleanup(cancelHub)
	cfg := config.Config{
		JWTSecret: "create-owner-secret", JWTTTL: time.Hour,
		DefaultEncryptionMode: "none", DefaultHistoryRetentionDays: 30,
		FileRoot: t.TempDir(),
	}
	api := NewServer(cfg, repo, hub)
	creator, err := repo.CreateUser(ctx, "Owner")
	if err != nil {
		t.Fatal(err)
	}
	creatorToken := mustToken(t, cfg, creator.ID)
	createResult := ownerRequest(t, api, http.MethodPost, "/api/v1/servers", creatorToken, map[string]any{
		"name": "Created Server",
	}, http.StatusOK)
	if createResult["owner_claim_key"] == "" || createResult["owner_claim_expires_at"] == nil {
		t.Fatalf("missing owner claim bootstrap: %#v", createResult)
	}
	serverID := createResult["id"].(string)
	loginResult := ownerRequest(t, api, http.MethodPost, "/api/v1/auth/login", "", map[string]any{
		"display_name": "Local User", "password": "",
	}, http.StatusOK)
	status := ownerRequest(t, api, http.MethodGet,
		"/api/v1/servers/"+serverID+"/owner/status", loginResult["token"].(string), nil, http.StatusOK)
	if status["claimed"] != false || status["claim_available"] != true {
		t.Fatalf("unexpected claim status: %#v", status)
	}
}

func authenticateOwnerDevice(t *testing.T, api http.Handler, serverID, guestToken, deviceID string, privateKey ed25519.PrivateKey) string {
	t.Helper()
	challenge := ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverID+"/owner/challenges", guestToken,
		map[string]any{"method": "device", "device_id": deviceID}, http.StatusOK)
	result := ownerRequest(t, api, http.MethodPost,
		"/api/v1/servers/"+serverID+"/owner/authenticate", guestToken, map[string]any{
			"challenge_id": challenge["id"],
			"signature":    signOwnerChallenge(t, privateKey, challenge["challenge"].(string)),
		}, http.StatusOK)
	return result["token"].(string)
}

func ownerRequest(t *testing.T, handler http.Handler, method, path, token string, body any, expectedStatus int) map[string]any {
	t.Helper()
	var bodyText string
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		bodyText = string(encoded)
	}
	request := httptest.NewRequest(method, path, strings.NewReader(bodyText))
	request.Header.Set("Content-Type", "application/json")
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != expectedStatus {
		t.Fatalf("%s %s status = %d, want %d, body = %s", method, path, response.Code, expectedStatus, response.Body.String())
	}
	if response.Body.Len() == 0 {
		return nil
	}
	var value map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &value); err != nil {
		t.Fatalf("decode response: %v; body = %s", err, response.Body.String())
	}
	return value
}

func generateOwnerKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return publicKey, privateKey
}

func ownerTestDevice(label string, publicKey ed25519.PublicKey) map[string]any {
	return map[string]any{
		"device_id": "odev_" + encodeOwnerBytes(publicKey)[:24],
		"label":     label, "platform": "test", "client_version": "test",
		"public_key": encodeOwnerBytes(publicKey),
	}
}

func signOwnerChallenge(t *testing.T, privateKey ed25519.PrivateKey, challenge string) string {
	t.Helper()
	value, err := base64.RawURLEncoding.DecodeString(challenge)
	if err != nil {
		t.Fatal(err)
	}
	return encodeOwnerBytes(ed25519.Sign(privateKey, value))
}

func encodeOwnerBytes(value []byte) string {
	return base64.RawURLEncoding.EncodeToString(value)
}

func mustToken(t *testing.T, cfg config.Config, userID string) string {
	t.Helper()
	token, _, err := auth.CreateToken(cfg.JWTSecret, auth.Claims{Subject: userID}, cfg.JWTTTL)
	if err != nil {
		t.Fatal(err)
	}
	return token
}
