package httpapi

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"image"
	"image/color"
	_ "image/gif"
	"image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"openspeak/internal/realtime"
)

const maxAvatarBytes = 20 << 20
const maxAvatarDimension = 8192
const avatarThumbnailSize = 128

func (s *Server) avatarDir(userID string) string {
	return filepath.Join(s.cfg.FileRoot, "avatars", userID)
}

func (s *Server) serverAvatarDir(serverID string) string {
	return filepath.Join(s.cfg.FileRoot, "server_avatars", serverID)
}

func (s *Server) handleUserAvatar(w http.ResponseWriter, r *http.Request, userID string) {
	name := "original"
	contentType := "application/octet-stream"
	if r.URL.Query().Get("size") == "small" {
		name = "small.png"
		contentType = "image/png"
		if err := s.ensureAvatarThumbnail(userID); err != nil && !os.IsNotExist(err) {
			writeResult(w, nil, err)
			return
		}
	}
	path := filepath.Join(s.avatarDir(userID), name)
	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			writeError(w, http.StatusNotFound, "avatar_not_found", "avatar not found")
			return
		}
		writeResult(w, nil, err)
		return
	}
	defer file.Close()
	if name == "original" {
		var header [512]byte
		n, _ := file.Read(header[:])
		contentType = http.DetectContentType(header[:n])
		_, _ = file.Seek(0, io.SeekStart)
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	http.ServeContent(w, r, name, time.Time{}, file)
}

func (s *Server) handleAvatarUpload(w http.ResponseWriter, r *http.Request, authCtx authContext) {
	data, thumbnail, digest, ok := decodeAvatarUpload(w, r)
	if !ok {
		return
	}
	dir := s.avatarDir(authCtx.User.ID)
	if err := saveAvatarFiles(dir, data, thumbnail); err != nil {
		writeResult(w, nil, err)
		return
	}
	user, err := s.repo.IncrementUserAvatarVersion(r.Context(), authCtx.User.ID, digest)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	s.hub.Publish(realtimeProfileUpdated(user.ID, user.DisplayName, user.AvatarVersion))
	writeJSON(w, http.StatusOK, user)
}

func (s *Server) handleServerAvatar(w http.ResponseWriter, r *http.Request, serverID string) {
	handleAvatarDownload(w, r, s.serverAvatarDir(serverID))
}

func handleAvatarDownload(w http.ResponseWriter, r *http.Request, dir string) {
	name := "original"
	contentType := "application/octet-stream"
	if r.URL.Query().Get("size") == "small" {
		name = "small.png"
		contentType = "image/png"
	}
	file, err := os.Open(filepath.Join(dir, name))
	if err != nil {
		if os.IsNotExist(err) {
			writeError(w, http.StatusNotFound, "avatar_not_found", "avatar not found")
			return
		}
		writeResult(w, nil, err)
		return
	}
	defer file.Close()
	if name == "original" {
		var header [512]byte
		n, _ := file.Read(header[:])
		contentType = http.DetectContentType(header[:n])
		_, _ = file.Seek(0, io.SeekStart)
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	http.ServeContent(w, r, name, time.Time{}, file)
}

func (s *Server) handleServerAvatarUpload(w http.ResponseWriter, r *http.Request, serverID string) {
	data, thumbnail, digest, ok := decodeAvatarUpload(w, r)
	if !ok {
		return
	}
	if err := saveAvatarFiles(s.serverAvatarDir(serverID), data, thumbnail); err != nil {
		writeResult(w, nil, err)
		return
	}
	server, err := s.repo.IncrementServerAvatarVersion(r.Context(), serverID, digest)
	writeResult(w, server, err)
}

func decodeAvatarUpload(w http.ResponseWriter, r *http.Request) ([]byte, []byte, string, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, maxAvatarBytes+(1<<20))
	if err := r.ParseMultipartForm(maxAvatarBytes); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_avatar", "头像文件不能超过 20 MiB")
		return nil, nil, "", false
	}
	file, _, err := r.FormFile("avatar")
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_avatar", "avatar file is required")
		return nil, nil, "", false
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxAvatarBytes+1))
	if err != nil || len(data) == 0 || len(data) > maxAvatarBytes {
		writeError(w, http.StatusBadRequest, "invalid_avatar", "头像文件不能超过 20 MiB")
		return nil, nil, "", false
	}
	contentType := http.DetectContentType(data)
	if !strings.HasPrefix(contentType, "image/jpeg") && contentType != "image/png" && contentType != "image/gif" {
		writeError(w, http.StatusBadRequest, "invalid_avatar_type", "仅支持 JPEG、PNG 或 GIF 头像")
		return nil, nil, "", false
	}
	config, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || config.Width < 1 || config.Height < 1 || config.Width > maxAvatarDimension || config.Height > maxAvatarDimension {
		writeError(w, http.StatusBadRequest, "invalid_avatar_dimensions", "头像尺寸无效或超过 8192×8192")
		return nil, nil, "", false
	}
	source, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_avatar", "无法解码头像图片")
		return nil, nil, "", false
	}
	thumbnail := squareThumbnail(source, avatarThumbnailSize)
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, thumbnail); err != nil {
		writeResult(w, nil, err)
		return nil, nil, "", false
	}
	digest := sha256.Sum256(data)
	return data, encoded.Bytes(), hex.EncodeToString(digest[:]), true
}

func saveAvatarFiles(dir string, original, thumbnail []byte) error {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return err
	}
	if err := writeAvatarFile(filepath.Join(dir, "original"), original); err != nil {
		return err
	}
	return writeAvatarFile(filepath.Join(dir, "small.png"), thumbnail)
}

func (s *Server) ensureAvatarThumbnail(userID string) error {
	dir := s.avatarDir(userID)
	thumbnailPath := filepath.Join(dir, "small.png")
	if _, err := os.Stat(thumbnailPath); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}
	original, err := os.Open(filepath.Join(dir, "original"))
	if err != nil {
		return err
	}
	defer original.Close()
	source, _, err := image.Decode(original)
	if err != nil {
		return err
	}
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, squareThumbnail(source, avatarThumbnailSize)); err != nil {
		return err
	}
	if err := writeAvatarFile(thumbnailPath, encoded.Bytes()); err != nil {
		// Concurrent first reads may both rebuild the same legacy thumbnail.
		// If another request already completed it, the desired result exists.
		if _, statErr := os.Stat(thumbnailPath); statErr == nil {
			return nil
		}
		return err
	}
	return nil
}

func realtimeProfileUpdated(userID, displayName string, avatarVersion int64) realtime.Event {
	return realtime.Event{Type: "user.profile_updated", FromUser: userID, Payload: map[string]any{
		"user_id": userID, "display_name": displayName, "avatar_version": avatarVersion,
	}}
}

func writeAvatarFile(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".avatar-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err = tmp.Write(data); err == nil {
		err = tmp.Close()
	} else {
		_ = tmp.Close()
	}
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return os.Rename(tmpName, path)
}

func squareThumbnail(source image.Image, size int) *image.RGBA {
	b := source.Bounds()
	side := b.Dx()
	if b.Dy() < side {
		side = b.Dy()
	}
	left := b.Min.X + (b.Dx()-side)/2
	top := b.Min.Y + (b.Dy()-side)/2
	dst := image.NewRGBA(image.Rect(0, 0, size, size))
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			sx := left + x*side/size
			sy := top + y*side/size
			r, g, bl, a := source.At(sx, sy).RGBA()
			dst.SetRGBA(x, y, color.RGBA{uint8(r >> 8), uint8(g >> 8), uint8(bl >> 8), uint8(a >> 8)})
		}
	}
	return dst
}
