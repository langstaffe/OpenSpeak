package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

type Claims struct {
	Subject                string `json:"sub"`
	DisplayName            string `json:"display_name,omitempty"`
	OwnerServerID          string `json:"owner_server_id,omitempty"`
	OwnerDeviceID          string `json:"owner_device_id,omitempty"`
	OwnerGeneration        int64  `json:"owner_generation,omitempty"`
	OwnerSessionGeneration int64  `json:"owner_session_generation,omitempty"`
	IssuedAt               int64  `json:"iat"`
	Expires                int64  `json:"exp"`
}

func HashSecret(password string) (string, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	return string(hash), err
}

func CheckPassword(hash, password string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) == nil
}

func RandomToken(byteCount int) (string, error) {
	if byteCount < 16 {
		byteCount = 16
	}
	value := make([]byte, byteCount)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func SecretHash(value string) string {
	sum := sha256.Sum256([]byte(value))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func CreateToken(secret string, claims Claims, ttl time.Duration) (string, time.Time, error) {
	now := time.Now().UTC()
	expiresAt := now.Add(ttl)
	claims.IssuedAt = now.Unix()
	claims.Expires = expiresAt.Unix()
	header := map[string]string{"alg": "HS256", "typ": "JWT"}
	headerJSON, err := json.Marshal(header)
	if err != nil {
		return "", time.Time{}, err
	}
	claimsJSON, err := json.Marshal(claims)
	if err != nil {
		return "", time.Time{}, err
	}
	enc := base64.RawURLEncoding
	unsigned := enc.EncodeToString(headerJSON) + "." + enc.EncodeToString(claimsJSON)
	signature := sign(unsigned, secret)
	return unsigned + "." + signature, expiresAt, nil
}

func ParseToken(secret, token string) (Claims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return Claims{}, errors.New("invalid token")
	}
	unsigned := parts[0] + "." + parts[1]
	expected := sign(unsigned, secret)
	if !hmac.Equal([]byte(expected), []byte(parts[2])) {
		return Claims{}, errors.New("invalid token signature")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return Claims{}, err
	}
	var claims Claims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return Claims{}, err
	}
	if claims.Subject == "" || claims.Expires < time.Now().UTC().Unix() {
		return Claims{}, errors.New("token expired or invalid")
	}
	return claims, nil
}

func sign(unsigned, secret string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(unsigned))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}
