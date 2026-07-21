package httpapi

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"openspeak/internal/auth"
	"openspeak/internal/store"
)

const (
	ownerClaimTTL     = 24 * time.Hour
	ownerPairingTTL   = 5 * time.Minute
	ownerChallengeTTL = 2 * time.Minute
)

type ownerChallenge struct {
	ID              string
	ServerID        string
	RequesterUserID string
	Method          string
	DeviceID        string
	PublicKey       string
	Value           string
	ExpiresAt       time.Time
}

type ownerChallengeStore struct {
	mu    sync.Mutex
	items map[string]ownerChallenge
}

func newOwnerChallengeStore() *ownerChallengeStore {
	return &ownerChallengeStore{items: make(map[string]ownerChallenge)}
}

func (s *ownerChallengeStore) create(serverID, requesterUserID, method, deviceID, publicKey string) (ownerChallenge, error) {
	id, err := auth.RandomToken(18)
	if err != nil {
		return ownerChallenge{}, err
	}
	valueBytes := make([]byte, 32)
	if _, err := rand.Read(valueBytes); err != nil {
		return ownerChallenge{}, err
	}
	challenge := ownerChallenge{
		ID:              id,
		ServerID:        serverID,
		RequesterUserID: requesterUserID,
		Method:          method,
		DeviceID:        deviceID,
		PublicKey:       publicKey,
		Value:           base64.RawURLEncoding.EncodeToString(valueBytes),
		ExpiresAt:       time.Now().UTC().Add(ownerChallengeTTL),
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now().UTC()
	for key, item := range s.items {
		if !item.ExpiresAt.After(now) {
			delete(s.items, key)
		}
	}
	s.items[id] = challenge
	return challenge, nil
}

func (s *ownerChallengeStore) consume(id, serverID, requesterUserID, method string) (ownerChallenge, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	challenge, ok := s.items[id]
	if !ok ||
		challenge.ServerID != serverID ||
		challenge.RequesterUserID != requesterUserID ||
		challenge.Method != method ||
		!challenge.ExpiresAt.After(time.Now().UTC()) {
		return ownerChallenge{}, false
	}
	delete(s.items, id)
	return challenge, true
}

type ownerDeviceInput struct {
	DeviceID      string `json:"device_id"`
	PublicKey     string `json:"public_key"`
	Label         string `json:"label"`
	Platform      string `json:"platform"`
	ClientVersion string `json:"client_version"`
}

func (input ownerDeviceInput) model(serverID, method string) (store.OwnerDevice, error) {
	key, err := decodePublicKey(input.PublicKey)
	if err != nil {
		return store.OwnerDevice{}, err
	}
	sum := sha256.Sum256(key)
	deviceID := strings.TrimSpace(input.DeviceID)
	if !strings.HasPrefix(deviceID, "odev_") || len(deviceID) < 21 || len(deviceID) > 64 {
		return store.OwnerDevice{}, errors.New("device_id must be a client-generated odev_ identifier")
	}
	return store.OwnerDevice{
		ID:                   deviceID,
		ServerID:             serverID,
		Label:                strings.TrimSpace(input.Label),
		Platform:             strings.TrimSpace(input.Platform),
		ClientVersion:        strings.TrimSpace(input.ClientVersion),
		PublicKey:            base64.RawURLEncoding.EncodeToString(key),
		PublicKeyFingerprint: base64.RawURLEncoding.EncodeToString(sum[:12]),
		AuthorizationMethod:  method,
	}, nil
}

func (s *Server) handleOwner(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string, parts []string) {
	if !s.requireServerAccess(w, r, authCtx, serverID) {
		return
	}
	if len(parts) == 1 && parts[0] == "status" && r.Method == http.MethodGet {
		s.handleOwnerStatus(w, r, authCtx, serverID)
		return
	}
	if len(parts) == 1 && parts[0] == "claim" && r.Method == http.MethodPost {
		s.handleOwnerClaim(w, r, authCtx, serverID)
		return
	}
	if len(parts) == 1 && parts[0] == "pair" && r.Method == http.MethodPost {
		s.handleOwnerPair(w, r, authCtx, serverID)
		return
	}
	if len(parts) == 1 && parts[0] == "challenges" && r.Method == http.MethodPost {
		s.handleOwnerChallenge(w, r, authCtx, serverID)
		return
	}
	if len(parts) == 1 && parts[0] == "authenticate" && r.Method == http.MethodPost {
		s.handleOwnerAuthenticate(w, r, authCtx, serverID)
		return
	}
	if len(parts) == 1 && parts[0] == "pairing-codes" && r.Method == http.MethodPost {
		if !s.requireOwnerDevice(w, authCtx, serverID) {
			return
		}
		if !s.requireFreshOwnerProof(w, r, authCtx, serverID) {
			return
		}
		s.handleOwnerPairingCode(w, r, authCtx, serverID)
		return
	}
	if len(parts) == 1 && parts[0] == "devices" && r.Method == http.MethodGet {
		if !s.requireOwnerDevice(w, authCtx, serverID) {
			return
		}
		s.handleOwnerDevices(w, r, serverID)
		return
	}
	if len(parts) == 3 && parts[0] == "devices" && parts[2] == "kick" && r.Method == http.MethodPost {
		if !s.requireOwnerDevice(w, authCtx, serverID) {
			return
		}
		if !s.requireFreshOwnerProof(w, r, authCtx, serverID) {
			return
		}
		device, err := s.repo.KickOwnerDevice(r.Context(), serverID, parts[1])
		if err != nil {
			writeOwnerError(w, err)
			return
		}
		s.hub.DisconnectOwnerDevice(serverID, parts[1], "owner.session_revoked")
		slog.Info("owner security event", "action", "device_session_kicked", "server_id", serverID, "actor_device_id", authCtx.Claims.OwnerDeviceID, "target_device_id", parts[1])
		writeJSON(w, http.StatusOK, device)
		return
	}
	if len(parts) == 2 && parts[0] == "devices" && r.Method == http.MethodDelete {
		if !s.requireOwnerDevice(w, authCtx, serverID) {
			return
		}
		if !s.requireFreshOwnerProof(w, r, authCtx, serverID) {
			return
		}
		if err := s.repo.RevokeOwnerDevice(r.Context(), serverID, parts[1]); err != nil {
			writeOwnerError(w, err)
			return
		}
		s.hub.DisconnectOwnerDevice(serverID, parts[1], "owner.credentials_revoked")
		slog.Info("owner security event", "action", "device_revoked", "server_id", serverID, "actor_device_id", authCtx.Claims.OwnerDeviceID, "target_device_id", parts[1])
		writeJSON(w, http.StatusOK, map[string]any{"revoked": true})
		return
	}
	writeError(w, http.StatusNotFound, "not_found", "route not found")
}

func (s *Server) requireFreshOwnerProof(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) bool {
	var req struct {
		ChallengeID string `json:"challenge_id"`
		Signature   string `json:"signature"`
	}
	if !decodeJSON(w, r, &req) {
		return false
	}
	return s.verifyFreshOwnerProof(w, authCtx, serverID, req.ChallengeID, req.Signature)
}

func (s *Server) verifyFreshOwnerProof(w http.ResponseWriter, authCtx authContext, serverID, challengeID, signature string) bool {
	challenge, ok := s.ownerChallenges.consume(
		challengeID, serverID, authCtx.User.ID, "device",
	)
	if !ok ||
		challenge.DeviceID != authCtx.Claims.OwnerDeviceID ||
		!verifyChallenge(challenge, signature) {
		writeError(w, http.StatusUnauthorized, "invalid_owner_proof", "a fresh owner device signature is required")
		return false
	}
	return true
}

func (s *Server) handleOwnerStatus(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) {
	security, err := s.repo.GetOwnerSecurity(r.Context(), serverID)
	if errors.Is(err, store.ErrNotFound) {
		writeJSON(w, http.StatusOK, map[string]any{
			"claimed": false, "claim_available": false, "is_owner": false,
		})
		return
	}
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	isOwner := authCtx.Claims.OwnerServerID == serverID && authCtx.Claims.OwnerDeviceID != ""
	writeJSON(w, http.StatusOK, map[string]any{
		"claimed":                 security.Claimed,
		"claim_available":         !security.Claimed && security.ClaimExpiresAt != nil && security.ClaimExpiresAt.After(time.Now().UTC()),
		"claim_expires_at":        security.ClaimExpiresAt,
		"is_owner":                isOwner,
		"current_owner_device_id": authCtx.Claims.OwnerDeviceID,
	})
}

func (s *Server) handleOwnerClaim(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) {
	var req struct {
		ClaimKey string           `json:"claim_key"`
		Device   ownerDeviceInput `json:"device"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	device, err := req.Device.model(serverID, "initial_claim")
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_device_key", err.Error())
		return
	}
	security, saved, err := s.repo.ClaimOwner(
		r.Context(), serverID, auth.SecretHash(strings.TrimSpace(req.ClaimKey)),
		device,
	)
	if err != nil {
		writeOwnerError(w, err)
		return
	}
	s.writeOwnerToken(r.Context(), w, security, saved, authCtx.User.DisplayName)
	slog.Info("owner security event", "action", "initial_claim", "server_id", serverID, "owner_device_id", saved.ID)
}

func (s *Server) handleOwnerPairingCode(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) {
	code, err := auth.RandomToken(12)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	expiresAt := time.Now().UTC().Add(ownerPairingTTL)
	if err := s.repo.CreateOwnerPairingToken(
		r.Context(), serverID, auth.SecretHash(code),
		authCtx.Claims.OwnerDeviceID, expiresAt,
	); err != nil {
		writeResult(w, nil, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"code": code, "expires_at": expiresAt, "expires_in_seconds": int(ownerPairingTTL.Seconds()),
	})
	slog.Info("owner security event", "action", "pairing_code_created", "server_id", serverID, "owner_device_id", authCtx.Claims.OwnerDeviceID, "expires_at", expiresAt)
}

func (s *Server) handleOwnerPair(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) {
	var req struct {
		Code   string           `json:"code"`
		Device ownerDeviceInput `json:"device"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	device, err := req.Device.model(serverID, "pairing_code")
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_device_key", err.Error())
		return
	}
	security, saved, err := s.repo.ConsumeOwnerPairingToken(
		r.Context(), serverID, auth.SecretHash(strings.TrimSpace(req.Code)), device,
	)
	if err != nil {
		writeOwnerError(w, err)
		return
	}
	s.writeOwnerToken(r.Context(), w, security, saved, authCtx.User.DisplayName)
	slog.Info("owner security event", "action", "device_paired", "server_id", serverID, "owner_device_id", saved.ID)
}

func (s *Server) handleOwnerChallenge(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) {
	var req struct {
		Method   string `json:"method"`
		DeviceID string `json:"device_id"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.Method != "device" {
		writeError(w, http.StatusBadRequest, "invalid_method", "method must be device")
		return
	}
	device, err := s.repo.GetOwnerDevice(r.Context(), serverID, req.DeviceID)
	if err != nil || device.RevokedAt != nil {
		writeError(w, http.StatusUnauthorized, "owner_credential_revoked", "owner device is not active")
		return
	}
	challenge, err := s.ownerChallenges.create(
		serverID, authCtx.User.ID, req.Method, req.DeviceID, device.PublicKey,
	)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id": challenge.ID, "challenge": challenge.Value, "expires_at": challenge.ExpiresAt,
	})
}

func (s *Server) handleOwnerAuthenticate(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) {
	var req struct {
		ChallengeID string `json:"challenge_id"`
		Signature   string `json:"signature"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	challenge, ok := s.ownerChallenges.consume(req.ChallengeID, serverID, authCtx.User.ID, "device")
	if !ok || !verifyChallenge(challenge, req.Signature) {
		writeError(w, http.StatusUnauthorized, "invalid_owner_proof", "invalid or expired owner proof")
		return
	}
	security, err := s.repo.GetOwnerSecurity(r.Context(), serverID)
	if err != nil {
		writeOwnerError(w, err)
		return
	}
	device, err := s.repo.GetOwnerDevice(r.Context(), serverID, challenge.DeviceID)
	if err != nil || device.RevokedAt != nil {
		writeError(w, http.StatusUnauthorized, "owner_credential_revoked", "owner device is not active")
		return
	}
	s.writeOwnerToken(r.Context(), w, security, device, authCtx.User.DisplayName)
}

func (s *Server) handleOwnerDevices(w http.ResponseWriter, r *http.Request, serverID string) {
	devices, err := s.repo.ListOwnerDevices(r.Context(), serverID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	for i := range devices {
		devices[i].Online = s.hub.OwnerDeviceOnline(serverID, devices[i].ID)
		devices[i].PublicKey = ""
	}
	writeJSON(w, http.StatusOK, devices)
}

func (s *Server) requireOwnerDevice(w http.ResponseWriter, authCtx authContext, serverID string) bool {
	if authCtx.Claims.OwnerServerID != serverID || authCtx.Claims.OwnerDeviceID == "" {
		writeError(w, http.StatusForbidden, "owner_device_required", "an authenticated owner device is required")
		return false
	}
	return true
}

func (s *Server) writeOwnerToken(ctx context.Context, w http.ResponseWriter, security store.OwnerSecurity, device store.OwnerDevice, displayName string) {
	user, err := s.repo.GetUser(ctx, security.OwnerUserID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if strings.TrimSpace(displayName) != "" {
		user.DisplayName = strings.TrimSpace(displayName)
	}
	token, expiresAt, err := auth.CreateToken(s.cfg.JWTSecret, auth.Claims{
		Subject:                user.ID,
		DisplayName:            user.DisplayName,
		OwnerServerID:          security.ServerID,
		OwnerDeviceID:          device.ID,
		OwnerGeneration:        security.AuthGeneration,
		OwnerSessionGeneration: device.SessionGeneration,
	}, s.cfg.JWTTTL)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"token": token, "expires_at": expiresAt, "user": user, "owner_device": device,
	})
}

func verifyChallenge(challenge ownerChallenge, signatureValue string) bool {
	publicKey, err := decodePublicKey(challenge.PublicKey)
	if err != nil {
		return false
	}
	signature, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(signatureValue))
	if err != nil || len(signature) != ed25519.SignatureSize {
		return false
	}
	value, err := base64.RawURLEncoding.DecodeString(challenge.Value)
	if err != nil {
		return false
	}
	return ed25519.Verify(publicKey, value, signature)
}

func decodePublicKey(value string) (ed25519.PublicKey, error) {
	decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(value))
	if err != nil || len(decoded) != ed25519.PublicKeySize {
		return nil, errors.New("public key must be a base64url Ed25519 public key")
	}
	return ed25519.PublicKey(decoded), nil
}

func writeOwnerError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrOwnerAlreadyClaimed):
		writeError(w, http.StatusConflict, "owner_already_claimed", "server owner has already been claimed")
	case errors.Is(err, store.ErrInvalidOwnerToken):
		writeError(w, http.StatusUnauthorized, "invalid_owner_token", "invalid or expired owner credential")
	case errors.Is(err, store.ErrOwnerDeviceRevoked):
		writeError(w, http.StatusUnauthorized, "owner_credential_revoked", "owner device is no longer trusted")
	case errors.Is(err, store.ErrLastOwnerDevice):
		writeError(w, http.StatusConflict, "last_owner_device", "the last owner device can only be cleared with openspeakctl owner recover")
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "resource not found")
	default:
		writeResult(w, nil, err)
	}
}
