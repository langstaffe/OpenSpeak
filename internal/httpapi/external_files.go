package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"openspeak/internal/auth"
	"openspeak/internal/filenode"
	"openspeak/internal/files"
	"openspeak/internal/ids"
	"openspeak/internal/realtime"
	"openspeak/internal/store"
)

const externalUploadTTL = 60 * time.Minute
const externalStreamDownloadTTL = 6 * time.Hour

const (
	attachmentEncryptionFormatV1   = "openspeak-attachment-v1"
	attachmentEncryptionChunkSize  = int64(64 * 1024)
	attachmentEncryptionHeaderSize = int64(28)
)

type attachmentUploadClaims struct {
	FileID             string                       `json:"file_id"`
	ServerID           string                       `json:"server_id"`
	ChannelID          *string                      `json:"channel_id,omitempty"`
	FromUserID         string                       `json:"from_user_id"`
	ToUserID           string                       `json:"to_user_id,omitempty"`
	Kind               string                       `json:"kind"`
	OriginalName       string                       `json:"original_name"`
	ContentType        string                       `json:"content_type"`
	SizeBytes          int64                        `json:"size_bytes"`
	EncryptionMode     string                       `json:"encryption_mode"`
	EpochID            *string                      `json:"epoch_id,omitempty"`
	Nonce              string                       `json:"nonce,omitempty"`
	PlaintextSizeBytes int64                        `json:"plaintext_size_bytes,omitempty"`
	AttachmentFormat   string                       `json:"attachment_format,omitempty"`
	ChunkSize          int64                        `json:"chunk_size,omitempty"`
	MessageID          string                       `json:"message_id,omitempty"`
	SenderDeviceID     string                       `json:"sender_device_id,omitempty"`
	DirectEnvelopes    []realtime.DirectKeyEnvelope `json:"direct_envelopes,omitempty"`
	RecipientDeviceIDs []string                     `json:"recipient_device_ids,omitempty"`
	SenderIdentityKey  string                       `json:"sender_identity_key,omitempty"`
	FileNodeID         string                       `json:"file_node_id"`
	ObjectKey          string                       `json:"object_key"`
}

func (s *Server) handleAttachmentUploads(w http.ResponseWriter, r *http.Request, authCtx authContext, parts []string) {
	switch {
	case len(parts) == 0 && r.Method == http.MethodPost:
		s.handleAttachmentUploadInit(w, r, authCtx)
	case len(parts) == 1 && parts[0] == "complete" && r.Method == http.MethodPost:
		s.handleAttachmentUploadComplete(w, r, authCtx)
	default:
		writeError(w, http.StatusNotFound, "not_found", "route not found")
	}
}

func (s *Server) handleAttachmentUploadInit(w http.ResponseWriter, r *http.Request, authCtx authContext) {
	var req struct {
		ChannelID          string                       `json:"channel_id"`
		ToUserID           string                       `json:"to_user_id"`
		Kind               string                       `json:"kind"`
		OriginalName       string                       `json:"original_name"`
		ContentType        string                       `json:"content_type"`
		SizeBytes          int64                        `json:"size_bytes"`
		EncryptionMode     string                       `json:"encryption_mode"`
		EpochID            *string                      `json:"epoch_id"`
		Nonce              string                       `json:"nonce"`
		PlaintextSizeBytes int64                        `json:"plaintext_size_bytes"`
		AttachmentFormat   string                       `json:"attachment_format"`
		ChunkSize          int64                        `json:"chunk_size"`
		MessageID          string                       `json:"message_id"`
		SenderDeviceID     string                       `json:"sender_device_id"`
		DirectEnvelopes    []realtime.DirectKeyEnvelope `json:"direct_envelopes"`
		ForceLocal         bool                         `json:"force_local"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	maxBytes := maxExternalAttachmentFileSize
	localMaxBytes := maxLocalAttachmentFileSize
	if req.Kind == "image" {
		maxBytes = maxAttachmentImageSize
		localMaxBytes = maxAttachmentImageSize
	}
	if req.SizeBytes <= 0 || (req.Kind != "image" && req.Kind != "file") {
		writeError(w, http.StatusBadRequest, "invalid_attachment", "kind and size_bytes are invalid")
		return
	}
	name := files.OriginalName(req.OriginalName)
	contentType := strings.TrimSpace(req.ContentType)
	if contentType == "" {
		contentType = files.DetectContentTypeFromName(name)
	}
	claims := attachmentUploadClaims{FromUserID: authCtx.User.ID, Kind: req.Kind, OriginalName: name, ContentType: contentType, SizeBytes: req.SizeBytes, Nonce: req.Nonce}
	var server store.OSServer
	if strings.TrimSpace(req.ChannelID) != "" {
		if !s.requireChannelAccess(w, r, authCtx, req.ChannelID) {
			return
		}
		channel, err := s.repo.GetChannel(r.Context(), req.ChannelID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		permission := store.PermissionChannelMessagesSendFile
		if req.Kind == "image" {
			permission = store.PermissionChannelMessagesSendImage
		}
		if !s.requireServerPermission(w, r, authCtx, channel.ServerID, permission) {
			return
		}
		server, err = s.repo.GetServer(r.Context(), channel.ServerID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		if !requireClientEncryptionMode(w, req.EncryptionMode, server.EncryptionMode) {
			return
		}
		claims.ChannelID = &channel.ID
		claims.ServerID = channel.ServerID
		claims.FileID = ids.New("fil")
		claims.EpochID, claims.Nonce, _ = normalizeChannelEncryption(w, server.EncryptionMode, req.EpochID, req.Nonce)
		if server.EncryptionMode == "e2ee" && claims.EpochID == nil {
			return
		}
		if !validateAttachmentEncryption(w, server.EncryptionMode, claims.Nonce, req.SizeBytes, req.PlaintextSizeBytes, req.AttachmentFormat, req.ChunkSize, maxBytes) {
			return
		}
		claims.PlaintextSizeBytes = req.PlaintextSizeBytes
		claims.AttachmentFormat = req.AttachmentFormat
		claims.ChunkSize = req.ChunkSize
	} else {
		toUserID := strings.TrimSpace(req.ToUserID)
		if toUserID == "" || toUserID == authCtx.User.ID {
			writeError(w, http.StatusBadRequest, "invalid_recipient", "to_user_id must identify another user")
			return
		}
		serverID, ok := s.hub.SharedOnlineServer(authCtx.User.ID, toUserID)
		if !ok {
			writeError(w, http.StatusConflict, "recipient_offline", "recipient offline or not connected to the same server")
			return
		}
		permission := store.PermissionDirectSendFile
		if req.Kind == "image" {
			permission = store.PermissionDirectSendImage
		}
		if !s.requireServerPermission(w, r, authCtx, serverID, permission) {
			return
		}
		var err error
		server, err = s.repo.GetServer(r.Context(), serverID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		if !requireDirectEncryptionMode(w, req.EncryptionMode, server.EncryptionMode) ||
			!validateAttachmentEncryption(w, server.EncryptionMode, req.Nonce, req.SizeBytes, req.PlaintextSizeBytes, req.AttachmentFormat, req.ChunkSize, maxBytes) {
			return
		}
		claims.ServerID = serverID
		claims.ToUserID = toUserID
		claims.FileID = ids.New("dfl")
		claims.PlaintextSizeBytes = req.PlaintextSizeBytes
		claims.AttachmentFormat = req.AttachmentFormat
		claims.ChunkSize = req.ChunkSize
		claims.MessageID = strings.TrimSpace(req.MessageID)
		claims.SenderDeviceID = strings.TrimSpace(req.SenderDeviceID)
		claims.DirectEnvelopes = req.DirectEnvelopes
		if server.EncryptionMode == "e2ee" {
			claims.SenderIdentityKey, claims.RecipientDeviceIDs, ok = s.validateDirectEnvelopes(w, serverID, authCtx.User.ID, toUserID, claims.SenderDeviceID, claims.MessageID, claims.DirectEnvelopes)
			if !ok {
				return
			}
		}
	}
	claims.EncryptionMode = server.EncryptionMode
	localSizeBytes := claims.SizeBytes
	if claims.EncryptionMode == "e2ee" {
		localSizeBytes = claims.PlaintextSizeBytes
	}
	if req.ForceLocal || !server.AttachmentExternalEnabled || server.AttachmentFileNodeID == nil {
		if localSizeBytes > localMaxBytes {
			writeError(w, http.StatusRequestEntityTooLarge, "attachment_too_large", "attachment exceeds local file size limit")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"external": false, "local_max_bytes": localMaxBytes})
		return
	}
	node, err := s.repo.GetFileNode(r.Context(), server.ID, *server.AttachmentFileNodeID)
	if err != nil || !node.Enabled {
		writeError(w, http.StatusBadGateway, "file_node_unavailable", "attachment file node is unavailable")
		return
	}
	if !secureEndpoint(node.BaseURL, "https") {
		writeError(w, http.StatusConflict, "insecure_file_node", "external attachment nodes require HTTPS")
		return
	}
	claims.FileNodeID = node.ID
	claims.ObjectKey = claims.FileID
	uploadURL, err := filenode.SignedURL(node.BaseURL, node.Secret, filenode.Ticket{Operation: "put", ObjectKey: claims.ObjectKey, ExpiresAt: time.Now().Add(externalUploadTTL), MaxBytes: claims.SizeBytes, Name: claims.OriginalName, ContentType: claims.ContentType})
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	token, err := s.createAttachmentCompletionToken(claims)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"external": true, "upload_url": uploadURL, "completion_token": token, "local_max_bytes": localMaxBytes})
}

func (s *Server) handleAttachmentUploadComplete(w http.ResponseWriter, r *http.Request, authCtx authContext) {
	var req struct {
		Token string `json:"completion_token"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	claims, err := s.parseAttachmentCompletionToken(req.Token)
	if err != nil || claims.FromUserID != authCtx.User.ID {
		writeError(w, http.StatusForbidden, "invalid_upload", "invalid or expired completion token")
		return
	}
	if claims.ChannelID != nil {
		if !s.requireChannelAccess(w, r, authCtx, *claims.ChannelID) {
			return
		}
		permission := store.PermissionChannelMessagesSendFile
		if claims.Kind == "image" {
			permission = store.PermissionChannelMessagesSendImage
		}
		if !s.requireServerPermission(w, r, authCtx, claims.ServerID, permission) {
			return
		}
		server, err := s.repo.GetServer(r.Context(), claims.ServerID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		if server.EncryptionMode != claims.EncryptionMode {
			s.queueExternalUploadDelete(claims)
			writeError(w, http.StatusConflict, "encryption_mode_changed", "server encryption mode changed; retry the upload")
			return
		}
	} else {
		serverID, ok := s.hub.SharedOnlineServer(claims.FromUserID, claims.ToUserID)
		if !ok || serverID != claims.ServerID {
			writeError(w, http.StatusConflict, "recipient_offline", "recipient offline or not connected to the same server")
			return
		}
		permission := store.PermissionDirectSendFile
		if claims.Kind == "image" {
			permission = store.PermissionDirectSendImage
		}
		if !s.requireServerPermission(w, r, authCtx, claims.ServerID, permission) {
			return
		}
		server, err := s.repo.GetServer(r.Context(), claims.ServerID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		if server.EncryptionMode != claims.EncryptionMode {
			s.queueExternalUploadDelete(claims)
			writeError(w, http.StatusConflict, "encryption_mode_changed", "server encryption mode changed; retry the upload")
			return
		}
		if claims.EncryptionMode == "e2ee" {
			claims.SenderIdentityKey, claims.RecipientDeviceIDs, ok = s.validateDirectEnvelopes(w, claims.ServerID, claims.FromUserID, claims.ToUserID, claims.SenderDeviceID, claims.MessageID, claims.DirectEnvelopes)
			if !ok {
				s.queueExternalUploadDelete(claims)
				return
			}
		}
	}
	node, err := s.repo.GetFileNode(r.Context(), claims.ServerID, claims.FileNodeID)
	if err != nil {
		writeError(w, http.StatusBadGateway, "file_node_unavailable", "attachment file node is unavailable")
		return
	}
	if !secureEndpoint(node.BaseURL, "https") {
		writeError(w, http.StatusConflict, "insecure_file_node", "external attachment nodes require HTTPS")
		return
	}
	getURL, err := filenode.SignedURL(node.BaseURL, node.Secret, filenode.Ticket{Operation: "get", ObjectKey: claims.ObjectKey, ExpiresAt: time.Now().Add(time.Minute), MaxBytes: claims.SizeBytes, Name: claims.OriginalName, ContentType: claims.ContentType, Commit: true})
	if err != nil {
		writeError(w, http.StatusBadGateway, "file_node_unavailable", "attachment file node configuration is invalid")
		return
	}
	head, err := http.NewRequestWithContext(r.Context(), http.MethodHead, getURL, nil)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	response, err := (&http.Client{Timeout: 10 * time.Second}).Do(head)
	if err != nil || response.StatusCode != http.StatusOK {
		if response != nil {
			response.Body.Close()
		}
		writeError(w, http.StatusBadGateway, "file_node_unavailable", "file node did not confirm the upload")
		return
	}
	response.Body.Close()
	if response.ContentLength != claims.SizeBytes {
		s.queueExternalUploadDelete(claims)
		writeError(w, http.StatusBadRequest, "size_mismatch", "uploaded file size does not match")
		return
	}
	sha := response.Header.Get("X-OpenSpeak-SHA256")
	if sha == "" {
		s.queueExternalUploadDelete(claims)
		writeError(w, http.StatusBadGateway, "file_node_invalid_response", "file node did not return the upload checksum")
		return
	}
	if claims.ChannelID != nil {
		s.completeExternalChannelUpload(w, r, claims, sha)
		return
	}
	s.completeExternalDirectUpload(w, claims, sha)
}

func (s *Server) completeExternalChannelUpload(w http.ResponseWriter, r *http.Request, claims attachmentUploadClaims, sha string) {
	fileKind := "channel_file"
	if claims.Kind == "image" {
		fileKind = "channel_image"
	}
	metadata := attachmentEncryptionMetadata(claims.EncryptionMode, claims.Nonce, claims.PlaintextSizeBytes, claims.AttachmentFormat, claims.ChunkSize)
	file, err := s.repo.StoreFile(r.Context(), store.StoredFile{ID: claims.FileID, ServerID: claims.ServerID, ChannelID: claims.ChannelID, UploaderUserID: claims.FromUserID, Kind: fileKind, OriginalName: claims.OriginalName, ContentType: claims.ContentType, SizeBytes: claims.SizeBytes, SHA256Hex: sha, FileNodeID: &claims.FileNodeID, ObjectKey: claims.ObjectKey, EncryptionMode: claims.EncryptionMode, Metadata: metadata})
	if err != nil {
		s.queueExternalUploadDelete(claims)
		writeResult(w, nil, err)
		return
	}
	msg, err := s.repo.StoreChannelMessage(r.Context(), store.ChannelMessage{ChannelID: *claims.ChannelID, SenderUserID: claims.FromUserID, Kind: claims.Kind, EncryptionMode: claims.EncryptionMode, EpochID: claims.EpochID, Body: file.ID, Nonce: claims.Nonce, Metadata: channelAttachmentMessageMetadata(file, claims.PlaintextSizeBytes, claims.AttachmentFormat, claims.ChunkSize)})
	if err != nil {
		_ = s.repo.DeleteFile(context.Background(), file.ID)
		s.queueExternalUploadDelete(claims)
		if errors.Is(err, store.ErrEncryptionMode) {
			writeError(w, http.StatusConflict, "encryption_mode_changed", "server encryption mode changed; retry the upload")
			return
		}
		if errors.Is(err, store.ErrEpochConflict) {
			writeError(w, http.StatusConflict, "epoch_changed", "channel encryption epoch changed; refresh keys and retry")
			return
		}
	}
	if err == nil {
		s.hub.Publish(realtime.Event{Type: "channel.message_created", ServerID: claims.ServerID, ChannelID: *claims.ChannelID, Payload: map[string]any{"message_id": msg.ID, "kind": claims.Kind}})
	}
	writeResult(w, map[string]any{"file": file, "message": msg}, err)
}

func (s *Server) completeExternalDirectUpload(w http.ResponseWriter, claims attachmentUploadClaims, sha string) {
	file := directFile{
		ID: claims.FileID, ServerID: claims.ServerID, FromUserID: claims.FromUserID, ToUserID: claims.ToUserID,
		OriginalName: claims.OriginalName, ContentType: claims.ContentType, SizeBytes: claims.SizeBytes,
		EncryptionMode: claims.EncryptionMode, MessageID: claims.MessageID, SenderDeviceID: claims.SenderDeviceID,
		Nonce: claims.Nonce, PlaintextSizeBytes: claims.PlaintextSizeBytes, AttachmentFormat: claims.AttachmentFormat,
		ChunkSize: claims.ChunkSize, Envelopes: claims.DirectEnvelopes, RecipientDeviceIDs: claims.RecipientDeviceIDs,
		SenderIdentityKey: claims.SenderIdentityKey, FileNodeID: claims.FileNodeID, ObjectKey: claims.ObjectKey, SHA256Hex: sha,
	}
	s.directFiles.mu.Lock()
	if _, exists := s.directFiles.files[file.ID]; exists {
		s.directFiles.mu.Unlock()
		writeError(w, http.StatusConflict, "upload_completed", "attachment upload was already completed")
		return
	}
	s.directFiles.files[file.ID] = file
	delete(s.directFiles.expired, file.ID)
	s.directFiles.mu.Unlock()
	event := directFileMessageEvent(file, claims.Kind)
	if !s.hub.SendDirectEvent(event) {
		s.directFiles.remove(file.ID)
		s.queueExternalFileDelete(file)
		writeError(w, http.StatusConflict, "recipient_offline", "recipient went offline during upload")
		return
	}
	writeJSON(w, http.StatusOK, file)
}

func (s *Server) createAttachmentCompletionToken(claims attachmentUploadClaims) (string, error) {
	payload, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	token, _, err := auth.CreateToken(s.cfg.JWTSecret, auth.Claims{Subject: "attachment:" + base64.RawURLEncoding.EncodeToString(payload)}, externalUploadTTL)
	return token, err
}

func (s *Server) parseAttachmentCompletionToken(token string) (attachmentUploadClaims, error) {
	claims, err := auth.ParseToken(s.cfg.JWTSecret, token)
	if err != nil || !strings.HasPrefix(claims.Subject, "attachment:") {
		return attachmentUploadClaims{}, errors.New("invalid token")
	}
	payload, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(claims.Subject, "attachment:"))
	if err != nil {
		return attachmentUploadClaims{}, err
	}
	var value attachmentUploadClaims
	err = json.Unmarshal(payload, &value)
	return value, err
}

func externalObjectURL(node store.FileNode, objectKey, operation, name, contentType string, size int64, ttl time.Duration) (string, error) {
	return filenode.SignedURL(node.BaseURL, node.Secret, filenode.Ticket{Operation: operation, ObjectKey: objectKey, ExpiresAt: time.Now().Add(ttl), MaxBytes: size, Name: name, ContentType: contentType})
}

func externalDownloadTTL(r *http.Request) time.Duration {
	if r.URL.Query().Get("stream") == "1" {
		return externalStreamDownloadTTL
	}
	return 5 * time.Minute
}

func (s *Server) queueExternalUploadDelete(claims attachmentUploadClaims) {
	s.queueExternalFileDelete(directFile{
		ID: claims.FileID, ServerID: claims.ServerID, FileNodeID: claims.FileNodeID,
		ObjectKey: claims.ObjectKey, OriginalName: claims.OriginalName,
		ContentType: claims.ContentType, SizeBytes: claims.SizeBytes,
	})
}

func (s *Server) queueExternalFileDelete(file directFile) {
	if file.FileNodeID == "" || file.ObjectKey == "" {
		return
	}
	file = directFile{
		ID: file.ID, ServerID: file.ServerID, FileNodeID: file.FileNodeID,
		ObjectKey: file.ObjectKey, OriginalName: file.OriginalName,
		ContentType: file.ContentType, SizeBytes: file.SizeBytes,
	}
	s.externalDeleteMu.Lock()
	s.externalDeletes[file.ServerID+"/"+file.FileNodeID+"/"+file.ObjectKey] = file
	s.externalDeleteMu.Unlock()
	go s.retryExternalFileDeletes()
}

func (s *Server) retryExternalFileDeletes() {
	s.externalDeleteMu.Lock()
	pending := make(map[string]directFile, len(s.externalDeletes))
	for key, file := range s.externalDeletes {
		pending[key] = file
	}
	s.externalDeleteMu.Unlock()
	for key, file := range pending {
		if err := s.deleteExternalFile(file); err != nil {
			slog.Warn("external attachment delete will be retried", "object_key", file.ObjectKey, "error", err)
			continue
		}
		s.externalDeleteMu.Lock()
		delete(s.externalDeletes, key)
		s.externalDeleteMu.Unlock()
	}
}

func (s *Server) deleteExternalFile(file directFile) error {
	node, err := s.repo.GetFileNode(context.Background(), file.ServerID, file.FileNodeID)
	if err != nil {
		return err
	}
	if !secureEndpoint(node.BaseURL, "https") {
		return errors.New("external attachment nodes require HTTPS")
	}
	deleteURL, err := externalObjectURL(node, file.ObjectKey, "delete", file.OriginalName, file.ContentType, file.SizeBytes, time.Minute)
	if err != nil {
		return err
	}
	request, err := http.NewRequest(http.MethodDelete, deleteURL, nil)
	if err != nil {
		return err
	}
	response, err := (&http.Client{Timeout: 10 * time.Second}).Do(request)
	if err != nil {
		return err
	}
	response.Body.Close()
	if response.StatusCode == http.StatusNotFound || response.StatusCode/100 == 2 {
		return nil
	}
	return fmt.Errorf("file node delete returned HTTP %d", response.StatusCode)
}

func validateAttachmentEncryption(w http.ResponseWriter, mode, nonce string, ciphertextSize, plaintextSize int64, format string, chunkSize, maxPlaintextSize int64) bool {
	if mode != "e2ee" {
		if ciphertextSize > maxPlaintextSize {
			writeError(w, http.StatusRequestEntityTooLarge, "attachment_too_large", "attachment is too large")
			return false
		}
		return true
	}
	if plaintextSize > maxPlaintextSize {
		writeError(w, http.StatusRequestEntityTooLarge, "attachment_too_large", "attachment is too large")
		return false
	}
	nonceBytes, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(nonce))
	if err != nil || len(nonceBytes) != 8 || plaintextSize <= 0 || format != attachmentEncryptionFormatV1 || chunkSize != attachmentEncryptionChunkSize || encryptedAttachmentSize(plaintextSize, chunkSize) != ciphertextSize {
		writeError(w, http.StatusBadRequest, "invalid_e2ee_attachment", "invalid encrypted attachment metadata or size")
		return false
	}
	return true
}

func encryptedAttachmentSize(plaintextSize, chunkSize int64) int64 {
	chunks := (plaintextSize + chunkSize - 1) / chunkSize
	return attachmentEncryptionHeaderSize + plaintextSize + chunks*16
}

func attachmentEncryptionMetadata(mode, nonce string, plaintextSize int64, format string, chunkSize int64) map[string]string {
	metadata := map[string]string{"nonce": nonce}
	if mode == "e2ee" {
		metadata["plaintext_size_bytes"] = strconv.FormatInt(plaintextSize, 10)
		metadata["attachment_format"] = format
		metadata["chunk_size"] = strconv.FormatInt(chunkSize, 10)
	}
	return metadata
}

func channelAttachmentMessageMetadata(file store.StoredFile, plaintextSize int64, format string, chunkSize int64) map[string]string {
	size := file.SizeBytes
	metadata := map[string]string{
		"file_id": file.ID, "original_name": file.OriginalName,
		"content_type": file.ContentType,
		"size_bytes":   strconv.FormatInt(size, 10),
	}
	if file.EncryptionMode == "e2ee" {
		metadata["size_bytes"] = strconv.FormatInt(plaintextSize, 10)
		metadata["ciphertext_size_bytes"] = strconv.FormatInt(file.SizeBytes, 10)
		metadata["attachment_format"] = format
		metadata["chunk_size"] = strconv.FormatInt(chunkSize, 10)
	}
	return metadata
}

func (s *Server) CleanupRetainedFile(ctx context.Context, file store.StoredFile) error {
	if file.FileNodeID != nil && file.ObjectKey != "" {
		if err := s.deleteExternalFile(directFile{
			ID: file.ID, ServerID: file.ServerID, FileNodeID: *file.FileNodeID,
			ObjectKey: file.ObjectKey, OriginalName: file.OriginalName,
			ContentType: file.ContentType, SizeBytes: file.SizeBytes,
		}); err != nil {
			return err
		}
	} else {
		server, err := s.repo.GetServer(ctx, file.ServerID)
		if err != nil {
			return err
		}
		path := filepath.Join(server.FileRoot, filepath.FromSlash(file.RelativePath))
		if !strings.HasPrefix(path, filepath.Clean(server.FileRoot)+string(filepath.Separator)) {
			return errors.New("invalid retained file path")
		}
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return s.repo.DeleteFile(ctx, file.ID)
}
