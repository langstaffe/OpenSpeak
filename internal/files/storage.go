package files

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"mime/multipart"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"openspeak/internal/ids"
)

type SaveResult struct {
	OriginalName string
	ContentType  string
	SizeBytes    int64
	SHA256Hex    string
	RelativePath string
}

func SaveMultipart(root, serverID, kind string, header *multipart.FileHeader, originalNameOverride ...string) (SaveResult, error) {
	src, err := header.Open()
	if err != nil {
		return SaveResult{}, err
	}
	defer src.Close()

	originalName := OriginalName(header.Filename)
	if len(originalNameOverride) > 0 && strings.TrimSpace(originalNameOverride[0]) != "" {
		originalName = OriginalName(originalNameOverride[0])
	}
	cleanName := SanitizeName(originalName)
	day := time.Now().UTC().Format("2006/01/02")
	relDir := filepath.Join(serverID, kind, day)
	fileID := ids.New("blob")
	relPath := filepath.Join(relDir, fileID+"-"+cleanName)
	absPath := filepath.Join(root, relPath)

	if err := os.MkdirAll(filepath.Dir(absPath), 0o750); err != nil {
		return SaveResult{}, err
	}

	dst, err := os.OpenFile(absPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o640)
	if err != nil {
		return SaveResult{}, err
	}
	defer dst.Close()

	hasher := sha256.New()
	tee := io.TeeReader(src, hasher)
	size, err := io.Copy(dst, tee)
	if err != nil {
		return SaveResult{}, err
	}

	contentType := header.Header.Get("Content-Type")
	if contentType == "" {
		contentType = DetectContentTypeFromName(originalName)
	}

	return SaveResult{
		OriginalName: originalName,
		ContentType:  contentType,
		SizeBytes:    size,
		SHA256Hex:    hex.EncodeToString(hasher.Sum(nil)),
		RelativePath: filepath.ToSlash(relPath),
	}, nil
}

func OriginalName(name string) string {
	name = strings.TrimSpace(strings.ReplaceAll(name, `\`, `/`))
	name = path.Base(name)
	name = strings.Map(func(r rune) rune {
		if r == 0 || unicode.IsControl(r) || r == '/' || r == '\\' {
			return -1
		}
		return r
	}, name)
	name = strings.TrimSpace(name)
	if name == "" || name == "." || name == ".." {
		return "file"
	}
	return trimNamePreserveExt(name, 180)
}

func SanitizeName(name string) string {
	name = filepath.Base(name)
	name = strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z':
			return r
		case r >= 'A' && r <= 'Z':
			return r
		case r >= '0' && r <= '9':
			return r
		case r == '.', r == '-', r == '_':
			return r
		default:
			return '_'
		}
	}, name)
	name = strings.Trim(name, "._-")
	if name == "" {
		return "file"
	}
	return trimNamePreserveExt(name, 180)
}

func trimNamePreserveExt(name string, maxRunes int) string {
	runes := []rune(name)
	if len(runes) <= maxRunes {
		return name
	}
	ext := filepath.Ext(name)
	extRunes := []rune(ext)
	if len(extRunes) == 0 || len(extRunes) > 32 || len(extRunes) >= maxRunes {
		return string(runes[:maxRunes])
	}
	baseRunes := []rune(strings.TrimSuffix(name, ext))
	keepBase := maxRunes - len(extRunes)
	if keepBase < 1 {
		return string(runes[:maxRunes])
	}
	if len(baseRunes) > keepBase {
		baseRunes = baseRunes[:keepBase]
	}
	return string(baseRunes) + ext
}
