package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"openspeak/internal/files"
	"openspeak/internal/ids"
	"openspeak/internal/realtime"
	"openspeak/internal/store"
)

const (
	maxLocalAttachmentFileSize    int64 = 2 << 30
	maxExternalAttachmentFileSize int64 = 5 << 30
	maxAttachmentImageSize        int64 = 128 << 20
)

type directFile struct {
	ID                 string                       `json:"id"`
	ServerID           string                       `json:"server_id"`
	FromUserID         string                       `json:"from_user_id"`
	ToUserID           string                       `json:"to_user_id"`
	Path               string                       `json:"-"`
	OriginalName       string                       `json:"original_name"`
	ContentType        string                       `json:"content_type"`
	SizeBytes          int64                        `json:"size_bytes"`
	EncryptionMode     string                       `json:"encryption_mode"`
	MessageID          string                       `json:"message_id,omitempty"`
	SenderDeviceID     string                       `json:"sender_device_id,omitempty"`
	Nonce              string                       `json:"nonce,omitempty"`
	PlaintextSizeBytes int64                        `json:"plaintext_size_bytes,omitempty"`
	AttachmentFormat   string                       `json:"attachment_format,omitempty"`
	ChunkSize          int64                        `json:"chunk_size,omitempty"`
	Envelopes          []realtime.DirectKeyEnvelope `json:"-"`
	RecipientDeviceIDs []string                     `json:"-"`
	SenderIdentityKey  string                       `json:"-"`
	FileNodeID         string                       `json:"file_node_id,omitempty"`
	ObjectKey          string                       `json:"object_key,omitempty"`
	SHA256Hex          string                       `json:"sha256_hex,omitempty"`
}

type directFileStore struct {
	mu      sync.RWMutex
	root    string
	files   map[string]directFile
	expired map[string]struct{}
}

func newDirectFileStore(root string) *directFileStore {
	if strings.TrimSpace(root) == "" {
		root = filepath.Join(os.TempDir(), "openspeak", "direct_files")
	}
	return &directFileStore{
		root:    root,
		files:   make(map[string]directFile),
		expired: make(map[string]struct{}),
	}
}

func (s *Server) handleDirectFiles(w http.ResponseWriter, r *http.Request, authCtx authContext, parts []string) {
	switch {
	case len(parts) == 0 && r.Method == http.MethodPost:
		s.handleDirectFileUpload(w, r, authCtx)
	case len(parts) == 2 && parts[1] == "download" && r.Method == http.MethodGet:
		s.handleDirectFileDownload(w, r, authCtx, parts[0])
	default:
		writeError(w, http.StatusNotFound, "not_found", "route not found")
	}
}

func (s *Server) handleDirectFileUpload(w http.ResponseWriter, r *http.Request, authCtx authContext) {
	r.Body = http.MaxBytesReader(w, r.Body, maxLocalAttachmentFileSize+(1<<20))
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_multipart", "invalid multipart form")
		return
	}
	if r.MultipartForm != nil {
		defer r.MultipartForm.RemoveAll()
	}
	toUserID := strings.TrimSpace(r.FormValue("to_user_id"))
	if toUserID == "" || toUserID == authCtx.User.ID {
		writeError(w, http.StatusBadRequest, "invalid_recipient", "to_user_id must identify another user")
		return
	}
	serverID, ok := s.hub.SharedOnlineServer(authCtx.User.ID, toUserID)
	if !ok {
		writeError(w, http.StatusConflict, "recipient_offline", "recipient offline or not connected to the same server")
		return
	}
	server, err := s.repo.GetServer(r.Context(), serverID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if !requireDirectEncryptionMode(w, r.FormValue("encryption_mode"), server.EncryptionMode) {
		return
	}
	upload, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "missing_file", "file is required")
		return
	}
	_ = upload.Close()
	contentType := header.Header.Get("Content-Type")
	if contentType == "" {
		contentType = files.DetectContentTypeFromName(files.OriginalName(header.Filename))
	}
	permission := store.PermissionDirectSendFile
	if strings.HasPrefix(strings.ToLower(contentType), "image/") {
		permission = store.PermissionDirectSendImage
	}
	if !s.requireServerPermission(w, r, authCtx, serverID, permission) {
		return
	}
	plaintextSize, _ := strconv.ParseInt(strings.TrimSpace(r.FormValue("plaintext_size_bytes")), 10, 64)
	chunkSize, _ := strconv.ParseInt(strings.TrimSpace(r.FormValue("chunk_size")), 10, 64)
	format := strings.TrimSpace(r.FormValue("attachment_format"))
	nonce := strings.TrimSpace(r.FormValue("nonce"))
	if !validateAttachmentEncryption(w, server.EncryptionMode, nonce, header.Size, plaintextSize, format, chunkSize, maxLocalAttachmentFileSize) {
		return
	}
	messageID := strings.TrimSpace(r.FormValue("message_id"))
	senderDeviceID := strings.TrimSpace(r.FormValue("sender_device_id"))
	var envelopes []realtime.DirectKeyEnvelope
	var senderIdentity string
	var recipientDeviceIDs []string
	if server.EncryptionMode == "e2ee" {
		if err := json.Unmarshal([]byte(r.FormValue("envelopes")), &envelopes); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_direct_envelopes", "invalid direct key envelopes")
			return
		}
		senderIdentity, recipientDeviceIDs, ok = s.validateDirectEnvelopes(w, serverID, authCtx.User.ID, toUserID, senderDeviceID, messageID, envelopes)
		if !ok {
			return
		}
	}
	file, err := s.saveDirectFile(serverID, authCtx.User.ID, toUserID, header, r.FormValue("original_name"))
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	file.EncryptionMode = server.EncryptionMode
	file.MessageID = messageID
	file.SenderDeviceID = senderDeviceID
	file.Nonce = nonce
	file.PlaintextSizeBytes = plaintextSize
	file.AttachmentFormat = format
	file.ChunkSize = chunkSize
	file.Envelopes = envelopes
	file.RecipientDeviceIDs = recipientDeviceIDs
	file.SenderIdentityKey = senderIdentity
	s.directFiles.mu.Lock()
	s.directFiles.files[file.ID] = file
	s.directFiles.mu.Unlock()
	kind := "file"
	if strings.HasPrefix(strings.ToLower(file.ContentType), "image/") {
		kind = "image"
	}
	event := directFileMessageEvent(file, kind)
	if !s.hub.SendDirectEvent(event) {
		s.directFiles.remove(file.ID)
		writeError(w, http.StatusConflict, "recipient_offline", "recipient went offline during upload")
		return
	}
	writeJSON(w, http.StatusOK, file)
}

func requireDirectEncryptionMode(w http.ResponseWriter, requested, current string) bool {
	requested = strings.TrimSpace(requested)
	if requested == "" && current != "e2ee" {
		requested = current
	}
	return requireClientEncryptionMode(w, requested, current)
}

func (s *Server) validateDirectEnvelopes(w http.ResponseWriter, serverID, fromUserID, toUserID, senderDeviceID, messageID string, envelopes []realtime.DirectKeyEnvelope) (string, []string, bool) {
	if !realtime.ValidDirectMessageID(messageID) {
		writeError(w, http.StatusBadRequest, "invalid_direct_message_id", "invalid direct message id")
		return "", nil, false
	}
	senderIdentity, recipientDeviceIDs, ok := s.hub.ValidateDirectEnvelopes(serverID, fromUserID, toUserID, senderDeviceID, envelopes)
	if !ok {
		writeError(w, http.StatusConflict, "direct_devices_changed", "direct message devices changed; refresh and retry")
		return "", nil, false
	}
	return senderIdentity, recipientDeviceIDs, true
}

func directFileMessageEvent(file directFile, kind string) realtime.Event {
	messageID := ids.New("dm")
	size := file.SizeBytes
	payload := map[string]any{
		"kind": kind, "file_id": file.ID,
		"original_name": file.OriginalName, "content_type": file.ContentType,
		"from_user_id": file.FromUserID, "to_user_id": file.ToUserID,
		"encryption_mode": file.EncryptionMode,
	}
	if file.EncryptionMode == "e2ee" {
		messageID = file.MessageID
		size = file.PlaintextSizeBytes
		payload["ciphertext_size_bytes"] = file.SizeBytes
		payload["nonce"] = file.Nonce
		payload["attachment_format"] = file.AttachmentFormat
		payload["chunk_size"] = file.ChunkSize
		payload["sender_device_id"] = file.SenderDeviceID
		payload["sender_identity_public_key"] = file.SenderIdentityKey
		payload["envelopes"] = file.Envelopes
		payload["recipient_device_ids"] = file.RecipientDeviceIDs
	}
	payload["id"] = messageID
	payload["size_bytes"] = size
	return realtime.Event{
		Type: "direct.message_created", ServerID: file.ServerID,
		FromUser: file.FromUserID, ToUser: file.ToUserID, Payload: payload,
	}
}

func (s *Server) saveDirectFile(serverID, fromUserID, toUserID string, header *multipart.FileHeader, originalName string) (directFile, error) {
	src, err := header.Open()
	if err != nil {
		return directFile{}, err
	}
	defer src.Close()
	if err := os.MkdirAll(s.directFiles.root, 0o750); err != nil {
		return directFile{}, err
	}
	id := ids.New("dfl")
	path := filepath.Join(s.directFiles.root, id)
	dst, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o640)
	if err != nil {
		return directFile{}, err
	}
	size, copyErr := io.Copy(dst, src)
	closeErr := dst.Close()
	if copyErr != nil || closeErr != nil {
		_ = os.Remove(path)
		return directFile{}, errors.Join(copyErr, closeErr)
	}
	contentType := header.Header.Get("Content-Type")
	name := files.OriginalName(header.Filename)
	if strings.TrimSpace(originalName) != "" {
		name = files.OriginalName(originalName)
	}
	if _, _, err := mime.ParseMediaType(contentType); contentType == "" || err != nil {
		contentType = files.DetectContentTypeFromName(name)
	}
	file := directFile{
		ID: id, ServerID: serverID, FromUserID: fromUserID, ToUserID: toUserID,
		Path: path, OriginalName: name, ContentType: contentType, SizeBytes: size,
	}
	s.directFiles.mu.Lock()
	s.directFiles.files[id] = file
	delete(s.directFiles.expired, id)
	s.directFiles.mu.Unlock()
	return file, nil
}

func (s *Server) handleDirectFileDownload(w http.ResponseWriter, r *http.Request, authCtx authContext, fileID string) {
	file, ok := s.directFiles.get(fileID)
	if !ok {
		if s.directFiles.isExpired(fileID) {
			writeError(w, http.StatusGone, "expired", "file has expired")
			return
		}
		writeError(w, http.StatusNotFound, "not_found", "file not found")
		return
	}
	if authCtx.User.ID != file.FromUserID && authCtx.User.ID != file.ToUserID {
		writeError(w, http.StatusForbidden, "forbidden", "direct file belongs to another conversation")
		return
	}
	if file.FileNodeID != "" {
		node, err := s.repo.GetFileNode(r.Context(), file.ServerID, file.FileNodeID)
		if err != nil {
			writeError(w, http.StatusBadGateway, "file_node_unavailable", "attachment file node is unavailable")
			return
		}
		if !secureEndpoint(node.BaseURL, "https") {
			writeError(w, http.StatusConflict, "insecure_file_node", "external attachment nodes require HTTPS")
			return
		}
		downloadURL, err := externalObjectURL(node, file.ObjectKey, "get", file.OriginalName, file.ContentType, file.SizeBytes, 5*time.Minute)
		if err != nil {
			writeError(w, http.StatusBadGateway, "file_node_unavailable", "attachment file node configuration is invalid")
			return
		}
		http.Redirect(w, r, downloadURL, http.StatusTemporaryRedirect)
		return
	}
	handle, err := os.Open(file.Path)
	if errors.Is(err, os.ErrNotExist) {
		s.directFiles.remove(file.ID)
		writeError(w, http.StatusNotFound, "not_found", "file not found")
		return
	}
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	defer handle.Close()
	w.Header().Set("Content-Type", file.ContentType)
	w.Header().Set("Content-Length", strconv.FormatInt(file.SizeBytes, 10))
	w.Header().Set("Content-Disposition", attachmentContentDisposition(file.OriginalName))
	disableDownloadWriteTimeout(w)
	http.ServeContent(w, r, file.OriginalName, time.Time{}, handle)
}

func (d *directFileStore) get(id string) (directFile, bool) {
	d.mu.RLock()
	defer d.mu.RUnlock()
	file, ok := d.files[id]
	return file, ok
}

func (d *directFileStore) remove(id string) bool {
	d.mu.Lock()
	file, ok := d.files[id]
	if ok {
		delete(d.files, id)
	}
	d.mu.Unlock()
	if ok {
		_ = os.Remove(file.Path)
	}
	return ok
}

func (d *directFileStore) isExpired(id string) bool {
	d.mu.RLock()
	defer d.mu.RUnlock()
	_, ok := d.expired[id]
	return ok
}

func (d *directFileStore) expireBySender(serverID, fromUserID string) []directFile {
	d.mu.Lock()
	expired := make([]directFile, 0)
	for id, file := range d.files {
		if file.ServerID != serverID || file.FromUserID != fromUserID {
			continue
		}
		delete(d.files, id)
		d.expired[id] = struct{}{}
		expired = append(expired, file)
	}
	d.mu.Unlock()
	for _, file := range expired {
		if file.Path != "" {
			_ = os.Remove(file.Path)
		}
	}
	return expired
}

func (s *Server) expireDirectFilesFromSender(serverID, fromUserID string) {
	for _, file := range s.directFiles.expireBySender(serverID, fromUserID) {
		if file.FileNodeID != "" {
			s.queueExternalFileDelete(file)
		}
		s.hub.Publish(realtime.Event{
			Type:     "direct.file_expired",
			ServerID: file.ServerID,
			FromUser: file.FromUserID,
			ToUser:   file.ToUserID,
			Payload: map[string]any{
				"file_id":      file.ID,
				"from_user_id": file.FromUserID,
				"to_user_id":   file.ToUserID,
				"reason":       "sender_offline",
			},
		})
	}
}

func (s *Server) deleteDirectMessageFile(fileID string) {
	file, ok := s.directFiles.get(fileID)
	if !ok {
		return
	}
	s.directFiles.remove(fileID)
	if file.FileNodeID != "" {
		s.queueExternalFileDelete(file)
	}
}

func (s *Server) RunDirectFileCleaner(ctx context.Context) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.retryExternalFileDeletes()
		}
	}
}
