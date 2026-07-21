package filenode

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type Ticket struct {
	Operation   string
	ObjectKey   string
	ExpiresAt   time.Time
	MaxBytes    int64
	Name        string
	ContentType string
	Commit      bool
}

func SignedURL(baseURL, secret string, ticket Ticket) (string, error) {
	if strings.TrimSpace(baseURL) == "" || strings.TrimSpace(secret) == "" || !validObjectKey(ticket.ObjectKey) {
		return "", errors.New("invalid file node ticket")
	}
	values := url.Values{
		"op":   {ticket.Operation},
		"exp":  {strconv.FormatInt(ticket.ExpiresAt.Unix(), 10)},
		"max":  {strconv.FormatInt(ticket.MaxBytes, 10)},
		"name": {ticket.Name},
		"type": {ticket.ContentType},
	}
	if ticket.Commit {
		values.Set("commit", "1")
	}
	values.Set("sig", signature(ticket.ObjectKey, values, secret))
	return strings.TrimRight(baseURL, "/") + "/v1/objects/" + url.PathEscape(ticket.ObjectKey) + "?" + values.Encode(), nil
}

func Validate(objectKey string, values url.Values, secret string) (Ticket, error) {
	if !validObjectKey(objectKey) || strings.TrimSpace(secret) == "" {
		return Ticket{}, errors.New("invalid ticket")
	}
	provided := values.Get("sig")
	unsigned := cloneValues(values)
	unsigned.Del("sig")
	expected := signature(objectKey, unsigned, secret)
	if !hmac.Equal([]byte(provided), []byte(expected)) {
		return Ticket{}, errors.New("invalid ticket signature")
	}
	expires, err := strconv.ParseInt(values.Get("exp"), 10, 64)
	if err != nil || expires < time.Now().UTC().Unix() {
		return Ticket{}, errors.New("ticket expired")
	}
	maxBytes, err := strconv.ParseInt(values.Get("max"), 10, 64)
	if err != nil || maxBytes < 0 {
		return Ticket{}, errors.New("invalid maximum size")
	}
	return Ticket{Operation: values.Get("op"), ObjectKey: objectKey, ExpiresAt: time.Unix(expires, 0).UTC(), MaxBytes: maxBytes, Name: values.Get("name"), ContentType: values.Get("type"), Commit: values.Get("commit") == "1"}, nil
}

func signature(objectKey string, values url.Values, secret string) string {
	unsigned := cloneValues(values)
	unsigned.Del("sig")
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(objectKey + "\n" + unsigned.Encode()))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func cloneValues(values url.Values) url.Values {
	copy := make(url.Values, len(values))
	for key, items := range values {
		copy[key] = append([]string(nil), items...)
	}
	return copy
}

func validObjectKey(value string) bool {
	if value == "" || len(value) > 160 {
		return false
	}
	for _, r := range value {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-' {
			continue
		}
		return false
	}
	return true
}
