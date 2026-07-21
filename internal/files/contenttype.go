package files

import (
	"mime"
	"path/filepath"
)

func DetectContentTypeFromName(name string) string {
	if ct := mime.TypeByExtension(filepath.Ext(name)); ct != "" {
		return ct
	}
	return "application/octet-stream"
}
