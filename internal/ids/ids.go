package ids

import (
	"crypto/rand"
	"encoding/base32"
	"strings"
)

func New(prefix string) string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	token := strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b[:]))
	if prefix == "" {
		return token
	}
	return prefix + "_" + token
}
