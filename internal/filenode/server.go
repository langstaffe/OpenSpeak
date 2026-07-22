package filenode

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Server struct {
	Root   string
	Secret string
}

type objectMetadata struct {
	SizeBytes int64  `json:"size_bytes"`
	SHA256Hex string `json:"sha256_hex"`
	ExpiresAt int64  `json:"expires_at,omitempty"`
	Committed bool   `json:"committed,omitempty"`
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/health" {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	const prefix = "/v1/objects/"
	if !strings.HasPrefix(r.URL.Path, prefix) {
		http.NotFound(w, r)
		return
	}
	key := strings.TrimPrefix(r.URL.Path, prefix)
	ticket, err := Validate(key, r.URL.Query(), s.Secret)
	if err != nil {
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	}
	if r.Header.Get("Origin") != "" {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Range")
		w.Header().Set("Access-Control-Expose-Headers", "Accept-Ranges, Content-Length, Content-Range, X-OpenSpeak-SHA256")
	}
	if r.Method == http.MethodOptions {
		method := map[string]string{"put": http.MethodPut, "get": http.MethodGet, "delete": http.MethodDelete}[ticket.Operation]
		if method == "" {
			http.Error(w, "ticket operation mismatch", http.StatusForbidden)
			return
		}
		w.Header().Set("Access-Control-Allow-Methods", method+", OPTIONS")
		w.Header().Set("Access-Control-Max-Age", "600")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	path := filepath.Join(s.Root, key)
	switch {
	case r.Method == http.MethodPut && ticket.Operation == "put":
		s.put(w, r, path, ticket)
	case (r.Method == http.MethodGet || r.Method == http.MethodHead) && ticket.Operation == "get":
		s.get(w, r, path, ticket)
	case r.Method == http.MethodDelete && ticket.Operation == "delete":
		err := os.Remove(path)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		_ = os.Remove(path + ".meta")
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "ticket operation mismatch", http.StatusForbidden)
	}
}

func (s *Server) put(w http.ResponseWriter, r *http.Request, path string, ticket Ticket) {
	if ticket.MaxBytes <= 0 || (r.ContentLength > ticket.MaxBytes && r.ContentLength >= 0) {
		http.Error(w, "file too large", http.StatusRequestEntityTooLarge)
		return
	}
	if err := os.MkdirAll(s.Root, 0o750); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	temp, err := os.CreateTemp(s.Root, ".upload-*")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	tempName := temp.Name()
	defer os.Remove(tempName)
	hash := sha256.New()
	written, copyErr := io.Copy(io.MultiWriter(temp, hash), io.LimitReader(r.Body, ticket.MaxBytes+1))
	closeErr := temp.Close()
	if copyErr != nil || closeErr != nil {
		http.Error(w, errors.Join(copyErr, closeErr).Error(), http.StatusInternalServerError)
		return
	}
	if written > ticket.MaxBytes {
		http.Error(w, "file too large", http.StatusRequestEntityTooLarge)
		return
	}
	sha := hex.EncodeToString(hash.Sum(nil))
	if err := os.Rename(tempName, path); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	metadata := objectMetadata{SizeBytes: written, SHA256Hex: sha, ExpiresAt: ticket.ExpiresAt.Unix()}
	if err := writeMetadata(path+".meta", metadata); err != nil {
		_ = os.Remove(path)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"size_bytes": written, "sha256_hex": sha})
}

func (s *Server) get(w http.ResponseWriter, r *http.Request, path string, ticket Ticket) {
	if ticket.Commit && r.Method != http.MethodHead {
		http.Error(w, "commit requires HEAD", http.StatusForbidden)
		return
	}
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", ticket.ContentType)
	w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
	w.Header().Set("Content-Disposition", `attachment; filename="download"`)
	if metadata, err := readMetadata(path + ".meta"); err == nil {
		if ticket.Commit && !metadata.Committed {
			metadata.Committed = true
			if err := writeMetadata(path+".meta", metadata); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
		}
		w.Header().Set("X-OpenSpeak-SHA256", metadata.SHA256Hex)
	}
	http.ServeContent(w, r, ticket.Name, info.ModTime(), file)
}

func (s *Server) CleanupOrphans(now time.Time) (int, error) {
	entries, err := os.ReadDir(s.Root)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	removed := 0
	for _, entry := range entries {
		name := entry.Name()
		path := filepath.Join(s.Root, name)
		if strings.HasPrefix(name, ".upload-") || strings.HasPrefix(name, ".meta-") {
			if info, err := entry.Info(); err == nil && now.Sub(info.ModTime()) >= time.Hour {
				if os.Remove(path) == nil {
					removed++
				}
			}
			continue
		}
		if entry.IsDir() || !strings.HasSuffix(name, ".meta") {
			continue
		}
		metadata, err := readMetadata(path)
		if err != nil || metadata.Committed || metadata.ExpiresAt <= 0 || metadata.ExpiresAt > now.Unix() {
			continue
		}
		objectPath := strings.TrimSuffix(path, ".meta")
		if err := os.Remove(objectPath); err != nil && !errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err := os.Remove(path); err == nil || errors.Is(err, os.ErrNotExist) {
			removed++
		}
	}
	return removed, nil
}

func (s *Server) RunOrphanCleaner(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		interval = time.Minute
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		if _, err := s.CleanupOrphans(time.Now()); err != nil && ctx.Err() == nil {
			slog.Error("file node orphan cleanup failed", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func readMetadata(path string) (objectMetadata, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return objectMetadata{}, err
	}
	var value objectMetadata
	err = json.Unmarshal(raw, &value)
	return value, err
}

func writeMetadata(path string, value objectMetadata) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".meta-*")
	if err != nil {
		return err
	}
	tempName := temp.Name()
	defer os.Remove(tempName)
	if err := temp.Chmod(0o640); err != nil {
		_ = temp.Close()
		return err
	}
	if _, err := temp.Write(raw); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(tempName, path)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
