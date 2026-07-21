package livekit

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"time"

	"openspeak/internal/config"
)

var (
	ErrNotConfigured       = errors.New("livekit is not configured")
	ErrInvalidTokenRequest = errors.New("identity and room are required")
)

type TokenRequest struct {
	Identity          string   `json:"identity"`
	Name              string   `json:"name"`
	Room              string   `json:"room"`
	CanPublish        bool     `json:"can_publish"`
	CanPublishSources []string `json:"can_publish_sources,omitempty"`
	CanSubscribe      bool     `json:"can_subscribe"`
}

type TokenResponse struct {
	URL       string    `json:"url"`
	Token     string    `json:"token"`
	ExpiresAt time.Time `json:"expires_at"`
}

func CreateAccessToken(cfg config.LiveKitConfig, req TokenRequest) (TokenResponse, error) {
	if cfg.APIKey == "" || cfg.APISecret == "" || cfg.URL == "" {
		return TokenResponse{}, ErrNotConfigured
	}
	if req.Identity == "" || req.Room == "" {
		return TokenResponse{}, ErrInvalidTokenRequest
	}
	now := time.Now().UTC()
	expiresAt := now.Add(cfg.TokenTTL)
	videoClaims := map[string]any{
		"roomJoin":     true,
		"room":         req.Room,
		"canPublish":   req.CanPublish,
		"canSubscribe": req.CanSubscribe,
	}
	if len(req.CanPublishSources) > 0 {
		videoClaims["canPublishSources"] = req.CanPublishSources
	}
	claims := map[string]any{
		"iss":   cfg.APIKey,
		"sub":   req.Identity,
		"nbf":   now.Unix(),
		"exp":   expiresAt.Unix(),
		"name":  req.Name,
		"video": videoClaims,
	}
	token, err := signHS256(claims, cfg.APISecret)
	if err != nil {
		return TokenResponse{}, err
	}
	return TokenResponse{URL: cfg.URL, Token: token, ExpiresAt: expiresAt}, nil
}

func signHS256(claims map[string]any, secret string) (string, error) {
	header := map[string]string{"alg": "HS256", "typ": "JWT"}
	headerJSON, err := json.Marshal(header)
	if err != nil {
		return "", err
	}
	claimsJSON, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	enc := base64.RawURLEncoding
	unsigned := enc.EncodeToString(headerJSON) + "." + enc.EncodeToString(claimsJSON)
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(unsigned))
	signature := enc.EncodeToString(mac.Sum(nil))
	return unsigned + "." + signature, nil
}
