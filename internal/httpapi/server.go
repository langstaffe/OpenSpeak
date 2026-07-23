package httpapi

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"openspeak/internal/auth"
	"openspeak/internal/config"
	"openspeak/internal/files"
	"openspeak/internal/livekit"
	"openspeak/internal/realtime"
	"openspeak/internal/store"
)

type Repository interface {
	CreateUser(ctx context.Context, displayName string) (store.User, error)
	GetUser(ctx context.Context, userID string) (store.User, error)
	UpdateUserDisplayName(ctx context.Context, userID, displayName string) (store.User, error)
	IncrementUserAvatarVersion(ctx context.Context, userID, avatarHash string) (store.User, error)
	IncrementServerAvatarVersion(ctx context.Context, serverID, avatarHash string) (store.OSServer, error)
	RegisterDevice(ctx context.Context, d store.Device) (store.Device, error)
	TouchDevice(ctx context.Context, deviceID string) error
	CreateServer(ctx context.Context, s store.OSServer) (store.OSServer, error)
	ListServers(ctx context.Context) ([]store.OSServer, error)
	GetServer(ctx context.Context, serverID string) (store.OSServer, error)
	GetServerPasswordHash(ctx context.Context, serverID string) (string, error)
	UpdateServer(ctx context.Context, serverID string, name *string, encryptionMode *string, fileRoot *string, historyRetentionDays *int, serverPasswordHash *string, screenSharePolicy *store.ScreenSharePolicy, defaultChannelID *string, attachmentExternalEnabled *bool, attachmentFileNodeID *string, voiceAudioBitrateKbps *int, screenShareBitrateLimits *store.ScreenShareBitrateLimits) (store.OSServer, error)
	UpdateServerTLS(ctx context.Context, serverID, certificateType, identifier, status, tlsError string, expiresAt *time.Time, encryptionMode *string) (store.OSServer, error)
	SetServerMember(ctx context.Context, serverID, userID, role string, permissions []string) (store.ServerMember, error)
	ListServerMembers(ctx context.Context, serverID string) ([]store.ServerMember, error)
	GetServerMember(ctx context.Context, serverID, userID string) (store.ServerMember, error)
	FindUserByClientInstallation(ctx context.Context, serverID, installationHash string) (store.User, error)
	BindClientInstallation(ctx context.Context, serverID, installationHash, userID, displayName string) error
	TouchClientInstallation(ctx context.Context, serverID, installationHash, userID, displayName string) error
	IsClientInstallationBanned(ctx context.Context, serverID, installationHash string) (store.ServerBan, bool, error)
	IsServerUserBanned(ctx context.Context, serverID, userID string) (store.ServerBan, bool, error)
	ListManagedServerMembers(ctx context.Context, serverID string) ([]store.ManagedServerMember, error)
	CreateServerBan(ctx context.Context, serverID, userID, reason, actorUserID string, expiresAt *time.Time) (store.ServerBan, error)
	RevokeServerBan(ctx context.Context, serverID, userID, actorUserID string) error
	CreateMediaNode(ctx context.Context, node store.MediaNode) (store.MediaNode, error)
	ListMediaNodes(ctx context.Context, serverID string) ([]store.MediaNode, error)
	GetMediaNode(ctx context.Context, serverID, nodeID string) (store.MediaNode, error)
	UpdateMediaNode(ctx context.Context, serverID, nodeID string, patch store.MediaNodePatch) (store.MediaNode, error)
	SelectMediaNode(ctx context.Context, serverID string) (store.MediaNode, error)
	CreateFileNode(ctx context.Context, node store.FileNode) (store.FileNode, error)
	ListFileNodes(ctx context.Context, serverID string) ([]store.FileNode, error)
	GetFileNode(ctx context.Context, serverID, nodeID string) (store.FileNode, error)
	UpdateFileNode(ctx context.Context, serverID, nodeID string, patch store.FileNodePatch) (store.FileNode, error)
	IsServerOwnerOrAdmin(ctx context.Context, serverID, userID string) (bool, error)
	IsServerOwnerOrHasPermission(ctx context.Context, serverID, userID, permission string) (bool, error)
	GetServerRolePermissions(ctx context.Context, serverID string) (store.ServerRolePermissions, error)
	SetServerRolePermissions(ctx context.Context, serverID string, admin, user []string, actorUserID string) (store.ServerRolePermissions, error)
	GetMessageRetractWindowMinutes(ctx context.Context, serverID string) (int, error)
	SetMessageRetractWindowMinutes(ctx context.Context, serverID string, minutes int) error
	EffectiveServerPermissions(ctx context.Context, serverID, userID string) ([]string, error)
	IsServerMember(ctx context.Context, serverID, userID string) (bool, error)
	IsChannelServerOwnerOrAdmin(ctx context.Context, channelID, userID string) (bool, error)
	IsChannelServerOwnerOrHasPermission(ctx context.Context, channelID, userID, permission string) (bool, error)
	IsDeviceOwnerOrAdmin(ctx context.Context, deviceID, userID string) (bool, error)
	GetDevice(ctx context.Context, deviceID string) (store.Device, error)
	IsChannelMemberOrOwnerOrAdmin(ctx context.Context, channelID, userID string) (bool, error)
	CreateChannel(ctx context.Context, c store.Channel) (store.Channel, error)
	GetChannel(ctx context.Context, channelID string) (store.Channel, error)
	UpdateChannel(ctx context.Context, channelID string, name *string, sortOrder *int) (store.Channel, error)
	DeleteChannel(ctx context.Context, channelID string) error
	ListChannels(ctx context.Context, serverID string) ([]store.Channel, error)
	AddChannelMember(ctx context.Context, channelID, userID, role string) error
	ListChannelMembers(ctx context.Context, channelID string) ([]store.ChannelMember, error)
	LeaveChannel(ctx context.Context, channelID, userID string) error
	CreateEpoch(ctx context.Context, channelID, reason string) (store.ChannelEpoch, error)
	RotateServerChannelEpochs(ctx context.Context, serverID, reason string) ([]store.ChannelEpoch, error)
	GetLatestEpoch(ctx context.Context, channelID string) (store.ChannelEpoch, error)
	ListChannelDevices(ctx context.Context, channelID, epochID string, media bool) ([]store.ChannelDevice, error)
	StoreEnvelopeBatch(ctx context.Context, channelID, epochID, senderDeviceID, senderUserID string, envelopes []store.KeyEnvelope, media bool) ([]store.KeyEnvelope, error)
	ListEnvelopes(ctx context.Context, recipientDeviceID string, channelID *string, media bool) ([]store.KeyEnvelope, error)
	StoreChannelMessage(ctx context.Context, m store.ChannelMessage) (store.ChannelMessage, error)
	GetChannelMessage(ctx context.Context, messageID string) (store.ChannelMessage, error)
	DeleteChannelMessage(ctx context.Context, messageID, removalKind string) error
	ListChannelMessages(ctx context.Context, channelID string, limit int) ([]store.ChannelMessage, error)
	StoreFile(ctx context.Context, f store.StoredFile) (store.StoredFile, error)
	GetFile(ctx context.Context, fileID string) (store.StoredFile, error)
	DeleteFile(ctx context.Context, fileID string) error
	CreateAuditLog(ctx context.Context, entry store.AuditLog) (store.AuditLog, error)
	ListAuditLogs(ctx context.Context, serverID string, limit int) ([]store.AuditLog, error)
	CreateOwnerSecurity(ctx context.Context, serverID, ownerUserID, claimTokenHash string, claimExpiresAt time.Time) (store.OwnerSecurity, error)
	GetOwnerSecurity(ctx context.Context, serverID string) (store.OwnerSecurity, error)
	FindOwnerSecurityByUser(ctx context.Context, userID string) (store.OwnerSecurity, error)
	ListOwnerSecurities(ctx context.Context) ([]store.OwnerSecurity, error)
	ClaimOwner(ctx context.Context, serverID, tokenHash string, device store.OwnerDevice) (store.OwnerSecurity, store.OwnerDevice, error)
	GetOwnerDevice(ctx context.Context, serverID, deviceID string) (store.OwnerDevice, error)
	ListOwnerDevices(ctx context.Context, serverID string) ([]store.OwnerDevice, error)
	ValidateOwnerSession(ctx context.Context, serverID, userID, deviceID string, authGeneration, sessionGeneration int64) (store.OwnerDevice, error)
	CreateOwnerPairingToken(ctx context.Context, serverID, tokenHash, creatorDeviceID string, expiresAt time.Time) error
	ConsumeOwnerPairingToken(ctx context.Context, serverID, tokenHash string, device store.OwnerDevice) (store.OwnerSecurity, store.OwnerDevice, error)
	KickOwnerDevice(ctx context.Context, serverID, deviceID string) (store.OwnerDevice, error)
	RevokeOwnerDevice(ctx context.Context, serverID, deviceID string) error
	GetWebSettings(ctx context.Context) (store.WebSettings, error)
	UpdateWebSettings(ctx context.Context, enabled, customPathEnabled bool, path string) (store.WebSettings, error)
}

func (s *Server) RunOwnerCredentialMonitor(ctx context.Context) {
	known := map[string]int64{}
	poll := func() {
		items, err := s.repo.ListOwnerSecurities(ctx)
		if err != nil {
			if ctx.Err() == nil {
				slog.Error("owner credential monitor failed", "error", err)
			}
			return
		}
		for _, item := range items {
			previous, existed := known[item.ServerID]
			if (!existed && !item.Claimed) || (existed && previous != item.AuthGeneration) {
				s.hub.DisconnectOwnerUser(item.ServerID, item.OwnerUserID, "owner.credentials_revoked")
			}
			known[item.ServerID] = item.AuthGeneration
		}
	}
	poll()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			poll()
		}
	}
}

type authContext struct {
	User   store.User
	Claims auth.Claims
}

type Server struct {
	cfg              config.Config
	repo             Repository
	hub              *realtime.Hub
	directFiles      *directFileStore
	linkPreviews     *linkPreviewCache
	ownerChallenges  *ownerChallengeStore
	tlsApplyMu       sync.Mutex
	tlsPendingMu     sync.Mutex
	tlsPending       map[string]pendingTLSApply
	downgradePending map[string]pendingEncryptionDowngrade
	tlsRequired      atomic.Bool
	tlsSecureURL     atomic.Value
	tlsPlainURL      atomic.Value
	tlsProbeToken    atomic.Value
	externalDeleteMu sync.Mutex
	externalDeletes  map[string]directFile
	// ponytail: media key slot coordination is intentionally process-local. A
	// backend restart advertises slot 0 again, and reconnecting clients rebuild
	// their LiveKit voice session instead of adding persistent transition state.
	mediaKeyMu      sync.Mutex
	mediaKeys       map[string]*mediaKeyTransition
	mediaKeyClients map[string]bool
	upgrader        websocket.Upgrader
}

type mediaKeyTransition struct {
	ServerID   string
	ChannelID  string
	EpochID    string
	KeyIndex   int
	ReadyUsers map[string]bool
	Activated  bool
}

type ServerState struct {
	ServerID                    string                  `json:"server_id"`
	Channels                    []store.Channel         `json:"channels"`
	OnlineUsers                 []realtime.UserPresence `json:"online_users"`
	VoiceStates                 []realtime.VoiceState   `json:"voice_states"`
	CurrentUser                 CurrentUserState        `json:"current_user"`
	MessageRetractWindowMinutes int                     `json:"message_retract_window_minutes"`
}

type CurrentUserState struct {
	UserID            string   `json:"user_id"`
	Role              string   `json:"role"`
	Permissions       []string `json:"permissions"`
	CurrentChannelID  *string  `json:"current_channel_id,omitempty"`
	DefaultChannelID  *string  `json:"default_channel_id,omitempty"`
	SelectedChannelID *string  `json:"selected_channel_id,omitempty"`
}

func NewServer(cfg config.Config, repo Repository, hub *realtime.Hub) *Server {
	server := &Server{
		cfg:              cfg,
		repo:             repo,
		hub:              hub,
		directFiles:      newDirectFileStore(cfg.DirectFileRoot),
		linkPreviews:     newLinkPreviewCache(24 * time.Hour),
		ownerChallenges:  newOwnerChallengeStore(),
		externalDeletes:  make(map[string]directFile),
		mediaKeys:        make(map[string]*mediaKeyTransition),
		mediaKeyClients:  make(map[string]bool),
		tlsPending:       make(map[string]pendingTLSApply),
		downgradePending: make(map[string]pendingEncryptionDowngrade),
		upgrader: websocket.Upgrader{
			ReadBufferSize:  4096,
			WriteBufferSize: 4096,
			CheckOrigin: func(r *http.Request) bool {
				return true
			},
		},
	}
	server.tlsSecureURL.Store("")
	server.tlsPlainURL.Store("")
	server.tlsProbeToken.Store("")
	hub.SetUserOfflineHandler(server.expireDirectFilesFromSender)
	hub.SetDirectMessageDeletedHandler(server.deleteDirectMessageFile)
	hub.SetPermissionAuthorizer(func(serverID, userID, permission string) bool {
		ok, err := repo.IsServerOwnerOrHasPermission(context.Background(), serverID, userID, permission)
		return err == nil && ok
	})
	hub.SetEncryptionModeLookup(func(serverID string) (string, bool) {
		server, err := repo.GetServer(context.Background(), serverID)
		return server.EncryptionMode, err == nil
	})
	if servers, err := repo.ListServers(context.Background()); err == nil {
		for _, item := range servers {
			if item.TLSStatus == "active" {
				server.tlsRequired.Store(true)
				server.tlsSecureURL.Store(secureServerURL(item.TLSIdentifier, cfg.TLS.SecurePublicPort))
				server.tlsPlainURL.Store("")
				break
			}
			if item.TLSStatus == "discovery" && item.TLSIdentifier != "" {
				server.tlsSecureURL.Store(secureServerURL(item.TLSIdentifier, cfg.TLS.SecurePublicPort))
				server.tlsPlainURL.Store(plainServerURL(item.TLSIdentifier, cfg.TLS.PlainPublicPort))
			}
		}
	}
	return server
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	path := r.URL.Path
	defer func() {
		slog.Info("http request",
			"method", r.Method,
			"path", path,
			"duration_ms", time.Since(start).Milliseconds(),
			"remote_addr", r.RemoteAddr,
		)
	}()

	w.Header().Set("X-Content-Type-Options", "nosniff")
	plainURL, _ := s.tlsPlainURL.Load().(string)
	probeToken, _ := s.tlsProbeToken.Load().(string)
	validTLSProbe := path == "/ws" && probeToken != "" && subtle.ConstantTimeCompare([]byte(r.URL.Query().Get("tls_probe")), []byte(probeToken)) == 1
	tlsConfirmation := requestIsSecure(r) && strings.HasSuffix(path, "/tls/confirm")
	if !s.tlsRequired.Load() && plainURL != "" && requestIsSecure(r) && canonicalTLSHost(r.Host, s.activeTLSURL()) && path != "/api/health" && !validTLSProbe && !tlsConfirmation {
		w.Header().Set("Location", plainURL)
		writeJSON(w, http.StatusUpgradeRequired, map[string]string{
			"error": "http_required", "message_key": "http_required",
			"message": "this server now uses its plaintext HTTP/WS address", "plain_url": plainURL,
		})
		return
	}
	if s.tlsRequired.Load() && path != "/api/health" {
		secureURL := s.activeTLSURL()
		confirmation := tlsConfirmation || path == "/api/v1/encryption/downgrade/confirm"
		if !confirmation && (!requestIsSecure(r) || !canonicalTLSHost(r.Host, secureURL)) {
			if secureURL != "" {
				w.Header().Set("Location", secureURL)
			}
			writeJSON(w, http.StatusUpgradeRequired, map[string]string{
				"error": "https_required", "message_key": "https_required",
				"message": "this server requires its canonical HTTPS/WSS address", "secure_url": secureURL,
			})
			return
		}
	}

	switch {
	case r.Method == http.MethodGet && path == "/api/health":
		result := map[string]any{"ok": true, "time": time.Now().UTC()}
		if s.tlsRequired.Load() {
			result["secure_url"] = s.activeTLSURL()
		} else if plainURL != "" && requestIsSecure(r) {
			result["plain_url"] = plainURL
		}
		writeJSON(w, http.StatusOK, result)
	case path == "/ws":
		s.handleWebSocket(w, r)
	case strings.HasPrefix(path, "/api/v1/"):
		s.handleAPI(w, r)
	default:
		if !s.serveWeb(w, r) {
			w.WriteHeader(http.StatusNotFound)
		}
	}
}

func requestIsSecure(r *http.Request) bool {
	if r.TLS != nil {
		return true
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	return err == nil && net.ParseIP(host).IsLoopback() && strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
}

func (s *Server) handleAPI(w http.ResponseWriter, r *http.Request) {
	parts := splitPath(strings.TrimPrefix(r.URL.Path, "/api/v1/"))
	if len(parts) == 0 {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}

	switch parts[0] {
	case "encryption":
		if len(parts) == 3 && parts[1] == "downgrade" && parts[2] == "confirm" && r.Method == http.MethodPost {
			s.handleEncryptionDowngradeConfirm(w, r)
			return
		}
		writeError(w, http.StatusNotFound, "not_found", "route not found")
	case "auth":
		s.handleAuth(w, r, parts[1:])
	case "users":
		if len(parts) == 3 && parts[2] == "avatar" && r.Method == http.MethodGet {
			s.handleUserAvatar(w, r, parts[1])
			return
		}
		ctx, ok := s.requireAuth(w, r)
		if ok {
			s.handleUsers(w, r, ctx, parts[1:])
		}
	case "servers":
		if len(parts) == 3 && parts[2] == "avatar" && r.Method == http.MethodGet {
			s.handleServerAvatar(w, r, parts[1])
			return
		}
		ctx, ok := s.requireAuth(w, r)
		if ok {
			s.handleServers(w, r, ctx, parts[1:])
		}
	case "channels":
		ctx, ok := s.requireAuth(w, r)
		if ok {
			s.handleChannels(w, r, ctx, parts[1:])
		}
	case "e2ee":
		ctx, ok := s.requireAuth(w, r)
		if ok {
			s.handleE2EE(w, r, ctx, parts[1:])
		}
	case "files":
		ctx, ok := s.requireAuth(w, r)
		if ok {
			s.handleFiles(w, r, ctx, parts[1:])
		}
	case "direct-files":
		ctx, ok := s.requireAuth(w, r)
		if ok {
			s.handleDirectFiles(w, r, ctx, parts[1:])
		}
	case "attachment-uploads":
		ctx, ok := s.requireAuth(w, r)
		if ok {
			s.handleAttachmentUploads(w, r, ctx, parts[1:])
		}
	case "link-preview":
		ctx, ok := s.requireAuth(w, r)
		if ok {
			s.handleLinkPreview(w, r, ctx, parts[1:])
		}
	default:
		writeError(w, http.StatusNotFound, "not_found", "route not found")
	}
}

func (s *Server) handleAuth(w http.ResponseWriter, r *http.Request, parts []string) {
	if len(parts) != 1 || r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}
	switch parts[0] {
	case "login":
		var req struct {
			DisplayName          string `json:"display_name"`
			Password             string `json:"password"`
			ClientInstallationID string `json:"client_installation_id"`
			ClientType           string `json:"client_type"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		displayName := strings.TrimSpace(req.DisplayName)
		if displayName == "" {
			writeError(w, http.StatusBadRequest, "invalid_display_name", "display_name is required")
			return
		}
		servers, err := s.repo.ListServers(r.Context())
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		if len(servers) == 0 {
			writeError(w, http.StatusConflict, "server_not_initialized", "no OpenSpeak server exists")
			return
		}
		server := servers[0]
		clientType := strings.ToLower(strings.TrimSpace(req.ClientType))
		if clientType != "" && clientType != "web" {
			writeError(w, http.StatusBadRequest, "invalid_client_type", "client_type must be web when provided")
			return
		}
		var webGeneration int64
		if clientType == "web" {
			settings, err := s.repo.GetWebSettings(r.Context())
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			if !settings.Enabled {
				writeError(w, http.StatusForbidden, "web_disabled", "网页端未启用")
				return
			}
			webGeneration = settings.Generation
		}
		if server.PasswordProtected {
			passwordHash, err := s.repo.GetServerPasswordHash(r.Context(), server.ID)
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			if !auth.CheckPassword(passwordHash, req.Password) {
				writeError(w, http.StatusUnauthorized, "invalid_server_password", "invalid server password")
				return
			}
		}
		installationID := strings.ToLower(strings.TrimSpace(req.ClientInstallationID))
		var user store.User
		if installationID == "" {
			// Compatibility for older clients. Legacy sessions do not receive a
			// stable member identity and cannot be installation-banned.
			user, err = s.repo.CreateUser(r.Context(), displayName)
			if err == nil {
				_, err = s.repo.SetServerMember(r.Context(), server.ID, user.ID, store.RoleUser, nil)
			}
		} else {
			if !validClientInstallationID(installationID) {
				writeError(w, http.StatusBadRequest, "invalid_client_installation_id", "client_installation_id must be a UUID")
				return
			}
			installationHash := auth.SecretHash(server.ID + ":" + installationID)
			if ban, banned, banErr := s.repo.IsClientInstallationBanned(r.Context(), server.ID, installationHash); banErr != nil {
				writeResult(w, nil, banErr)
				return
			} else if banned {
				message := "你已被此服务器封禁"
				if strings.TrimSpace(ban.Reason) != "" {
					message += "：" + strings.TrimSpace(ban.Reason)
				}
				if ban.ExpiresAt != nil {
					message += "（到期时间 " + ban.ExpiresAt.Local().Format("2006-01-02 15:04") + "）"
				}
				writeError(w, http.StatusForbidden, "server_banned", message)
				return
			}
			user, err = s.repo.FindUserByClientInstallation(r.Context(), server.ID, installationHash)
			if errors.Is(err, store.ErrNotFound) {
				user, err = s.repo.CreateUser(r.Context(), displayName)
				if err == nil {
					_, err = s.repo.SetServerMember(r.Context(), server.ID, user.ID, store.RoleUser, nil)
				}
				if err == nil {
					err = s.repo.BindClientInstallation(r.Context(), server.ID, installationHash, user.ID, displayName)
				}
			} else if err == nil {
				if user.DisplayName != displayName {
					user, err = s.repo.UpdateUserDisplayName(r.Context(), user.ID, displayName)
					if err == nil {
						s.hub.UpdateUserDisplayName(user.ID, user.DisplayName)
					}
				}
				if err == nil {
					err = s.repo.TouchClientInstallation(r.Context(), server.ID, installationHash, user.ID, displayName)
				}
			}
		}
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		s.writeAuthToken(w, user, clientType, webGeneration)
	default:
		writeError(w, http.StatusNotFound, "not_found", "route not found")
	}
}

func (s *Server) writeAuthToken(w http.ResponseWriter, user store.User, clientType string, webGeneration int64) {
	token, expiresAt, err := auth.CreateToken(s.cfg.JWTSecret, auth.Claims{
		Subject:       user.ID,
		DisplayName:   user.DisplayName,
		ClientType:    clientType,
		WebGeneration: webGeneration,
	}, s.cfg.JWTTTL)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"token":      token,
		"expires_at": expiresAt,
		"user":       user,
	})
}

func (s *Server) handleUsers(w http.ResponseWriter, r *http.Request, authCtx authContext, parts []string) {
	if len(parts) == 2 && parts[0] == "me" && parts[1] == "avatar" && r.Method == http.MethodPut {
		s.handleAvatarUpload(w, r, authCtx)
		return
	}
	if len(parts) == 1 && parts[0] == "me" && r.Method == http.MethodPatch {
		var req struct {
			DisplayName string `json:"display_name"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		displayName := strings.TrimSpace(req.DisplayName)
		if displayName == "" {
			writeError(w, http.StatusBadRequest, "invalid_display_name", "display_name is required")
			return
		}
		user, err := s.repo.UpdateUserDisplayName(r.Context(), authCtx.User.ID, displayName)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		s.hub.UpdateUserDisplayName(user.ID, user.DisplayName)
		writeJSON(w, http.StatusOK, user)
		return
	}

	if len(parts) == 0 && r.Method == http.MethodPost {
		var req struct {
			DisplayName string `json:"display_name"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		if strings.TrimSpace(req.DisplayName) == "" {
			writeError(w, http.StatusBadRequest, "invalid_display_name", "display_name is required")
			return
		}
		user, err := s.repo.CreateUser(r.Context(), req.DisplayName)
		writeResult(w, user, err)
		return
	}

	if len(parts) == 2 && parts[1] == "devices" && r.Method == http.MethodPost {
		if parts[0] != authCtx.User.ID {
			writeError(w, http.StatusForbidden, "forbidden", "cannot register a device for another user")
			return
		}
		var req struct {
			DeviceID          string `json:"device_id"`
			Label             string `json:"label"`
			IdentityPublicKey string `json:"identity_public_key"`
			EnvelopePublicKey string `json:"envelope_public_key"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		req.DeviceID = strings.TrimSpace(req.DeviceID)
		req.IdentityPublicKey = strings.TrimSpace(req.IdentityPublicKey)
		req.EnvelopePublicKey = strings.TrimSpace(req.EnvelopePublicKey)
		if req.DeviceID != "" || req.IdentityPublicKey != "" || req.EnvelopePublicKey != "" {
			if !validE2EEDeviceID(req.DeviceID) ||
				!store.ValidE2EEDeviceKeys(req.IdentityPublicKey, req.EnvelopePublicKey) {
				writeError(w, http.StatusBadRequest, "invalid_device_key", "device_id and 32-byte Ed25519/X25519 public keys are required")
				return
			}
		}
		device, err := s.repo.RegisterDevice(r.Context(), store.Device{
			ID:                req.DeviceID,
			UserID:            parts[0],
			Label:             req.Label,
			IdentityPublicKey: req.IdentityPublicKey,
			EnvelopePublicKey: req.EnvelopePublicKey,
		})
		if errors.Is(err, store.ErrDeviceConflict) {
			writeError(w, http.StatusConflict, "device_conflict", "device belongs to another user")
			return
		}
		writeResult(w, device, err)
		return
	}

	writeError(w, http.StatusNotFound, "not_found", "route not found")
}

func (s *Server) handleServers(w http.ResponseWriter, r *http.Request, authCtx authContext, parts []string) {
	if len(parts) == 2 && parts[1] == "avatar" && r.Method == http.MethodPut {
		if !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionServerProfileUpdate) {
			return
		}
		s.handleServerAvatarUpload(w, r, parts[0])
		return
	}
	if len(parts) == 0 {
		switch r.Method {
		case http.MethodGet:
			servers, err := s.repo.ListServers(r.Context())
			writeResult(w, servers, err)
		case http.MethodPost:
			existingServers, err := s.repo.ListServers(r.Context())
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			if len(existingServers) != 0 {
				writeError(w, http.StatusConflict, "server_exists", "this OpenSpeak installation already has a server")
				return
			}
			var req struct {
				Name                 string `json:"name"`
				EncryptionMode       string `json:"encryption_mode"`
				FileRoot             string `json:"file_root"`
				HistoryRetentionDays *int   `json:"history_retention_days"`
			}
			if !decodeJSON(w, r, &req) {
				return
			}
			if req.Name == "" {
				writeError(w, http.StatusBadRequest, "invalid_name", "name is required")
				return
			}
			retention := s.cfg.DefaultHistoryRetentionDays
			if req.HistoryRetentionDays != nil {
				retention = *req.HistoryRetentionDays
			}
			mode := req.EncryptionMode
			if mode == "" {
				mode = s.cfg.DefaultEncryptionMode
			}
			mode, ok := config.NormalizeEncryptionMode(mode)
			if !ok {
				writeError(w, http.StatusBadRequest, "invalid_encryption_mode", "encryption_mode must be none, transport, or e2ee")
				return
			}
			if mode != "none" {
				writeError(w, http.StatusConflict, "tls_required", "创建服务器后请通过证书配置启用传输层加密")
				return
			}
			fileRoot := req.FileRoot
			if fileRoot == "" {
				fileRoot = s.cfg.FileRoot
			}
			server, err := s.repo.CreateServer(r.Context(), store.OSServer{
				Name:                 req.Name,
				EncryptionMode:       mode,
				FileRoot:             fileRoot,
				HistoryRetentionDays: retention,
			})
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			if _, err := s.repo.SetServerMember(r.Context(), server.ID, authCtx.User.ID, store.RoleOwner, store.AllPermissions()); err != nil {
				writeResult(w, nil, err)
				return
			}
			claimKey, err := auth.RandomToken(32)
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			expiresAt := time.Now().UTC().Add(24 * time.Hour)
			if _, err := s.repo.CreateOwnerSecurity(r.Context(), server.ID, authCtx.User.ID, auth.SecretHash(claimKey), expiresAt); err != nil {
				writeResult(w, nil, err)
				return
			}
			writeJSON(w, http.StatusOK, struct {
				store.OSServer
				OwnerClaimKey       string    `json:"owner_claim_key"`
				OwnerClaimExpiresAt time.Time `json:"owner_claim_expires_at"`
			}{OSServer: server, OwnerClaimKey: claimKey, OwnerClaimExpiresAt: expiresAt})
		default:
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		}
		return
	}

	if len(parts) >= 2 && parts[1] == "owner" {
		if authCtx.Claims.ClientType == "web" {
			writeError(w, http.StatusForbidden, "owner_unavailable_on_web", "网页端不提供服务器所有者权限")
			return
		}
		s.handleOwner(w, r, authCtx, parts[0], parts[2:])
		return
	}

	if len(parts) == 2 && parts[1] == "web-settings" {
		s.handleWebSettings(w, r, authCtx, parts[0])
		return
	}

	if len(parts) == 2 && parts[1] == "tls" && r.Method == http.MethodPost {
		s.handleTLSApply(w, r, authCtx, parts[0])
		return
	}
	if len(parts) == 3 && parts[1] == "tls" && parts[2] == "public-ip" && r.Method == http.MethodGet {
		s.handleTLSPublicIP(w, r, authCtx, parts[0])
		return
	}
	if len(parts) == 3 && parts[1] == "tls" && parts[2] == "confirm" && r.Method == http.MethodPost {
		s.handleTLSConfirm(w, r, authCtx, parts[0])
		return
	}
	if len(parts) == 3 && parts[1] == "encryption" && parts[2] == "downgrade" && r.Method == http.MethodPost {
		s.handleEncryptionDowngradeApply(w, r, authCtx, parts[0])
		return
	}

	if len(parts) == 2 && parts[1] == "permissions" {
		if !s.requireNotBanned(w, r, authCtx, parts[0]) || !s.requireOwnerDevice(w, authCtx, parts[0]) {
			return
		}
		switch r.Method {
		case http.MethodGet:
			settings, err := s.repo.GetServerRolePermissions(r.Context(), parts[0])
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			retractMinutes, err := s.repo.GetMessageRetractWindowMinutes(r.Context(), parts[0])
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{
				"server_id": parts[0], "admin": settings.Admin, "user": settings.User,
				"available": store.DelegablePermissions(), "updated_by": settings.UpdatedBy,
				"updated_at": settings.UpdatedAt, "message_retract_window_minutes": retractMinutes,
			})
		case http.MethodPut:
			previous, err := s.repo.GetServerRolePermissions(r.Context(), parts[0])
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			var req struct {
				Admin                       []string `json:"admin"`
				User                        []string `json:"user"`
				MessageRetractWindowMinutes *int     `json:"message_retract_window_minutes"`
			}
			if !decodeJSON(w, r, &req) {
				return
			}
			admin, err := normalizePermissions(req.Admin)
			if err != nil {
				writeError(w, http.StatusBadRequest, "invalid_permissions", err.Error())
				return
			}
			user, err := normalizePermissions(req.User)
			if err != nil {
				writeError(w, http.StatusBadRequest, "invalid_permissions", err.Error())
				return
			}
			if err := validateScreenShareQualityPermissions("admin", admin); err != nil {
				writeError(w, http.StatusBadRequest, "invalid_permissions", err.Error())
				return
			}
			if err := validateScreenShareQualityPermissions("user", user); err != nil {
				writeError(w, http.StatusBadRequest, "invalid_permissions", err.Error())
				return
			}
			if req.MessageRetractWindowMinutes != nil && (*req.MessageRetractWindowMinutes < 1 || *req.MessageRetractWindowMinutes > 10080) {
				writeError(w, http.StatusBadRequest, "invalid_message_retract_window", "message_retract_window_minutes must be between 1 and 10080")
				return
			}
			settings, err := s.repo.SetServerRolePermissions(r.Context(), parts[0], admin, user, authCtx.User.ID)
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			if permissionEnabled(previous.Admin, store.PermissionChannelMessagesView) != permissionEnabled(admin, store.PermissionChannelMessagesView) ||
				permissionEnabled(previous.User, store.PermissionChannelMessagesView) != permissionEnabled(user, store.PermissionChannelMessagesView) ||
				permissionEnabled(previous.Admin, store.PermissionVoiceJoin) != permissionEnabled(admin, store.PermissionVoiceJoin) ||
				permissionEnabled(previous.User, store.PermissionVoiceJoin) != permissionEnabled(user, store.PermissionVoiceJoin) {
				if err := s.rotateServerChannelEpochs(r.Context(), parts[0], "e2ee_access_permissions_changed"); err != nil {
					writeResult(w, nil, err)
					return
				}
			}
			if req.MessageRetractWindowMinutes != nil {
				if err := s.repo.SetMessageRetractWindowMinutes(r.Context(), parts[0], *req.MessageRetractWindowMinutes); err != nil {
					writeResult(w, nil, err)
					return
				}
			}
			retractMinutes, err := s.repo.GetMessageRetractWindowMinutes(r.Context(), parts[0])
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			s.audit(r.Context(), parts[0], authCtx.User.ID, "permissions.updated", "", nil)
			s.enforceScreenSharePermissions(r.Context(), parts[0])
			s.hub.Publish(realtime.Event{Type: "server.permissions_updated", ServerID: parts[0]})
			writeJSON(w, http.StatusOK, map[string]any{
				"server_id": parts[0], "admin": settings.Admin, "user": settings.User,
				"available": store.DelegablePermissions(), "updated_by": settings.UpdatedBy,
				"updated_at": settings.UpdatedAt, "message_retract_window_minutes": retractMinutes,
			})
		default:
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		}
		return
	}

	if len(parts) == 2 && parts[1] == "audit-logs" && r.Method == http.MethodGet {
		if !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionAuditView) {
			return
		}
		entries, err := s.repo.ListAuditLogs(r.Context(), parts[0], 100)
		writeResult(w, entries, err)
		return
	}

	if len(parts) == 2 && parts[1] == "settings" && r.Method == http.MethodGet {
		if !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionServerSettingsUpdate) {
			return
		}
		server, err := s.repo.GetServer(r.Context(), parts[0])
		if err == nil && server.TLSStatus == "active" {
			server.TLSRenewalAt = caddyRenewalAt(s.cfg.TLS.CaddyConfigPath, server.TLSIdentifier)
		}
		writeResult(w, server, err)
		return
	}

	if len(parts) == 2 && parts[1] == "members" {
		if !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionMemberView) {
			return
		}
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
			return
		}
		members, err := s.repo.ListServerMembers(r.Context(), parts[0])
		writeResult(w, members, err)
		return
	}

	if len(parts) == 3 && parts[1] == "members" && parts[2] == "manage" && r.Method == http.MethodGet {
		if !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionMemberView) {
			return
		}
		members, err := s.repo.ListManagedServerMembers(r.Context(), parts[0])
		if err == nil {
			for index := range members {
				members[index].Online = s.hub.UserOnlineInServer(parts[0], members[index].UserID)
			}
		}
		writeResult(w, members, err)
		return
	}

	if len(parts) == 4 && parts[1] == "members" {
		target, err := s.repo.GetServerMember(r.Context(), parts[0], parts[2])
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		if target.Role == store.RoleOwner {
			writeError(w, http.StatusBadRequest, "owner_protected", "owner cannot be kicked, banned, or changed here")
			return
		}
		switch parts[3] {
		case "kick":
			if !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionMemberKick) {
				return
			}
			if r.Method != http.MethodPost {
				writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
				return
			}
			s.hub.DisconnectUser(parts[0], parts[2], "member.kicked")
			s.audit(r.Context(), parts[0], authCtx.User.ID, "member.kicked", parts[2], nil)
			writeJSON(w, http.StatusOK, map[string]any{"kicked": true})
			return
		case "ban":
			switch r.Method {
			case http.MethodPost:
				if !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionMemberBan) {
					return
				}
				var req struct {
					Reason          string `json:"reason"`
					DurationSeconds int64  `json:"duration_seconds"`
				}
				if !decodeJSON(w, r, &req) {
					return
				}
				reason := strings.TrimSpace(req.Reason)
				if len([]rune(reason)) > 500 {
					writeError(w, http.StatusBadRequest, "invalid_reason", "ban reason is too long")
					return
				}
				if req.DurationSeconds < 0 || req.DurationSeconds > int64((10*365*24*time.Hour)/time.Second) {
					writeError(w, http.StatusBadRequest, "invalid_duration", "invalid ban duration")
					return
				}
				var expiresAt *time.Time
				if req.DurationSeconds > 0 {
					value := time.Now().UTC().Add(time.Duration(req.DurationSeconds) * time.Second)
					expiresAt = &value
				}
				ban, err := s.repo.CreateServerBan(r.Context(), parts[0], parts[2], reason, authCtx.User.ID, expiresAt)
				if errors.Is(err, store.ErrNotFound) {
					writeError(w, http.StatusConflict, "legacy_member", "legacy members without a client installation ID cannot be banned")
					return
				}
				if err == nil {
					if rotateErr := s.rotateServerChannelEpochs(r.Context(), parts[0], "member_banned"); rotateErr != nil {
						writeResult(w, nil, rotateErr)
						return
					}
					s.hub.DisconnectUser(parts[0], parts[2], "member.banned")
					s.audit(r.Context(), parts[0], authCtx.User.ID, "member.banned", parts[2], map[string]string{"reason": reason})
				}
				writeResult(w, ban, err)
				return
			case http.MethodDelete:
				if !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionMemberUnban) {
					return
				}
				err := s.repo.RevokeServerBan(r.Context(), parts[0], parts[2], authCtx.User.ID)
				if err == nil {
					s.audit(r.Context(), parts[0], authCtx.User.ID, "member.unbanned", parts[2], nil)
				}
				writeResult(w, map[string]any{"unbanned": err == nil}, err)
				return
			default:
				writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
				return
			}
		case "mute", "deafen":
			if r.Method != http.MethodPost {
				writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
				return
			}
			permission := store.PermissionMemberMute
			if parts[3] == "deafen" {
				permission = store.PermissionMemberDeafen
			}
			if !s.requireServerPermission(w, r, authCtx, parts[0], permission) {
				return
			}
			state, ok := s.hub.VoiceState(parts[0], parts[2])
			if !ok {
				writeError(w, http.StatusConflict, "not_in_voice", "member is not in a voice channel")
				return
			}
			if parts[3] == "mute" {
				state.Muted = true
				state.Speaking = false
			} else {
				state.Deafened = true
				state.Muted = true
				state.Speaking = false
			}
			state = s.hub.SetVoiceState(state)
			s.audit(r.Context(), parts[0], authCtx.User.ID, "member."+parts[3], parts[2], nil)
			writeJSON(w, http.StatusOK, state)
			return
		default:
			writeError(w, http.StatusNotFound, "not_found", "resource not found")
			return
		}
	}

	if len(parts) == 2 && parts[1] == "presence" && r.Method == http.MethodGet {
		if !s.requireServerAccess(w, r, authCtx, parts[0]) {
			return
		}
		snapshot := s.hub.Snapshot(parts[0])
		s.populateAvatarVersions(r.Context(), snapshot.Users)
		writeJSON(w, http.StatusOK, snapshot)
		return
	}

	if len(parts) == 2 && parts[1] == "state" && r.Method == http.MethodGet {
		if !s.requireServerAccess(w, r, authCtx, parts[0]) {
			return
		}
		server, err := s.repo.GetServer(r.Context(), parts[0])
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		channels, err := s.repo.ListChannels(r.Context(), parts[0])
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		snapshot := s.hub.Snapshot(parts[0])
		s.populateAvatarVersions(r.Context(), snapshot.Users)
		members, err := s.repo.ListServerMembers(r.Context(), parts[0])
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		rolesByUserID := make(map[string]string, len(members))
		for _, member := range members {
			rolesByUserID[member.UserID] = member.Role
		}
		for index := range snapshot.Users {
			snapshot.Users[index].Role = rolesByUserID[snapshot.Users[index].UserID]
		}
		currentUser := CurrentUserState{
			UserID: authCtx.User.ID, DefaultChannelID: server.DefaultChannelID,
		}
		currentUser.Role = rolesByUserID[authCtx.User.ID]
		currentUser.Permissions, err = s.repo.EffectiveServerPermissions(r.Context(), parts[0], authCtx.User.ID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		if current, ok := s.hub.CurrentChannel(parts[0], authCtx.User.ID); ok {
			channelID := current.ChannelID
			currentUser.CurrentChannelID = &channelID
			currentUser.SelectedChannelID = &channelID
		} else if server.DefaultChannelID != nil {
			channelID := *server.DefaultChannelID
			currentUser.SelectedChannelID = &channelID
		} else if len(channels) > 0 {
			channelID := channels[0].ID
			currentUser.SelectedChannelID = &channelID
		}
		retractMinutes, err := s.repo.GetMessageRetractWindowMinutes(r.Context(), parts[0])
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		writeJSON(w, http.StatusOK, ServerState{
			ServerID: parts[0], Channels: channels, OnlineUsers: snapshot.Users,
			VoiceStates: snapshot.VoiceStates, CurrentUser: currentUser,
			MessageRetractWindowMinutes: retractMinutes,
		})
		return
	}

	if len(parts) == 2 && parts[1] == "voice-state" {
		if !s.requireServerAccess(w, r, authCtx, parts[0]) {
			return
		}
		switch r.Method {
		case http.MethodPut:
			if !s.hub.UserOnlineInServer(parts[0], authCtx.User.ID) {
				writeError(w, http.StatusConflict, "websocket_required", "open a server WebSocket connection before updating voice state")
				return
			}
			var req struct {
				ChannelID              string `json:"channel_id"`
				Muted                  bool   `json:"muted"`
				Deafened               bool   `json:"deafened"`
				Speaking               bool   `json:"speaking"`
				ScreenSharing          bool   `json:"screen_sharing"`
				ScreenShareResolution  string `json:"screen_share_resolution"`
				ScreenShareFPS         int    `json:"screen_share_fps"`
				ScreenShareMediaNodeID string `json:"screen_share_media_node_id"`
			}
			if !decodeJSON(w, r, &req) {
				return
			}
			if strings.TrimSpace(req.ChannelID) == "" {
				writeError(w, http.StatusBadRequest, "missing_channel_id", "channel_id is required")
				return
			}
			channel, err := s.repo.GetChannel(r.Context(), req.ChannelID)
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			if channel.ServerID != parts[0] {
				writeError(w, http.StatusBadRequest, "channel_server_mismatch", "channel does not belong to server")
				return
			}
			if !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionVoiceJoin) {
				return
			}
			if !req.Muted || req.Speaking {
				canSpeak, err := s.repo.IsServerOwnerOrHasPermission(r.Context(), parts[0], authCtx.User.ID, store.PermissionVoiceSpeak)
				if err != nil {
					writeResult(w, nil, err)
					return
				}
				if !canSpeak {
					req.Muted = true
					req.Speaking = false
				}
			}
			if req.ScreenSharing {
				canShareScreen, err := s.repo.IsServerOwnerOrHasPermission(r.Context(), parts[0], authCtx.User.ID, store.PermissionVoiceScreenShare)
				if err != nil {
					writeResult(w, nil, err)
					return
				}
				server, err := s.repo.GetServer(r.Context(), parts[0])
				if err != nil {
					writeResult(w, nil, err)
					return
				}
				canShareScreen = canShareScreen && server.ScreenSharePolicy.Relay.Enabled
				if !canShareScreen {
					req.ScreenSharing = false
					req.ScreenShareResolution = ""
					req.ScreenShareFPS = 0
				} else {
					permissions, err := s.repo.EffectiveServerPermissions(r.Context(), parts[0], authCtx.User.ID)
					if err != nil {
						writeResult(w, nil, err)
						return
					}
					if !validScreenResolution(req.ScreenShareResolution) || !validScreenFPS(req.ScreenShareFPS) {
						writeError(w, http.StatusBadRequest, "invalid_screen_share_quality", "screen_sharing requires a supported resolution and fps")
						return
					}
					if !store.ScreenShareQualityAllowed(permissions, req.ScreenShareResolution, req.ScreenShareFPS) {
						writeError(w, http.StatusForbidden, "screen_share_quality_forbidden", "selected screen-share quality is not allowed for this role")
						return
					}
					for _, state := range s.hub.Snapshot(parts[0]).VoiceStates {
						if state.ChannelID == req.ChannelID && state.ScreenSharing && state.UserID != authCtx.User.ID {
							writeError(w, http.StatusConflict, "screen_share_in_progress", "another user is already sharing in this channel")
							return
						}
					}
					if previous, sharing := s.hub.VoiceState(parts[0], authCtx.User.ID); sharing && previous.ScreenSharing {
						if req.ScreenShareMediaNodeID != previous.ScreenShareMediaNodeID {
							writeError(w, http.StatusConflict, "screen_share_node_changed", "an active screen share cannot change relay nodes")
							return
						}
					} else {
						selectedNodeID := ""
						if node, err := s.repo.SelectMediaNode(r.Context(), parts[0]); err == nil {
							selectedNodeID = node.ID
						} else if !errors.Is(err, store.ErrNotFound) {
							writeResult(w, nil, err)
							return
						}
						if req.ScreenShareMediaNodeID != selectedNodeID {
							writeError(w, http.StatusConflict, "screen_share_node_changed", "screen-share relay node changed; request a new token")
							return
						}
					}
				}
			} else {
				req.ScreenShareResolution = ""
				req.ScreenShareFPS = 0
				req.ScreenShareMediaNodeID = ""
			}
			if !s.requireChannelAccess(w, r, authCtx, req.ChannelID) {
				return
			}
			current, ok := s.hub.CurrentChannel(parts[0], authCtx.User.ID)
			if !ok || current.ChannelID != req.ChannelID {
				writeError(w, http.StatusConflict, "current_channel_required", "enter the channel before updating its voice state")
				return
			}
			state, accepted := s.hub.SetVoiceStateIfScreenAvailable(realtime.VoiceState{
				ServerID:               parts[0],
				UserID:                 authCtx.User.ID,
				DisplayName:            authCtx.User.DisplayName,
				ChannelID:              req.ChannelID,
				Muted:                  req.Muted,
				Deafened:               req.Deafened,
				Speaking:               req.Speaking,
				ScreenSharing:          req.ScreenSharing,
				ScreenShareResolution:  req.ScreenShareResolution,
				ScreenShareFPS:         req.ScreenShareFPS,
				ScreenShareMediaNodeID: req.ScreenShareMediaNodeID,
			})
			if !accepted {
				writeError(w, http.StatusConflict, "screen_share_in_progress", "another user is already sharing in this channel")
				return
			}
			writeJSON(w, http.StatusOK, state)
		case http.MethodDelete:
			state, ok := s.hub.ClearVoiceState(parts[0], authCtx.User.ID)
			if !ok {
				writeJSON(w, http.StatusOK, map[string]any{"left": false})
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"left": true, "state": state})
		default:
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		}
		return
	}

	if len(parts) == 3 && parts[1] == "members" && r.Method == http.MethodPut {
		if !s.requireNotBanned(w, r, authCtx, parts[0]) {
			return
		}
		if !s.requireOwnerDevice(w, authCtx, parts[0]) {
			return
		}
		var req struct {
			Role        string   `json:"role"`
			Permissions []string `json:"permissions"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		role := store.NormalizeServerRole(req.Role)
		if role == store.RoleOwner {
			writeError(w, http.StatusBadRequest, "invalid_role", "owner can only be changed by ownership transfer")
			return
		}
		target, err := s.repo.GetServerMember(r.Context(), parts[0], parts[2])
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		if target.Role == store.RoleOwner {
			writeError(w, http.StatusBadRequest, "owner_protected", "owner role can only be changed by ownership transfer")
			return
		}
		permissions, err := normalizePermissions(req.Permissions)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid_permissions", err.Error())
			return
		}
		if role == store.RoleUser {
			permissions = nil
		} else if role == store.RoleAdmin && len(permissions) == 0 {
			permissions = store.AdminPermissions()
		}
		member, err := s.repo.SetServerMember(r.Context(), parts[0], parts[2], role, permissions)
		if err == nil {
			if target.Role != member.Role {
				if rotateErr := s.rotateServerChannelEpochs(r.Context(), parts[0], "member_role_changed"); rotateErr != nil {
					writeResult(w, nil, rotateErr)
					return
				}
			}
			s.audit(r.Context(), parts[0], authCtx.User.ID, "member.role_updated", parts[2], map[string]string{"role": role})
			s.enforceScreenSharePermissions(r.Context(), parts[0])
			s.hub.Publish(realtime.Event{Type: "server.permissions_updated", ServerID: parts[0]})
		}
		writeResult(w, member, err)
		return
	}

	if len(parts) == 2 && parts[1] == "media-nodes" {
		if !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionServerTransportUpdate) {
			return
		}
		switch r.Method {
		case http.MethodGet:
			nodes, err := s.repo.ListMediaNodes(r.Context(), parts[0])
			if err == nil {
				currentServer, serverErr := s.repo.GetServer(r.Context(), parts[0])
				if serverErr != nil {
					writeResult(w, nil, serverErr)
					return
				}
				for index := range nodes {
					stored, nodeErr := s.repo.GetMediaNode(r.Context(), parts[0], nodes[index].ID)
					if nodeErr != nil {
						writeResult(w, nil, nodeErr)
						return
					}
					nodes[index].IsLocal = s.isLocalLiveKitNode(stored, currentServer.TLSIdentifier)
				}
			}
			writeResult(w, nodes, err)
		case http.MethodPost:
			var req struct {
				Name                string `json:"name"`
				LiveKitURL          string `json:"livekit_url"`
				APIKey              string `json:"api_key"`
				APISecret           string `json:"api_secret"`
				Region              string `json:"region"`
				Weight              int    `json:"weight"`
				Enabled             *bool  `json:"enabled"`
				Draining            bool   `json:"draining"`
				MaxRelayBitrateKbps int    `json:"max_relay_bitrate_kbps"`
				MaxRooms            int    `json:"max_rooms"`
			}
			if !decodeJSON(w, r, &req) {
				return
			}
			if strings.TrimSpace(req.Name) == "" || strings.TrimSpace(req.LiveKitURL) == "" || strings.TrimSpace(req.APIKey) == "" || strings.TrimSpace(req.APISecret) == "" {
				writeError(w, http.StatusBadRequest, "invalid_media_node", "name, livekit_url, api_key, and api_secret are required")
				return
			}
			if req.Weight < 0 || req.MaxRelayBitrateKbps < 0 || req.MaxRooms < 0 {
				writeError(w, http.StatusBadRequest, "invalid_media_node", "weight, max_relay_bitrate_kbps, and max_rooms cannot be negative")
				return
			}
			currentServer, err := s.repo.GetServer(r.Context(), parts[0])
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			candidate := store.MediaNode{LiveKitURL: strings.TrimSpace(req.LiveKitURL), APIKey: strings.TrimSpace(req.APIKey), APISecret: req.APISecret}
			if !s.isLocalLiveKitNode(candidate, currentServer.TLSIdentifier) {
				if err := s.validateNodeTransport(r.Context(), parts[0], req.LiveKitURL, "wss"); err != nil {
					writeError(w, http.StatusConflict, "insecure_media_node", err.Error())
					return
				}
			}
			enabled := true
			if req.Enabled != nil {
				enabled = *req.Enabled
			}
			node, err := s.repo.CreateMediaNode(r.Context(), store.MediaNode{
				ServerID:            parts[0],
				Name:                strings.TrimSpace(req.Name),
				LiveKitURL:          strings.TrimSpace(req.LiveKitURL),
				APIKey:              strings.TrimSpace(req.APIKey),
				APISecret:           req.APISecret,
				Region:              strings.TrimSpace(req.Region),
				Weight:              req.Weight,
				Enabled:             enabled,
				Draining:            req.Draining,
				MaxRelayBitrateKbps: req.MaxRelayBitrateKbps,
				MaxRooms:            req.MaxRooms,
			})
			if err == nil {
				node.IsLocal = s.isLocalLiveKitNode(candidate, currentServer.TLSIdentifier)
			}
			writeResult(w, node, err)
		default:
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		}
		return
	}

	if len(parts) == 3 && parts[1] == "media-nodes" && r.Method == http.MethodPatch {
		if !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionServerTransportUpdate) {
			return
		}
		var req struct {
			Name                *string `json:"name"`
			LiveKitURL          *string `json:"livekit_url"`
			APIKey              *string `json:"api_key"`
			APISecret           *string `json:"api_secret"`
			Region              *string `json:"region"`
			Weight              *int    `json:"weight"`
			Enabled             *bool   `json:"enabled"`
			Draining            *bool   `json:"draining"`
			MaxRelayBitrateKbps *int    `json:"max_relay_bitrate_kbps"`
			MaxRooms            *int    `json:"max_rooms"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		patch := store.MediaNodePatch{
			Name:                trimOptionalString(req.Name),
			LiveKitURL:          trimOptionalString(req.LiveKitURL),
			APIKey:              trimOptionalString(req.APIKey),
			APISecret:           req.APISecret,
			Region:              trimOptionalString(req.Region),
			Weight:              req.Weight,
			Enabled:             req.Enabled,
			Draining:            req.Draining,
			MaxRelayBitrateKbps: req.MaxRelayBitrateKbps,
			MaxRooms:            req.MaxRooms,
		}
		if err := validateMediaNodePatch(patch); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_media_node", err.Error())
			return
		}
		current, err := s.repo.GetMediaNode(r.Context(), parts[0], parts[2])
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		liveKitURL, enabled, draining := current.LiveKitURL, current.Enabled, current.Draining
		if patch.LiveKitURL != nil {
			liveKitURL = *patch.LiveKitURL
		}
		if patch.Enabled != nil {
			enabled = *patch.Enabled
		}
		if patch.Draining != nil {
			draining = *patch.Draining
		}
		connectionChanged := (patch.LiveKitURL != nil && *patch.LiveKitURL != current.LiveKitURL) ||
			(patch.APIKey != nil && *patch.APIKey != current.APIKey) ||
			(patch.APISecret != nil && *patch.APISecret != current.APISecret)
		if connectionChanged {
			for _, state := range s.hub.Snapshot(parts[0]).VoiceStates {
				if state.ScreenSharing && state.ScreenShareMediaNodeID == current.ID {
					writeError(w, http.StatusConflict, "screen_share_node_in_use", "stop the active screen share before changing this relay address or credentials")
					return
				}
			}
		}
		candidate := current
		candidate.LiveKitURL = liveKitURL
		if patch.APIKey != nil {
			candidate.APIKey = *patch.APIKey
		}
		if patch.APISecret != nil {
			candidate.APISecret = *patch.APISecret
		}
		currentServer, err := s.repo.GetServer(r.Context(), parts[0])
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		bundled := s.isLocalLiveKitNode(candidate, currentServer.TLSIdentifier)
		if !bundled && (patch.LiveKitURL != nil || (enabled && !draining)) {
			if err := s.validateNodeTransport(r.Context(), parts[0], liveKitURL, "wss"); err != nil {
				writeError(w, http.StatusConflict, "insecure_media_node", err.Error())
				return
			}
		}
		node, err := s.repo.UpdateMediaNode(r.Context(), parts[0], parts[2], patch)
		if err == nil {
			node.IsLocal = bundled
		}
		writeResult(w, node, err)
		return
	}

	if len(parts) == 2 && parts[1] == "file-nodes" {
		if !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionServerTransportUpdate) {
			return
		}
		switch r.Method {
		case http.MethodGet:
			nodes, err := s.repo.ListFileNodes(r.Context(), parts[0])
			writeResult(w, nodes, err)
		case http.MethodPost:
			var req struct {
				Name    string `json:"name"`
				BaseURL string `json:"base_url"`
				Secret  string `json:"secret"`
				Enabled *bool  `json:"enabled"`
			}
			if !decodeJSON(w, r, &req) {
				return
			}
			baseURL, err := normalizeFileNodeURL(req.BaseURL)
			if strings.TrimSpace(req.Name) == "" || strings.TrimSpace(req.Secret) == "" || err != nil {
				writeError(w, http.StatusBadRequest, "invalid_file_node", "name, valid HTTPS base_url, and secret are required")
				return
			}
			enabled := true
			if req.Enabled != nil {
				enabled = *req.Enabled
			}
			if err := s.validateNodeTransport(r.Context(), parts[0], baseURL, "https"); err != nil {
				writeError(w, http.StatusConflict, "insecure_file_node", err.Error())
				return
			}
			if enabled {
				if err := checkFileNode(r.Context(), baseURL, req.Secret); err != nil {
					writeError(w, http.StatusBadGateway, "file_node_unavailable", "外部附件节点连接或密钥校验失败: "+err.Error())
					return
				}
			}
			node, err := s.repo.CreateFileNode(r.Context(), store.FileNode{ServerID: parts[0], Name: strings.TrimSpace(req.Name), BaseURL: baseURL, Secret: req.Secret, Enabled: enabled})
			writeResult(w, node, err)
		default:
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		}
		return
	}

	if len(parts) == 3 && parts[1] == "file-nodes" && r.Method == http.MethodPatch {
		if !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionServerTransportUpdate) {
			return
		}
		var req struct {
			Name    *string `json:"name"`
			BaseURL *string `json:"base_url"`
			Secret  *string `json:"secret"`
			Enabled *bool   `json:"enabled"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		if req.BaseURL != nil {
			value, err := normalizeFileNodeURL(*req.BaseURL)
			if err != nil {
				writeError(w, http.StatusBadRequest, "invalid_file_node", "base_url must be a valid HTTPS URL")
				return
			}
			req.BaseURL = &value
		}
		current, err := s.repo.GetFileNode(r.Context(), parts[0], parts[2])
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		baseURL, secret, enabled := current.BaseURL, current.Secret, current.Enabled
		if req.BaseURL != nil {
			baseURL = *req.BaseURL
		}
		if req.Secret != nil {
			secret = *req.Secret
		}
		if req.Enabled != nil {
			enabled = *req.Enabled
		}
		if req.BaseURL != nil || enabled {
			if err := s.validateNodeTransport(r.Context(), parts[0], baseURL, "https"); err != nil {
				writeError(w, http.StatusConflict, "insecure_file_node", err.Error())
				return
			}
		}
		if enabled && (req.BaseURL != nil || req.Secret != nil || req.Enabled != nil) {
			if err := checkFileNode(r.Context(), baseURL, secret); err != nil {
				writeError(w, http.StatusBadGateway, "file_node_unavailable", "外部附件节点连接或密钥校验失败: "+err.Error())
				return
			}
		}
		node, err := s.repo.UpdateFileNode(r.Context(), parts[0], parts[2], store.FileNodePatch{Name: trimOptionalString(req.Name), BaseURL: req.BaseURL, Secret: req.Secret, Enabled: req.Enabled})
		writeResult(w, node, err)
		return
	}

	if len(parts) == 2 && parts[1] == "channels" {
		if r.Method == http.MethodGet {
			channels, err := s.repo.ListChannels(r.Context(), parts[0])
			writeResult(w, channels, err)
			return
		}
		if r.Method == http.MethodPost {
			if !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionChannelCreate) {
				return
			}
			var req struct {
				Name      string `json:"name"`
				SortOrder int    `json:"sort_order"`
			}
			if !decodeJSON(w, r, &req) {
				return
			}
			if req.Name == "" {
				writeError(w, http.StatusBadRequest, "invalid_name", "name is required")
				return
			}
			channel, err := s.repo.CreateChannel(r.Context(), store.Channel{
				ServerID:  parts[0],
				Name:      req.Name,
				SortOrder: req.SortOrder,
			})
			writeResult(w, channel, err)
			return
		}
	}

	if len(parts) == 2 && parts[1] == "settings" && r.Method == http.MethodPatch {
		var req struct {
			Name                      *string                         `json:"name"`
			EncryptionMode            *string                         `json:"encryption_mode"`
			FileRoot                  *string                         `json:"file_root"`
			HistoryRetentionDays      *int                            `json:"history_retention_days"`
			ServerPassword            *string                         `json:"server_password"`
			ClearServerPassword       bool                            `json:"clear_server_password"`
			ScreenSharePolicy         *store.ScreenSharePolicy        `json:"screen_share_policy"`
			DefaultChannelID          *string                         `json:"default_channel_id"`
			AttachmentExternalEnabled *bool                           `json:"attachment_external_enabled"`
			AttachmentFileNodeID      *string                         `json:"attachment_file_node_id"`
			VoiceAudioBitrateKbps     *int                            `json:"voice_audio_bitrate_kbps"`
			ScreenShareBitrateLimits  *store.ScreenShareBitrateLimits `json:"screen_share_bitrate_limits_mbps"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		if req.EncryptionMode != nil {
			mode, ok := config.NormalizeEncryptionMode(*req.EncryptionMode)
			if !ok {
				writeError(w, http.StatusBadRequest, "invalid_encryption_mode", "encryption_mode must be none, transport, or e2ee")
				return
			}
			req.EncryptionMode = &mode
			if mode == "none" {
				server, err := s.repo.GetServer(r.Context(), parts[0])
				if err != nil {
					writeResult(w, nil, err)
					return
				}
				if server.TLSStatus == "active" {
					writeError(w, http.StatusConflict, "secure_downgrade_required", "切换到不加密需要服主确认并迁移客户端到 HTTP/WS")
					return
				}
			}
			if mode == "e2ee" {
				server, err := s.repo.GetServer(r.Context(), parts[0])
				if err != nil {
					writeResult(w, nil, err)
					return
				}
				if server.TLSStatus != "active" {
					writeError(w, http.StatusConflict, "tls_required", "端到端加密必须先启用并验证传输层加密")
					return
				}
			}
			if mode == "transport" {
				server, err := s.repo.GetServer(r.Context(), parts[0])
				if err != nil {
					writeResult(w, nil, err)
					return
				}
				if server.TLSStatus != "active" {
					writeError(w, http.StatusConflict, "tls_required", "请先通过证书配置启用传输层加密")
					return
				}
			}
		}
		var previousEncryptionMode string
		if req.EncryptionMode != nil {
			current, err := s.repo.GetServer(r.Context(), parts[0])
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			previousEncryptionMode = current.EncryptionMode
		}
		if req.Name != nil {
			trimmed := strings.TrimSpace(*req.Name)
			if trimmed == "" {
				writeError(w, http.StatusBadRequest, "invalid_name", "name is required")
				return
			}
			req.Name = &trimmed
		}
		if req.Name != nil && !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionServerProfileUpdate) {
			return
		}
		transportChanged := req.EncryptionMode != nil || req.FileRoot != nil || req.ScreenSharePolicy != nil ||
			req.AttachmentExternalEnabled != nil || req.AttachmentFileNodeID != nil || req.VoiceAudioBitrateKbps != nil ||
			req.ScreenShareBitrateLimits != nil
		if transportChanged && !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionServerTransportUpdate) {
			return
		}
		generalChanged := req.HistoryRetentionDays != nil || req.ServerPassword != nil ||
			req.DefaultChannelID != nil || req.ClearServerPassword
		if generalChanged && !s.requireServerPermission(w, r, authCtx, parts[0], store.PermissionServerSettingsUpdate) {
			return
		}
		if req.ScreenSharePolicy != nil {
			if err := validateScreenSharePolicy(*req.ScreenSharePolicy); err != nil {
				writeError(w, http.StatusBadRequest, "invalid_screen_share_policy", err.Error())
				return
			}
		}
		if req.VoiceAudioBitrateKbps != nil && !validVoiceAudioBitrate(*req.VoiceAudioBitrateKbps) {
			writeError(w, http.StatusBadRequest, "invalid_voice_audio_bitrate", "voice_audio_bitrate_kbps must be 24, 48, 64, 96, or 128")
			return
		}
		if req.ScreenShareBitrateLimits != nil && !req.ScreenShareBitrateLimits.Valid() {
			writeError(w, http.StatusBadRequest, "invalid_screen_share_bitrate_limits", "all screen-share bitrate limits must be between 1 and 200 Mbps")
			return
		}
		if req.DefaultChannelID != nil {
			trimmed := strings.TrimSpace(*req.DefaultChannelID)
			if trimmed == "" {
				writeError(w, http.StatusBadRequest, "invalid_default_channel", "default_channel_id cannot be empty")
				return
			}
			channel, err := s.repo.GetChannel(r.Context(), trimmed)
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			if channel.ServerID != parts[0] {
				writeError(w, http.StatusBadRequest, "channel_server_mismatch", "default channel does not belong to server")
				return
			}
			req.DefaultChannelID = &trimmed
		}
		var passwordHash *string
		if req.ClearServerPassword {
			empty := ""
			passwordHash = &empty
		} else if req.ServerPassword != nil {
			hash, err := auth.HashSecret(*req.ServerPassword)
			if err != nil {
				writeError(w, http.StatusBadRequest, "invalid_password", err.Error())
				return
			}
			passwordHash = &hash
		}
		validateExternalFileNode := req.AttachmentExternalEnabled != nil && *req.AttachmentExternalEnabled
		if req.AttachmentExternalEnabled == nil && req.AttachmentFileNodeID != nil {
			currentServer, err := s.repo.GetServer(r.Context(), parts[0])
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			validateExternalFileNode = currentServer.AttachmentExternalEnabled
		}
		if validateExternalFileNode {
			if req.AttachmentFileNodeID == nil || strings.TrimSpace(*req.AttachmentFileNodeID) == "" {
				writeError(w, http.StatusBadRequest, "missing_file_node", "attachment_file_node_id is required when external attachments are enabled")
				return
			}
			nodeID := strings.TrimSpace(*req.AttachmentFileNodeID)
			node, err := s.repo.GetFileNode(r.Context(), parts[0], nodeID)
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			if !node.Enabled {
				writeError(w, http.StatusBadRequest, "file_node_disabled", "attachment file node is disabled")
				return
			}
			if err := s.validateNodeTransport(r.Context(), parts[0], node.BaseURL, "https"); err != nil {
				writeError(w, http.StatusConflict, "insecure_file_node", err.Error())
				return
			}
			req.AttachmentFileNodeID = &nodeID
		}
		if req.EncryptionMode != nil && *req.EncryptionMode == "e2ee" && previousEncryptionMode != "e2ee" {
			if _, err := s.repo.RotateServerChannelEpochs(r.Context(), parts[0], "e2ee_enabled"); err != nil {
				writeResult(w, nil, err)
				return
			}
		}
		server, err := s.repo.UpdateServer(r.Context(), parts[0], req.Name, req.EncryptionMode, req.FileRoot, req.HistoryRetentionDays, passwordHash, req.ScreenSharePolicy, req.DefaultChannelID, req.AttachmentExternalEnabled, req.AttachmentFileNodeID, req.VoiceAudioBitrateKbps, req.ScreenShareBitrateLimits)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		writeJSON(w, http.StatusOK, server)
		if req.ScreenSharePolicy != nil {
			s.enforceScreenSharePermissions(r.Context(), parts[0])
		}
		if passwordHash != nil {
			s.hub.DisconnectClientType("web", "server.password_changed")
		}
		if previousEncryptionMode != "" && previousEncryptionMode != server.EncryptionMode {
			s.hub.NotifyAndDisconnectServer(parts[0], realtime.Event{
				Type: "server.encryption_changed", ServerID: parts[0],
				Payload: map[string]any{"encryption_mode": server.EncryptionMode},
			})
		}
		return
	}

	writeError(w, http.StatusNotFound, "not_found", "route not found")
}

func (s *Server) populateAvatarVersions(ctx context.Context, users []realtime.UserPresence) {
	for index := range users {
		user, err := s.repo.GetUser(ctx, users[index].UserID)
		if err == nil {
			users[index].AvatarVersion = user.AvatarVersion
		}
	}
}

func (s *Server) handleChannels(w http.ResponseWriter, r *http.Request, authCtx authContext, parts []string) {
	if len(parts) == 3 && parts[1] == "messages" && r.Method == http.MethodDelete {
		channelID, messageID := parts[0], parts[2]
		if !s.requireChannelAccess(w, r, authCtx, channelID) {
			return
		}
		message, err := s.repo.GetChannelMessage(r.Context(), messageID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		if message.ChannelID != channelID {
			writeError(w, http.StatusNotFound, "not_found", "message not found")
			return
		}
		if message.Kind == "removed" {
			writeError(w, http.StatusConflict, "message_already_removed", "message is already removed")
			return
		}
		channel, err := s.repo.GetChannel(r.Context(), channelID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		canManage, err := s.repo.IsServerOwnerOrHasPermission(r.Context(), channel.ServerID, authCtx.User.ID, store.PermissionChannelMessagesManage)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		ownMessage := message.SenderUserID == authCtx.User.ID
		retractExpired := false
		if ownMessage {
			retractMinutes, err := s.repo.GetMessageRetractWindowMinutes(r.Context(), channel.ServerID)
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			retractExpired = time.Now().UTC().After(message.CreatedAt.Add(time.Duration(retractMinutes) * time.Minute))
		}
		requestedAction := r.URL.Query().Get("action")
		if requestedAction == "" {
			if ownMessage && !retractExpired {
				requestedAction = "retract"
			} else {
				requestedAction = "delete"
			}
		}
		removalKind := ""
		switch requestedAction {
		case "retract":
			if !ownMessage {
				writeError(w, http.StatusForbidden, "forbidden", "only the sender can retract this message")
				return
			}
			if retractExpired {
				writeError(w, http.StatusForbidden, "retract_window_expired", "the message retract window has expired")
				return
			}
			removalKind = "retracted"
		case "delete":
			if !canManage {
				writeError(w, http.StatusForbidden, "forbidden", "missing permission: "+store.PermissionChannelMessagesManage)
				return
			}
			removalKind = "deleted"
		default:
			writeError(w, http.StatusBadRequest, "invalid_message_action", "action must be retract or delete")
			return
		}
		if err := s.repo.DeleteChannelMessage(r.Context(), messageID, removalKind); err != nil {
			writeResult(w, nil, err)
			return
		}
		s.hub.Publish(realtime.Event{Type: "channel.message_deleted", ServerID: channel.ServerID, ChannelID: channelID, Payload: map[string]any{"message_id": messageID}})
		if removalKind == "deleted" {
			s.audit(r.Context(), channel.ServerID, authCtx.User.ID, "message.deleted_by_moderator", messageID, map[string]string{"sender_user_id": message.SenderUserID})
		}
		writeJSON(w, http.StatusOK, map[string]any{"deleted": true})
		return
	}
	if len(parts) == 1 {
		channelID := parts[0]
		channel, err := s.repo.GetChannel(r.Context(), channelID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		switch r.Method {
		case http.MethodPatch:
			var req struct {
				Name      *string `json:"name"`
				SortOrder *int    `json:"sort_order"`
			}
			if !decodeJSON(w, r, &req) {
				return
			}
			if req.Name != nil {
				value := strings.TrimSpace(*req.Name)
				if value == "" {
					writeError(w, http.StatusBadRequest, "invalid_name", "name is required")
					return
				}
				req.Name = &value
				if !s.requireServerPermission(w, r, authCtx, channel.ServerID, store.PermissionChannelEdit) {
					return
				}
			}
			if req.SortOrder != nil && !s.requireServerPermission(w, r, authCtx, channel.ServerID, store.PermissionChannelReorder) {
				return
			}
			updated, err := s.repo.UpdateChannel(r.Context(), channelID, req.Name, req.SortOrder)
			writeResult(w, updated, err)
		case http.MethodDelete:
			if !s.requireServerPermission(w, r, authCtx, channel.ServerID, store.PermissionChannelDelete) {
				return
			}
			if err := s.repo.DeleteChannel(r.Context(), channelID); err != nil {
				if errors.Is(err, store.ErrLastChannel) {
					writeError(w, http.StatusConflict, "last_channel", "the last channel cannot be deleted")
					return
				}
				writeResult(w, nil, err)
				return
			}
			for _, user := range s.hub.Snapshot(channel.ServerID).Users {
				if user.CurrentChannelID != nil && *user.CurrentChannelID == channelID {
					s.hub.ClearCurrentChannel(channel.ServerID, user.UserID)
					s.hub.ClearVoiceState(channel.ServerID, user.UserID)
				}
			}
			s.audit(r.Context(), channel.ServerID, authCtx.User.ID, "channel.deleted", channelID, map[string]string{"name": channel.Name})
			writeJSON(w, http.StatusOK, map[string]any{"deleted": true})
		default:
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		}
		return
	}
	if len(parts) < 2 {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}
	channelID := parts[0]
	switch parts[1] {
	case "join":
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
			return
		}
		var req struct {
			UserID     string `json:"user_id"`
			Role       string `json:"role"`
			AccessOnly bool   `json:"access_only"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		channel, err := s.repo.GetChannel(r.Context(), channelID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		targetUserID := strings.TrimSpace(req.UserID)
		if targetUserID == "" {
			targetUserID = authCtx.User.ID
		}
		if targetUserID == authCtx.User.ID {
			permission := store.PermissionVoiceJoin
			if req.AccessOnly {
				permission = store.PermissionChannelMessagesView
			}
			if !s.requireServerAccess(w, r, authCtx, channel.ServerID) ||
				!s.requireServerPermission(w, r, authCtx, channel.ServerID, permission) {
				return
			}
		} else {
			if req.AccessOnly {
				writeError(w, http.StatusBadRequest, "invalid_access", "access_only is available only for the current user")
				return
			}
			if !s.requireChannelServerPermission(w, r, authCtx, channelID, store.PermissionMemberMove) {
				return
			}
		}
		if !req.AccessOnly && !s.hub.UserOnlineInServer(channel.ServerID, targetUserID) {
			writeError(w, http.StatusConflict, "websocket_required", "open a server WebSocket connection before entering a channel")
			return
		}
		hasAccess, err := s.repo.IsChannelMemberOrOwnerOrAdmin(r.Context(), channelID, targetUserID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		var epoch *store.ChannelEpoch
		if !hasAccess {
			role := req.Role
			if req.AccessOnly {
				role = "member"
			}
			if err := s.repo.AddChannelMember(r.Context(), channelID, targetUserID, role); err != nil {
				writeResult(w, nil, err)
				return
			}
			created, err := s.repo.CreateEpoch(r.Context(), channelID, "access_granted")
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			epoch = &created
		}
		if req.AccessOnly {
			if epoch != nil {
				s.beginMediaKeyTransition(r.Context(), channel.ServerID, *epoch)
				s.hub.Publish(realtime.Event{
					Type: "channel.access_granted", ServerID: channel.ServerID, ChannelID: channelID,
					Payload: map[string]any{"user_id": targetUserID, "epoch": *epoch},
				})
			}
			writeJSON(w, http.StatusOK, map[string]any{"access_granted": epoch != nil, "epoch": epoch})
			return
		}
		previous, hadPrevious := s.hub.CurrentChannel(channel.ServerID, targetUserID)
		state := s.hub.SetCurrentChannel(channel.ServerID, targetUserID, channelID)
		if hadPrevious && previous.ChannelID != channelID {
			s.hub.ClearVoiceState(channel.ServerID, targetUserID)
		}
		if epoch != nil {
			s.beginMediaKeyTransition(r.Context(), channel.ServerID, *epoch)
			s.hub.Publish(realtime.Event{
				Type: "channel.access_granted", ServerID: channel.ServerID, ChannelID: channelID,
				Payload: map[string]any{"user_id": targetUserID, "epoch": *epoch},
			})
		}
		writeJSON(w, http.StatusOK, map[string]any{"current_channel": state, "epoch": epoch})
	case "leave":
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
			return
		}
		var req struct {
			UserID string `json:"user_id"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		targetUserID := strings.TrimSpace(req.UserID)
		if targetUserID == "" {
			targetUserID = authCtx.User.ID
		}
		if targetUserID != authCtx.User.ID && !s.requireChannelServerPermission(w, r, authCtx, channelID, store.PermissionMemberMove) {
			return
		}
		channel, err := s.repo.GetChannel(r.Context(), channelID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		left := false
		if current, ok := s.hub.CurrentChannel(channel.ServerID, targetUserID); ok && current.ChannelID == channelID {
			_, left = s.hub.ClearCurrentChannel(channel.ServerID, targetUserID)
			s.hub.ClearVoiceState(channel.ServerID, targetUserID)
		}
		writeJSON(w, http.StatusOK, map[string]any{"left": left})
	case "messages":
		s.handleChannelMessages(w, r, authCtx, channelID)
	case "members":
		if r.Method == http.MethodGet {
			if !s.requireChannelAccess(w, r, authCtx, channelID) {
				return
			}
			members, err := s.repo.ListChannelMembers(r.Context(), channelID)
			writeResult(w, members, err)
			return
		}
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	case "e2ee", "media-e2ee":
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
			return
		}
		media := parts[1] == "media-e2ee"
		permission := store.PermissionChannelMessagesView
		if media {
			permission = store.PermissionVoiceJoin
		}
		if !s.requireChannelAccess(w, r, authCtx, channelID) ||
			!s.requireChannelServerPermission(w, r, authCtx, channelID, permission) {
			return
		}
		epoch, err := s.repo.GetLatestEpoch(r.Context(), channelID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		devices, err := s.repo.ListChannelDevices(r.Context(), channelID, epoch.ID, media)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		response := map[string]any{"epoch": epoch, "devices": devices}
		if media {
			keyIndex, active, slots := s.mediaKeyStatus(channelID, epoch.ID)
			response["media_key_index"] = keyIndex
			response["media_key_active"] = active
			response["media_key_slots"] = slots
		}
		writeJSON(w, http.StatusOK, response)
	case "images":
		if r.Method == http.MethodPost {
			s.handleChannelImageUpload(w, r, authCtx, channelID)
			return
		}
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	case "files":
		if r.Method == http.MethodPost {
			s.handleChannelFileUpload(w, r, authCtx, channelID)
			return
		}
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	case "voice-token":
		s.handleChannelVoiceToken(w, r, authCtx, channelID)
	case "screen-share-token":
		s.handleChannelScreenShareToken(w, r, authCtx, channelID)
	default:
		writeError(w, http.StatusNotFound, "not_found", "route not found")
	}
}

func (s *Server) handleChannelVoiceToken(w http.ResponseWriter, r *http.Request, authCtx authContext, channelID string) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	if !s.requireChannelAccess(w, r, authCtx, channelID) {
		return
	}
	channel, err := s.repo.GetChannel(r.Context(), channelID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if !s.requireServerPermission(w, r, authCtx, channel.ServerID, store.PermissionVoiceJoin) {
		return
	}
	server, err := s.repo.GetServer(r.Context(), channel.ServerID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	var req struct {
		CanPublish          *bool  `json:"can_publish"`
		CanSubscribe        *bool  `json:"can_subscribe"`
		PersistentRoom      bool   `json:"persistent_room"`
		E2EEParticipantKeys bool   `json:"e2ee_participant_keys"`
		MediaKeySlots       bool   `json:"media_key_slots"`
		DeviceID            string `json:"device_id"`
		E2EEEpochID         string `json:"e2ee_epoch_id"`
	}
	if r.Body != nil && r.ContentLength != 0 {
		if !decodeJSON(w, r, &req) {
			return
		}
	}
	canSpeak, err := s.repo.IsServerOwnerOrHasPermission(r.Context(), channel.ServerID, authCtx.User.ID, store.PermissionVoiceSpeak)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	canShareScreen, err := s.repo.IsServerOwnerOrHasPermission(r.Context(), channel.ServerID, authCtx.User.ID, store.PermissionVoiceScreenShare)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	canShareScreen = canShareScreen && server.ScreenSharePolicy.Relay.Enabled
	canSubscribe := true
	if req.CanPublish != nil {
		if *req.CanPublish && !canSpeak {
			writeError(w, http.StatusForbidden, "forbidden", "server permission required: "+store.PermissionVoiceSpeak)
			return
		}
		if !*req.CanPublish {
			canSpeak = false
			canShareScreen = false
		}
	}
	if req.CanSubscribe != nil {
		canSubscribe = *req.CanSubscribe
	}
	canPublishSources := make([]string, 0, 1)
	if canSpeak {
		canPublishSources = append(canPublishSources, "microphone")
	}
	e2eeEpochID := ""
	if server.EncryptionMode == "e2ee" {
		var ok bool
		e2eeEpochID, ok = s.requireMediaE2EEAccess(
			w, r, authCtx, channelID, req.DeviceID, req.E2EEEpochID,
		)
		if !ok {
			return
		}
		s.recordMediaKeyClient(channel.ServerID, authCtx.User.ID, req.MediaKeySlots)
		if !req.MediaKeySlots {
			s.disableMediaKeySlots(channel.ServerID, channelID, e2eeEpochID)
		}
	}
	e2eeParticipantKeys := server.EncryptionMode == "e2ee" && req.E2EEParticipantKeys
	roomScope := "channel"
	room := liveKitRoomName(channel.ServerID, channel.ID)
	if req.PersistentRoom && (server.EncryptionMode != "e2ee" || e2eeParticipantKeys) {
		roomScope = "server"
		room = liveKitServerRoomName(channel.ServerID)
	}
	liveKitCfg := s.cfg.LiveKit
	if liveKitCfg.URL == "" || liveKitCfg.APIKey == "" || liveKitCfg.APISecret == "" {
		nodes, listErr := s.repo.ListMediaNodes(r.Context(), channel.ServerID)
		if listErr != nil {
			writeResult(w, nil, listErr)
			return
		}
		for _, summary := range nodes {
			node, getErr := s.repo.GetMediaNode(r.Context(), channel.ServerID, summary.ID)
			if errors.Is(getErr, store.ErrNotFound) {
				continue
			}
			if getErr != nil {
				writeResult(w, nil, getErr)
				return
			}
			if s.isLocalLiveKitNode(node, server.TLSIdentifier) {
				liveKitCfg = liveKitConfigFromMediaNode(node, liveKitCfg.TokenTTL)
				break
			}
		}
	}
	token, err := livekit.CreateAccessToken(liveKitCfg, livekit.TokenRequest{
		Identity:          authCtx.User.ID,
		Name:              authCtx.User.DisplayName,
		Room:              room,
		CanPublish:        canSpeak,
		CanPublishSources: canPublishSources,
		CanSubscribe:      canSubscribe,
	})
	if err != nil {
		writeLiveKitError(w, err)
		return
	}
	publicLiveKitURL := token.URL
	if server.TLSStatus == "active" {
		publicLiveKitURL = secureLiveKitURL(server.TLSIdentifier, s.cfg.TLS.SecurePublicPort)
	} else if server.TLSStatus == "discovery" {
		if upstreamUsesPort(s.cfg.TLS.BackendUpstream, s.cfg.TLS.PlainPublicPort) {
			if directURL := plainLiveKitURL(server.TLSIdentifier, s.cfg.TLS.LiveKitUpstream); directURL != "" {
				publicLiveKitURL = directURL
			}
		} else {
			publicLiveKitURL = strings.Replace(plainServerURL(server.TLSIdentifier, s.cfg.TLS.PlainPublicPort), "http://", "ws://", 1)
		}
	}
	e2eeKeyIndex, e2eeKeyActive, mediaKeySlots := 0, true, false
	if server.EncryptionMode == "e2ee" {
		e2eeKeyIndex, e2eeKeyActive, mediaKeySlots = s.mediaKeyStatus(channelID, e2eeEpochID)
	}
	response := map[string]any{
		"url":                      publicLiveKitURL,
		"token":                    token.Token,
		"expires_at":               token.ExpiresAt,
		"room":                     room,
		"room_scope":               roomScope,
		"server_id":                channel.ServerID,
		"channel_id":               channel.ID,
		"media_node_id":            "",
		"voice_audio_bitrate_kbps": server.VoiceAudioBitrateKbps,
		"encryption_mode":          server.EncryptionMode,
		"e2ee_required":            server.EncryptionMode == "e2ee",
		"e2ee_epoch_id":            e2eeEpochID,
		"e2ee_key_index":           e2eeKeyIndex,
		"e2ee_key_active":          e2eeKeyActive,
		"e2ee_participant_keys":    e2eeParticipantKeys && roomScope == "server",
		"media_key_slots":          mediaKeySlots,
		"can_publish":              canSpeak,
		"can_share_screen":         canShareScreen,
	}
	writeJSON(w, http.StatusOK, response)
}

func (s *Server) handleChannelScreenShareToken(w http.ResponseWriter, r *http.Request, authCtx authContext, channelID string) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	if !s.requireChannelAccess(w, r, authCtx, channelID) {
		return
	}
	channel, err := s.repo.GetChannel(r.Context(), channelID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if !s.requireServerPermission(w, r, authCtx, channel.ServerID, store.PermissionVoiceJoin) {
		return
	}
	current, ok := s.hub.CurrentChannel(channel.ServerID, authCtx.User.ID)
	if !ok || current.ChannelID != channelID {
		writeError(w, http.StatusConflict, "current_channel_required", "enter the channel before requesting a screen-share token")
		return
	}
	server, err := s.repo.GetServer(r.Context(), channel.ServerID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	var req struct {
		Publish         bool   `json:"publish"`
		PublisherUserID string `json:"publisher_user_id"`
		Resolution      string `json:"resolution"`
		FPS             int    `json:"fps"`
		DeviceID        string `json:"device_id"`
		E2EEEpochID     string `json:"e2ee_epoch_id"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	publisherUserID := strings.TrimSpace(req.PublisherUserID)
	var mediaNode *store.MediaNode
	if req.Publish {
		publisherUserID = authCtx.User.ID
		canShare, err := s.repo.IsServerOwnerOrHasPermission(r.Context(), channel.ServerID, authCtx.User.ID, store.PermissionVoiceScreenShare)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		permissions, err := s.repo.EffectiveServerPermissions(r.Context(), channel.ServerID, authCtx.User.ID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		if !canShare || !server.ScreenSharePolicy.Relay.Enabled {
			writeError(w, http.StatusForbidden, "forbidden", "screen sharing is not allowed")
			return
		}
		if !store.ScreenShareQualityAllowed(permissions, req.Resolution, req.FPS) {
			writeError(w, http.StatusForbidden, "screen_share_quality_forbidden", "selected screen-share quality is not allowed for this role")
			return
		}
		for _, state := range s.hub.Snapshot(channel.ServerID).VoiceStates {
			if state.ChannelID == channelID && state.ScreenSharing && state.UserID != authCtx.User.ID {
				writeError(w, http.StatusConflict, "screen_share_in_progress", "another user is already sharing in this channel")
				return
			}
		}
		if selected, err := s.repo.SelectMediaNode(r.Context(), channel.ServerID); err == nil {
			mediaNode = &selected
		} else if !errors.Is(err, store.ErrNotFound) {
			writeResult(w, nil, err)
			return
		}
	} else {
		if publisherUserID == "" {
			writeError(w, http.StatusBadRequest, "missing_publisher", "publisher_user_id is required")
			return
		}
		var sharingState *realtime.VoiceState
		for _, state := range s.hub.Snapshot(channel.ServerID).VoiceStates {
			if state.ChannelID == channelID && state.UserID == publisherUserID && state.ScreenSharing {
				copy := state
				sharingState = &copy
				break
			}
		}
		if sharingState == nil {
			writeError(w, http.StatusConflict, "screen_share_not_active", "the selected user is not sharing in this channel")
			return
		}
		if sharingState.ScreenShareMediaNodeID != "" {
			node, err := s.repo.GetMediaNode(r.Context(), channel.ServerID, sharingState.ScreenShareMediaNodeID)
			if err != nil {
				if errors.Is(err, store.ErrNotFound) {
					writeError(w, http.StatusConflict, "screen_share_node_unavailable", "the active screen-share relay no longer exists")
					return
				}
				writeResult(w, nil, err)
				return
			}
			mediaNode = &node
		}
	}

	e2eeEpochID := ""
	if server.EncryptionMode == "e2ee" {
		var allowed bool
		e2eeEpochID, allowed = s.requireMediaE2EEAccess(
			w, r, authCtx, channelID, req.DeviceID, req.E2EEEpochID,
		)
		if !allowed {
			return
		}
	}
	liveKitCfg := s.cfg.LiveKit
	mediaNodeID := ""
	if mediaNode != nil {
		liveKitCfg = liveKitConfigFromMediaNode(*mediaNode, s.cfg.LiveKit.TokenTTL)
		mediaNodeID = mediaNode.ID
	}
	publishSources := []string(nil)
	if req.Publish {
		publishSources = []string{"screen_share"}
	}
	room := liveKitScreenShareRoomName(channel.ServerID, channelID, publisherUserID)
	token, err := livekit.CreateAccessToken(liveKitCfg, livekit.TokenRequest{
		Identity:          authCtx.User.ID,
		Name:              authCtx.User.DisplayName,
		Room:              room,
		CanPublish:        req.Publish,
		CanPublishSources: publishSources,
		CanSubscribe:      !req.Publish,
	})
	if err != nil {
		writeLiveKitError(w, err)
		return
	}
	publicURL, err := s.publicLiveKitURL(server, mediaNode, token.URL)
	if err != nil {
		writeError(w, http.StatusConflict, "insecure_media_node", err.Error())
		return
	}
	keyIndex, keyActive, mediaKeySlots := 0, true, false
	if server.EncryptionMode == "e2ee" {
		keyIndex, keyActive, mediaKeySlots = s.mediaKeyStatus(channelID, e2eeEpochID)
	}
	maxBitrateMbps := 0
	if req.Publish {
		maxBitrateMbps = server.ScreenShareBitrateLimits.BitrateMbps(req.Resolution, req.FPS)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"url":               publicURL,
		"token":             token.Token,
		"expires_at":        token.ExpiresAt,
		"room":              room,
		"server_id":         channel.ServerID,
		"channel_id":        channelID,
		"publisher_user_id": publisherUserID,
		"media_node_id":     mediaNodeID,
		"e2ee_required":     server.EncryptionMode == "e2ee",
		"e2ee_epoch_id":     e2eeEpochID,
		"e2ee_key_index":    keyIndex,
		"e2ee_key_active":   keyActive,
		"media_key_slots":   mediaKeySlots,
		"can_publish":       req.Publish,
		"max_bitrate_mbps":  maxBitrateMbps,
	})
}

func (s *Server) requireMediaE2EEAccess(w http.ResponseWriter, r *http.Request, authCtx authContext, channelID, deviceID, epochID string) (string, bool) {
	deviceID = strings.TrimSpace(deviceID)
	epochID = strings.TrimSpace(epochID)
	if !validE2EEDeviceID(deviceID) || epochID == "" {
		writeError(w, http.StatusBadRequest, "missing_media_e2ee_identity", "device_id and e2ee_epoch_id are required in e2ee mode")
		return "", false
	}
	owned, err := s.repo.IsDeviceOwnerOrAdmin(r.Context(), deviceID, authCtx.User.ID)
	if err != nil {
		writeResult(w, nil, err)
		return "", false
	}
	if !owned {
		writeError(w, http.StatusConflict, "e2ee_device_required", "an E2EE-capable device is required for media")
		return "", false
	}
	device, err := s.repo.GetDevice(r.Context(), deviceID)
	if err != nil {
		writeResult(w, nil, err)
		return "", false
	}
	if !store.ValidE2EEDeviceKeys(device.IdentityPublicKey, device.EnvelopePublicKey) {
		writeError(w, http.StatusConflict, "e2ee_device_required", "an E2EE-capable device is required for media")
		return "", false
	}
	epoch, err := s.repo.GetLatestEpoch(r.Context(), channelID)
	if err != nil {
		writeResult(w, nil, err)
		return "", false
	}
	if epoch.ID != epochID {
		writeError(w, http.StatusConflict, "epoch_changed", "channel media encryption epoch changed")
		return "", false
	}
	envelopes, err := s.repo.ListEnvelopes(r.Context(), deviceID, &channelID, true)
	if err != nil {
		writeResult(w, nil, err)
		return "", false
	}
	for _, envelope := range envelopes {
		if envelope.EpochID != nil && *envelope.EpochID == epoch.ID {
			return epoch.ID, true
		}
	}
	writeError(w, http.StatusConflict, "media_key_required", "current device has no media key for this epoch")
	return "", false
}

func (s *Server) publicLiveKitURL(server store.OSServer, mediaNode *store.MediaNode, configuredURL string) (string, error) {
	local := mediaNode == nil || s.isLocalLiveKitNode(*mediaNode, server.TLSIdentifier)
	if server.TLSStatus == "active" && local {
		return secureLiveKitURL(server.TLSIdentifier, s.cfg.TLS.SecurePublicPort), nil
	}
	if server.TLSStatus == "discovery" && local {
		if upstreamUsesPort(s.cfg.TLS.BackendUpstream, s.cfg.TLS.PlainPublicPort) {
			if directURL := plainLiveKitURL(server.TLSIdentifier, s.cfg.TLS.LiveKitUpstream); directURL != "" {
				return directURL, nil
			}
		}
		return strings.Replace(plainServerURL(server.TLSIdentifier, s.cfg.TLS.PlainPublicPort), "http://", "ws://", 1), nil
	}
	if server.TLSStatus == "active" && !secureEndpoint(configuredURL, "wss") {
		return "", errors.New("transport encryption requires WSS")
	}
	return configuredURL, nil
}

func validVoiceAudioBitrate(value int) bool {
	return value == 24 || value == 48 || value == 64 || value == 96 || value == 128
}

func (s *Server) handleChannelMessages(w http.ResponseWriter, r *http.Request, authCtx authContext, channelID string) {
	switch r.Method {
	case http.MethodGet:
		if !s.requireChannelAccess(w, r, authCtx, channelID) {
			return
		}
		if !s.requireChannelServerPermission(w, r, authCtx, channelID, store.PermissionChannelMessagesView) {
			return
		}
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		messages, err := s.repo.ListChannelMessages(r.Context(), channelID, limit)
		writeResult(w, messages, err)
	case http.MethodPost:
		if !s.requireChannelAccess(w, r, authCtx, channelID) {
			return
		}
		if !s.requireChannelServerPermission(w, r, authCtx, channelID, store.PermissionChannelMessagesSendText) {
			return
		}
		channel, err := s.repo.GetChannel(r.Context(), channelID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		server, err := s.repo.GetServer(r.Context(), channel.ServerID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		var req struct {
			SenderUserID   string            `json:"sender_user_id"`
			Kind           string            `json:"kind"`
			EncryptionMode string            `json:"encryption_mode"`
			EpochID        *string           `json:"epoch_id"`
			Body           string            `json:"body"`
			Nonce          string            `json:"nonce"`
			Metadata       map[string]string `json:"metadata"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		if req.Kind == "" {
			req.Kind = "text"
		}
		if req.Kind == "file" || req.Kind == "image" {
			writeError(w, http.StatusBadRequest, "multipart_upload_required", "images and files must use their channel upload endpoints")
			return
		}
		if !requireClientEncryptionMode(w, req.EncryptionMode, server.EncryptionMode) {
			return
		}
		epochID, nonce, ok := normalizeChannelEncryption(w, server.EncryptionMode, req.EpochID, req.Nonce)
		if !ok {
			return
		}
		if server.EncryptionMode == "e2ee" && !validE2EETextPayload(req.Body, nonce) {
			writeError(w, http.StatusBadRequest, "invalid_e2ee_payload", "e2ee text requires base64url AES-GCM ciphertext and a 12-byte nonce")
			return
		}
		msg, err := s.repo.StoreChannelMessage(r.Context(), store.ChannelMessage{
			ChannelID:      channelID,
			SenderUserID:   authCtx.User.ID,
			Kind:           req.Kind,
			EncryptionMode: server.EncryptionMode,
			EpochID:        epochID,
			Body:           req.Body,
			Nonce:          nonce,
			Metadata:       req.Metadata,
		})
		if errors.Is(err, store.ErrEncryptionMode) {
			writeError(w, http.StatusConflict, "encryption_mode_changed", "server encryption mode changed; retry the message")
			return
		}
		if errors.Is(err, store.ErrEpochConflict) {
			writeError(w, http.StatusConflict, "epoch_changed", "channel encryption epoch changed; refresh keys and retry")
			return
		}
		if err == nil {
			s.hub.Publish(realtime.Event{Type: "channel.message_created", ServerID: channel.ServerID, ChannelID: channelID, Payload: map[string]any{"message_id": msg.ID, "kind": msg.Kind}})
		}
		writeResult(w, msg, err)
	default:
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	}
}

func (s *Server) handleChannelImageUpload(w http.ResponseWriter, r *http.Request, authCtx authContext, channelID string) {
	if !s.requireChannelAccess(w, r, authCtx, channelID) {
		return
	}
	if !s.requireChannelServerPermission(w, r, authCtx, channelID, store.PermissionChannelMessagesSendImage) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxAttachmentImageSize+(1<<20))
	if err := r.ParseMultipartForm((128 << 20) + (1 << 20)); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_multipart", "invalid multipart form")
		return
	}
	channel, err := s.repo.GetChannel(r.Context(), channelID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	serverID := channel.ServerID
	if requestedServerID := r.FormValue("server_id"); requestedServerID != "" && requestedServerID != serverID {
		writeError(w, http.StatusBadRequest, "channel_server_mismatch", "channel does not belong to server")
		return
	}
	server, err := s.repo.GetServer(r.Context(), serverID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if !requireClientEncryptionMode(w, r.FormValue("encryption_mode"), server.EncryptionMode) {
		return
	}
	epochID := r.FormValue("epoch_id")
	nonce := r.FormValue("nonce")
	epoch, normalizedNonce, ok := normalizeChannelEncryption(w, server.EncryptionMode, optionalString(epochID), nonce)
	if !ok {
		return
	}
	fileHandle, header, err := r.FormFile("image")
	if err != nil {
		writeError(w, http.StatusBadRequest, "missing_image", "image is required")
		return
	}
	_ = fileHandle.Close()
	plaintextSize, _ := strconv.ParseInt(strings.TrimSpace(r.FormValue("plaintext_size_bytes")), 10, 64)
	chunkSize, _ := strconv.ParseInt(strings.TrimSpace(r.FormValue("chunk_size")), 10, 64)
	format := strings.TrimSpace(r.FormValue("attachment_format"))
	if !validateAttachmentEncryption(w, server.EncryptionMode, normalizedNonce, header.Size, plaintextSize, format, chunkSize, maxAttachmentImageSize) {
		return
	}
	result, err := files.SaveMultipart(server.FileRoot, serverID, "channel-images", header, r.FormValue("original_name"))
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	file, err := s.repo.StoreFile(r.Context(), store.StoredFile{
		ServerID:       serverID,
		ChannelID:      &channelID,
		UploaderUserID: authCtx.User.ID,
		Kind:           "channel_image",
		OriginalName:   result.OriginalName,
		ContentType:    result.ContentType,
		SizeBytes:      result.SizeBytes,
		SHA256Hex:      result.SHA256Hex,
		RelativePath:   result.RelativePath,
		EncryptionMode: server.EncryptionMode,
		Metadata:       attachmentEncryptionMetadata(server.EncryptionMode, normalizedNonce, plaintextSize, format, chunkSize),
	})
	if err != nil {
		_ = os.Remove(filepath.Join(server.FileRoot, filepath.FromSlash(result.RelativePath)))
		writeResult(w, nil, err)
		return
	}
	msg, err := s.repo.StoreChannelMessage(r.Context(), store.ChannelMessage{
		ChannelID:      channelID,
		SenderUserID:   authCtx.User.ID,
		Kind:           "image",
		EncryptionMode: server.EncryptionMode,
		EpochID:        epoch,
		Body:           file.ID,
		Nonce:          normalizedNonce,
		Metadata:       channelAttachmentMessageMetadata(file, plaintextSize, format, chunkSize),
	})
	if err != nil {
		_ = s.CleanupRetainedFile(context.Background(), file)
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
		s.hub.Publish(realtime.Event{Type: "channel.message_created", ServerID: serverID, ChannelID: channelID, Payload: map[string]any{"message_id": msg.ID, "kind": "image"}})
	}
	writeResult(w, map[string]any{"file": file, "message": msg}, err)
}

func (s *Server) handleChannelFileUpload(w http.ResponseWriter, r *http.Request, authCtx authContext, channelID string) {
	if !s.requireChannelAccess(w, r, authCtx, channelID) {
		return
	}
	if !s.requireChannelServerPermission(w, r, authCtx, channelID, store.PermissionChannelMessagesSendFile) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxLocalAttachmentFileSize+(1<<20))
	if err := r.ParseMultipartForm(256 << 20); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_multipart", "invalid multipart form")
		return
	}
	channel, err := s.repo.GetChannel(r.Context(), channelID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if requestedServerID := r.FormValue("server_id"); requestedServerID != "" && requestedServerID != channel.ServerID {
		writeError(w, http.StatusBadRequest, "channel_server_mismatch", "channel does not belong to server")
		return
	}
	server, err := s.repo.GetServer(r.Context(), channel.ServerID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if !requireClientEncryptionMode(w, r.FormValue("encryption_mode"), server.EncryptionMode) {
		return
	}
	epoch, nonce, ok := normalizeChannelEncryption(w, server.EncryptionMode, optionalString(r.FormValue("epoch_id")), r.FormValue("nonce"))
	if !ok {
		return
	}
	fileHandle, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "missing_file", "file is required")
		return
	}
	_ = fileHandle.Close()
	plaintextSize, _ := strconv.ParseInt(strings.TrimSpace(r.FormValue("plaintext_size_bytes")), 10, 64)
	chunkSize, _ := strconv.ParseInt(strings.TrimSpace(r.FormValue("chunk_size")), 10, 64)
	format := strings.TrimSpace(r.FormValue("attachment_format"))
	if !validateAttachmentEncryption(w, server.EncryptionMode, nonce, header.Size, plaintextSize, format, chunkSize, maxLocalAttachmentFileSize) {
		return
	}
	result, err := files.SaveMultipart(server.FileRoot, channel.ServerID, "channel-files", header, r.FormValue("original_name"))
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	file, err := s.repo.StoreFile(r.Context(), store.StoredFile{
		ServerID:       channel.ServerID,
		ChannelID:      &channelID,
		UploaderUserID: authCtx.User.ID,
		Kind:           "channel_file",
		OriginalName:   result.OriginalName,
		ContentType:    result.ContentType,
		SizeBytes:      result.SizeBytes,
		SHA256Hex:      result.SHA256Hex,
		RelativePath:   result.RelativePath,
		EncryptionMode: server.EncryptionMode,
		Metadata:       attachmentEncryptionMetadata(server.EncryptionMode, nonce, plaintextSize, format, chunkSize),
	})
	if err != nil {
		_ = os.Remove(filepath.Join(server.FileRoot, filepath.FromSlash(result.RelativePath)))
		writeResult(w, nil, err)
		return
	}
	msg, err := s.repo.StoreChannelMessage(r.Context(), store.ChannelMessage{
		ChannelID:      channelID,
		SenderUserID:   authCtx.User.ID,
		Kind:           "file",
		EncryptionMode: server.EncryptionMode,
		EpochID:        epoch,
		Body:           file.ID,
		Nonce:          nonce,
		Metadata:       channelAttachmentMessageMetadata(file, plaintextSize, format, chunkSize),
	})
	if err != nil {
		_ = s.CleanupRetainedFile(context.Background(), file)
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
		s.hub.Publish(realtime.Event{Type: "channel.message_created", ServerID: channel.ServerID, ChannelID: channelID, Payload: map[string]any{"message_id": msg.ID, "kind": "file"}})
	}
	writeResult(w, map[string]any{"file": file, "message": msg}, err)
}

func (s *Server) handleE2EE(w http.ResponseWriter, r *http.Request, authCtx authContext, parts []string) {
	if len(parts) != 1 {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}
	if parts[0] == "key-requests" || parts[0] == "media-key-requests" {
		s.handleE2EEKeyRequest(w, r, authCtx, parts[0] == "media-key-requests")
		return
	}
	if parts[0] == "direct-devices" {
		s.handleDirectE2EEDevices(w, r, authCtx)
		return
	}
	if parts[0] == "media-key-ready" {
		s.handleE2EEMediaKeyReady(w, r, authCtx)
		return
	}
	if parts[0] != "envelopes" && parts[0] != "media-envelopes" {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}
	media := parts[0] == "media-envelopes"
	permission := store.PermissionChannelMessagesView
	if media {
		permission = store.PermissionVoiceJoin
	}
	switch r.Method {
	case http.MethodGet:
		deviceID := r.URL.Query().Get("recipient_device_id")
		channelID := strings.TrimSpace(r.URL.Query().Get("channel_id"))
		if deviceID == "" || channelID == "" {
			writeError(w, http.StatusBadRequest, "missing_envelope_scope", "recipient_device_id and channel_id are required")
			return
		}
		ok, err := s.repo.IsDeviceOwnerOrAdmin(r.Context(), deviceID, authCtx.User.ID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		if !ok {
			writeError(w, http.StatusForbidden, "forbidden", "cannot read envelopes for another device")
			return
		}
		if !s.requireChannelAccess(w, r, authCtx, channelID) ||
			!s.requireChannelServerPermission(w, r, authCtx, channelID, permission) {
			return
		}
		envelopes, err := s.repo.ListEnvelopes(r.Context(), deviceID, &channelID, media)
		writeResult(w, envelopes, err)
	case http.MethodPost:
		var req struct {
			ChannelID      string              `json:"channel_id"`
			EpochID        string              `json:"epoch_id"`
			SenderDeviceID string              `json:"sender_device_id"`
			Envelopes      []store.KeyEnvelope `json:"envelopes"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		req.ChannelID = strings.TrimSpace(req.ChannelID)
		req.EpochID = strings.TrimSpace(req.EpochID)
		req.SenderDeviceID = strings.TrimSpace(req.SenderDeviceID)
		if req.ChannelID == "" || req.EpochID == "" || req.SenderDeviceID == "" || len(req.Envelopes) == 0 || len(req.Envelopes) > 256 {
			writeError(w, http.StatusBadRequest, "invalid_envelope_batch", "channel_id, epoch_id, sender_device_id and envelopes are required")
			return
		}
		if !s.requireChannelAccess(w, r, authCtx, req.ChannelID) ||
			!s.requireChannelServerPermission(w, r, authCtx, req.ChannelID, permission) {
			return
		}
		for _, envelope := range req.Envelopes {
			if envelope.Algorithm != "openspeak-envelope-v1" || envelope.RecipientUserID == "" || envelope.RecipientDeviceID == "" || len(envelope.Ciphertext) == 0 || len(envelope.Ciphertext) > 65536 {
				writeError(w, http.StatusBadRequest, "invalid_envelope", "invalid recipient, algorithm, or ciphertext")
				return
			}
		}
		envelopes, err := s.repo.StoreEnvelopeBatch(r.Context(), req.ChannelID, req.EpochID, req.SenderDeviceID, authCtx.User.ID, req.Envelopes, media)
		switch {
		case errors.Is(err, store.ErrEpochConflict), errors.Is(err, store.ErrEnvelopeConflict):
			writeError(w, http.StatusConflict, "envelope_conflict", err.Error())
			return
		case errors.Is(err, store.ErrEnvelopeInvalid):
			writeError(w, http.StatusBadRequest, "invalid_envelope_batch", err.Error())
			return
		case errors.Is(err, store.ErrEnvelopeDenied):
			writeError(w, http.StatusForbidden, "forbidden", err.Error())
			return
		case err != nil:
			writeResult(w, nil, err)
			return
		}
		eventType := "e2ee.envelope_created"
		if media {
			eventType = "e2ee.media_envelope_created"
		}
		for _, envelope := range envelopes {
			s.hub.Publish(realtime.Event{Type: eventType, ToUser: envelope.RecipientUserID, ChannelID: req.ChannelID, Payload: map[string]any{"envelope_id": envelope.ID, "epoch_id": req.EpochID}})
		}
		writeJSON(w, http.StatusOK, envelopes)
	default:
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	}
}

func (s *Server) handleE2EEMediaKeyReady(w http.ResponseWriter, r *http.Request, authCtx authContext) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	var req struct {
		ChannelID string `json:"channel_id"`
		EpochID   string `json:"epoch_id"`
		DeviceID  string `json:"device_id"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	req.ChannelID = strings.TrimSpace(req.ChannelID)
	req.EpochID = strings.TrimSpace(req.EpochID)
	req.DeviceID = strings.TrimSpace(req.DeviceID)
	if req.ChannelID == "" || req.EpochID == "" || !validE2EEDeviceID(req.DeviceID) {
		writeError(w, http.StatusBadRequest, "invalid_media_key_ready", "channel_id, epoch_id and device_id are required")
		return
	}
	if !s.requireChannelAccess(w, r, authCtx, req.ChannelID) ||
		!s.requireChannelServerPermission(w, r, authCtx, req.ChannelID, store.PermissionVoiceJoin) {
		return
	}
	owned, err := s.repo.IsDeviceOwnerOrAdmin(r.Context(), req.DeviceID, authCtx.User.ID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if !owned {
		writeError(w, http.StatusForbidden, "forbidden", "cannot mark another device's media key ready")
		return
	}
	channel, err := s.repo.GetChannel(r.Context(), req.ChannelID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	server, err := s.repo.GetServer(r.Context(), channel.ServerID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if server.EncryptionMode != "e2ee" {
		writeError(w, http.StatusConflict, "encryption_mode_changed", "media key slots are available only in e2ee mode")
		return
	}
	current, ok := s.hub.CurrentChannel(channel.ServerID, authCtx.User.ID)
	if !ok || current.ChannelID != req.ChannelID {
		writeError(w, http.StatusConflict, "current_channel_required", "enter the channel before marking its media key ready")
		return
	}
	epoch, err := s.repo.GetLatestEpoch(r.Context(), req.ChannelID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if epoch.ID != req.EpochID {
		writeError(w, http.StatusConflict, "epoch_changed", "channel media encryption epoch changed")
		return
	}
	devices, err := s.repo.ListChannelDevices(r.Context(), req.ChannelID, epoch.ID, true)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	eligible := make(map[string]bool, len(devices))
	deviceReady := false
	for _, device := range devices {
		eligible[device.UserID] = true
		if device.ID == req.DeviceID && device.UserID == authCtx.User.ID && device.HasEnvelope {
			deviceReady = true
		}
	}
	if !deviceReady {
		writeError(w, http.StatusConflict, "media_key_required", "current device has no media key for this epoch")
		return
	}
	keyIndex, activated, slots := s.markMediaKeyReady(channel.ServerID, req.ChannelID, req.EpochID, authCtx.User.ID, eligible)
	writeJSON(w, http.StatusOK, map[string]any{
		"key_index":       keyIndex,
		"activated":       activated,
		"media_key_slots": slots,
	})
}

func (s *Server) handleDirectE2EEDevices(w http.ResponseWriter, r *http.Request, authCtx authContext) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	serverID := strings.TrimSpace(r.URL.Query().Get("server_id"))
	toUserID := strings.TrimSpace(r.URL.Query().Get("to_user_id"))
	if serverID == "" || toUserID == "" || toUserID == authCtx.User.ID {
		writeError(w, http.StatusBadRequest, "invalid_direct_peer", "server_id and another to_user_id are required")
		return
	}
	server, err := s.repo.GetServer(r.Context(), serverID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if server.EncryptionMode != "e2ee" {
		writeError(w, http.StatusConflict, "encryption_mode_changed", "direct E2EE devices are available only in e2ee mode")
		return
	}
	devices, ok := s.hub.DirectDevices(serverID, authCtx.User.ID, toUserID)
	if !ok {
		writeError(w, http.StatusConflict, "e2ee_device_unavailable", "both users must be online with E2EE-capable devices")
		return
	}
	writeJSON(w, http.StatusOK, devices)
}

func (s *Server) handleE2EEKeyRequest(w http.ResponseWriter, r *http.Request, authCtx authContext, media bool) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	var req struct {
		ChannelID         string `json:"channel_id"`
		EpochID           string `json:"epoch_id"`
		RecipientDeviceID string `json:"recipient_device_id"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	req.ChannelID = strings.TrimSpace(req.ChannelID)
	req.EpochID = strings.TrimSpace(req.EpochID)
	req.RecipientDeviceID = strings.TrimSpace(req.RecipientDeviceID)
	if req.ChannelID == "" || req.EpochID == "" || req.RecipientDeviceID == "" {
		writeError(w, http.StatusBadRequest, "invalid_key_request", "channel_id, epoch_id and recipient_device_id are required")
		return
	}
	permission := store.PermissionChannelMessagesView
	if media {
		permission = store.PermissionVoiceJoin
	}
	if !s.requireChannelAccess(w, r, authCtx, req.ChannelID) ||
		!s.requireChannelServerPermission(w, r, authCtx, req.ChannelID, permission) {
		return
	}
	owned, err := s.repo.IsDeviceOwnerOrAdmin(r.Context(), req.RecipientDeviceID, authCtx.User.ID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if !owned {
		writeError(w, http.StatusForbidden, "forbidden", "cannot request a key for another device")
		return
	}
	epoch, err := s.repo.GetLatestEpoch(r.Context(), req.ChannelID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if epoch.ID != req.EpochID {
		writeError(w, http.StatusConflict, "epoch_changed", "channel encryption epoch changed")
		return
	}
	devices, err := s.repo.ListChannelDevices(r.Context(), req.ChannelID, epoch.ID, media)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	eligible := false
	for _, device := range devices {
		if device.ID == req.RecipientDeviceID && !device.HasEnvelope {
			eligible = true
			break
		}
	}
	if !eligible {
		writeError(w, http.StatusConflict, "key_not_required", "device is not eligible or already has the channel key")
		return
	}
	channel, err := s.repo.GetChannel(r.Context(), req.ChannelID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if authCtx.Claims.OwnerServerID == channel.ServerID && authCtx.Claims.OwnerDeviceID != "" {
		keyHolderOnline := false
		for _, device := range devices {
			if device.HasEnvelope && s.hub.DeviceOnlineInServer(channel.ServerID, device.ID) {
				keyHolderOnline = true
				break
			}
		}
		if !keyHolderOnline {
			created, err := s.repo.CreateEpoch(r.Context(), channel.ID, "owner_key_recovery")
			if err != nil {
				writeResult(w, nil, err)
				return
			}
			s.beginMediaKeyTransition(r.Context(), channel.ServerID, created)
			s.hub.Publish(realtime.Event{
				Type: "channel.epoch_changed", ServerID: channel.ServerID, ChannelID: channel.ID,
				Payload: map[string]any{"epoch": created},
			})
			writeError(w, http.StatusConflict, "key_not_required", "channel encryption epoch changed for owner key recovery")
			return
		}
	}
	notified := map[string]bool{}
	for _, device := range devices {
		if !device.HasEnvelope || notified[device.UserID] {
			continue
		}
		notified[device.UserID] = true
		eventType := "e2ee.key_requested"
		if media {
			eventType = "e2ee.media_key_requested"
		}
		s.hub.Publish(realtime.Event{
			Type: eventType, ServerID: channel.ServerID, ChannelID: channel.ID,
			ToUser:  device.UserID,
			Payload: map[string]any{"epoch_id": epoch.ID, "recipient_device_id": req.RecipientDeviceID},
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"requested": true})
}

func (s *Server) handleFiles(w http.ResponseWriter, r *http.Request, authCtx authContext, parts []string) {
	if len(parts) != 2 || parts[1] != "download" || r.Method != http.MethodGet {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}
	file, err := s.repo.GetFile(r.Context(), parts[0])
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if file.ChannelID == nil {
		writeError(w, http.StatusNotFound, "not_found", "file not found")
		return
	}
	if !s.requireChannelAccess(w, r, authCtx, *file.ChannelID) {
		return
	}
	if !s.requireServerPermission(w, r, authCtx, file.ServerID, store.PermissionChannelAttachmentsDownload) {
		return
	}
	server, err := s.repo.GetServer(r.Context(), file.ServerID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if file.FileNodeID != nil && file.ObjectKey != "" {
		node, err := s.repo.GetFileNode(r.Context(), file.ServerID, *file.FileNodeID)
		if err != nil {
			writeError(w, http.StatusBadGateway, "file_node_unavailable", "attachment file node is unavailable")
			return
		}
		if !secureEndpoint(node.BaseURL, "https") {
			writeError(w, http.StatusConflict, "insecure_file_node", "external attachment nodes require HTTPS")
			return
		}
		downloadURL, err := externalObjectURL(node, file.ObjectKey, "get", file.OriginalName, file.ContentType, file.SizeBytes, externalDownloadTTL(r))
		if err != nil {
			writeError(w, http.StatusBadGateway, "file_node_unavailable", "attachment file node configuration is invalid")
			return
		}
		if r.URL.Query().Get("external_url") == "1" {
			w.Header().Set("Cache-Control", "no-store")
			writeJSON(w, http.StatusOK, map[string]string{"url": downloadURL})
			return
		}
		http.Redirect(w, r, downloadURL, http.StatusTemporaryRedirect)
		return
	}
	if r.URL.Query().Get("external_url") == "1" {
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, http.StatusOK, map[string]string{"url": ""})
		return
	}
	absPath := filepath.Join(server.FileRoot, filepath.FromSlash(file.RelativePath))
	if !strings.HasPrefix(absPath, filepath.Clean(server.FileRoot)+string(filepath.Separator)) {
		writeError(w, http.StatusBadRequest, "invalid_file_path", "invalid file path")
		return
	}
	w.Header().Set("Content-Type", file.ContentType)
	w.Header().Set("Content-Disposition", attachmentContentDisposition(file.OriginalName))
	disableDownloadWriteTimeout(w)
	http.ServeFile(w, r, absPath)
}

func disableDownloadWriteTimeout(w http.ResponseWriter) {
	err := http.NewResponseController(w).SetWriteDeadline(time.Time{})
	if err != nil && !errors.Is(err, http.ErrNotSupported) {
		slog.Warn("failed to disable download write timeout", "error", err)
	}
}

func normalizeChannelEncryption(w http.ResponseWriter, mode string, epochID *string, nonce string) (*string, string, bool) {
	if mode != "e2ee" {
		return nil, "", true
	}
	if epochID == nil || strings.TrimSpace(*epochID) == "" || strings.TrimSpace(nonce) == "" {
		writeError(w, http.StatusBadRequest, "missing_e2ee_metadata", "epoch_id and nonce are required in e2ee mode")
		return nil, "", false
	}
	trimmedEpoch := strings.TrimSpace(*epochID)
	return &trimmedEpoch, strings.TrimSpace(nonce), true
}

func requireClientEncryptionMode(w http.ResponseWriter, requested, current string) bool {
	if requested == current {
		return true
	}
	writeError(w, http.StatusConflict, "encryption_mode_changed", "服务器加密模式已变化，请重新连接后重试")
	return false
}

func optionalString(value string) *string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	value = strings.TrimSpace(value)
	return &value
}

func (s *Server) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	authCtx, ok := s.authFromRequest(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized", "missing or invalid token")
		return
	}
	userID := authCtx.User.ID
	deviceID := r.URL.Query().Get("device_id")
	serverID := r.URL.Query().Get("server_id")
	if deviceID == "" {
		writeError(w, http.StatusBadRequest, "missing_identity", "device_id is required")
		return
	}
	ok, err := s.repo.IsDeviceOwnerOrAdmin(r.Context(), deviceID, userID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden", "device does not belong to current user")
		return
	}
	registeredDevice, err := s.repo.GetDevice(r.Context(), deviceID)
	if err != nil {
		writeResult(w, nil, err)
		return
	}
	if serverID != "" {
		server, err := s.repo.GetServer(r.Context(), serverID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		if server.EncryptionMode == "e2ee" &&
			!store.ValidE2EEDeviceKeys(registeredDevice.IdentityPublicKey, registeredDevice.EnvelopePublicKey) {
			writeError(w, http.StatusConflict, "e2ee_device_required", "an E2EE-capable device is required for this server")
			return
		}
		if _, banned, err := s.repo.IsServerUserBanned(r.Context(), serverID, userID); err != nil {
			writeResult(w, nil, err)
			return
		} else if banned {
			writeError(w, http.StatusForbidden, "server_banned", "你已被此服务器封禁")
			return
		}
		ok, err := s.repo.IsServerMember(r.Context(), serverID, userID)
		if err != nil {
			writeResult(w, nil, err)
			return
		}
		if !ok {
			writeError(w, http.StatusForbidden, "forbidden", "server membership required")
			return
		}
	}
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	_ = s.repo.TouchDevice(r.Context(), deviceID)
	s.hub.Attach(conn, userID, authCtx.User.DisplayName, realtime.DirectDevice{
		ID: registeredDevice.ID, UserID: registeredDevice.UserID,
		IdentityPublicKey: registeredDevice.IdentityPublicKey,
		EnvelopePublicKey: registeredDevice.EnvelopePublicKey,
	}, authCtx.Claims.OwnerDeviceID, serverID, authCtx.Claims.ClientType)
}

func (s *Server) requireAuth(w http.ResponseWriter, r *http.Request) (authContext, bool) {
	ctx, ok := s.authFromRequest(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized", "missing or invalid token")
		return authContext{}, false
	}
	return ctx, true
}

func (s *Server) authFromRequest(r *http.Request) (authContext, bool) {
	token := bearerToken(r.Header.Get("Authorization"))
	if token == "" {
		token = r.URL.Query().Get("token")
	}
	claims, err := auth.ParseToken(s.cfg.JWTSecret, token)
	if err != nil {
		return authContext{}, false
	}
	if claims.ClientType == "web" {
		settings, settingsErr := s.repo.GetWebSettings(r.Context())
		if settingsErr != nil || !settings.Enabled || settings.Generation != claims.WebGeneration {
			return authContext{}, false
		}
	}
	user, err := s.repo.GetUser(r.Context(), claims.Subject)
	if err != nil {
		return authContext{}, false
	}
	if security, ownerErr := s.repo.FindOwnerSecurityByUser(r.Context(), user.ID); ownerErr == nil {
		if claims.ClientType == "web" {
			return authContext{}, false
		}
		if !security.Claimed {
			// Recovery revokes every owner token, but the owner user still needs
			// an ordinary login session to use the new one-time claim key.
			if claims.OwnerServerID != "" || claims.OwnerDeviceID != "" {
				return authContext{}, false
			}
		} else {
			if claims.OwnerServerID != security.ServerID ||
				claims.OwnerDeviceID == "" ||
				claims.OwnerGeneration != security.AuthGeneration {
				return authContext{}, false
			}
			if _, err := s.repo.ValidateOwnerSession(
				r.Context(),
				security.ServerID,
				user.ID,
				claims.OwnerDeviceID,
				claims.OwnerGeneration,
				claims.OwnerSessionGeneration,
			); err != nil {
				return authContext{}, false
			}
			if strings.TrimSpace(claims.DisplayName) != "" {
				user.DisplayName = strings.TrimSpace(claims.DisplayName)
			}
		}
	} else if ownerErr != nil && !errors.Is(ownerErr, store.ErrNotFound) {
		return authContext{}, false
	}
	return authContext{User: user, Claims: claims}, true
}

func (s *Server) requireServerOwner(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) bool {
	if !s.requireNotBanned(w, r, authCtx, serverID) {
		return false
	}
	ok, err := s.repo.IsServerOwnerOrAdmin(r.Context(), serverID, authCtx.User.ID)
	if err != nil {
		writeResult(w, nil, err)
		return false
	}
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden", "server owner or admin role required")
		return false
	}
	return true
}

func (s *Server) requireServerPermission(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string, permission string) bool {
	if !s.requireNotBanned(w, r, authCtx, serverID) {
		return false
	}
	ok, err := s.repo.IsServerOwnerOrHasPermission(r.Context(), serverID, authCtx.User.ID, permission)
	if err != nil {
		writeResult(w, nil, err)
		return false
	}
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden", "server permission required: "+permission)
		return false
	}
	return true
}

func (s *Server) audit(ctx context.Context, serverID, actorUserID, action, targetID string, metadata map[string]string) {
	if _, err := s.repo.CreateAuditLog(ctx, store.AuditLog{
		ServerID: serverID, ActorUserID: actorUserID, Action: action,
		TargetID: targetID, Metadata: metadata,
	}); err != nil {
		slog.Error("failed to write audit log", "server_id", serverID, "action", action, "error", err)
	}
}

func (s *Server) requireServerAccess(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) bool {
	if !s.requireNotBanned(w, r, authCtx, serverID) {
		return false
	}
	ok, err := s.repo.IsServerMember(r.Context(), serverID, authCtx.User.ID)
	if err != nil {
		writeResult(w, nil, err)
		return false
	}
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden", "server membership required")
		return false
	}
	return true
}

func (s *Server) requireNotBanned(w http.ResponseWriter, r *http.Request, authCtx authContext, serverID string) bool {
	ban, banned, err := s.repo.IsServerUserBanned(r.Context(), serverID, authCtx.User.ID)
	if err != nil {
		writeResult(w, nil, err)
		return false
	}
	if !banned {
		return true
	}
	message := "你已被此服务器封禁"
	if strings.TrimSpace(ban.Reason) != "" {
		message += "：" + strings.TrimSpace(ban.Reason)
	}
	writeError(w, http.StatusForbidden, "server_banned", message)
	return false
}

func (s *Server) requireChannelServerOwner(w http.ResponseWriter, r *http.Request, authCtx authContext, channelID string) bool {
	channel, err := s.repo.GetChannel(r.Context(), channelID)
	if err != nil {
		writeResult(w, nil, err)
		return false
	}
	if !s.requireNotBanned(w, r, authCtx, channel.ServerID) {
		return false
	}
	ok, err := s.repo.IsChannelServerOwnerOrAdmin(r.Context(), channelID, authCtx.User.ID)
	if err != nil {
		writeResult(w, nil, err)
		return false
	}
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden", "server owner or admin role required")
		return false
	}
	return true
}

func (s *Server) requireChannelServerPermission(w http.ResponseWriter, r *http.Request, authCtx authContext, channelID string, permission string) bool {
	channel, err := s.repo.GetChannel(r.Context(), channelID)
	if err != nil {
		writeResult(w, nil, err)
		return false
	}
	if !s.requireNotBanned(w, r, authCtx, channel.ServerID) {
		return false
	}
	ok, err := s.repo.IsChannelServerOwnerOrHasPermission(r.Context(), channelID, authCtx.User.ID, permission)
	if err != nil {
		writeResult(w, nil, err)
		return false
	}
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden", "server permission required: "+permission)
		return false
	}
	return true
}

func (s *Server) requireChannelAccess(w http.ResponseWriter, r *http.Request, authCtx authContext, channelID string) bool {
	channel, err := s.repo.GetChannel(r.Context(), channelID)
	if err != nil {
		writeResult(w, nil, err)
		return false
	}
	if !s.requireNotBanned(w, r, authCtx, channel.ServerID) {
		return false
	}
	ok, err := s.repo.IsChannelMemberOrOwnerOrAdmin(r.Context(), channelID, authCtx.User.ID)
	if err != nil {
		writeResult(w, nil, err)
		return false
	}
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden", "channel membership required")
		return false
	}
	return true
}

func splitPath(path string) []string {
	path = strings.Trim(path, "/")
	if path == "" {
		return nil
	}
	return strings.Split(path, "/")
}

func bearerToken(header string) string {
	const prefix = "Bearer "
	if strings.HasPrefix(header, prefix) {
		return strings.TrimSpace(strings.TrimPrefix(header, prefix))
	}
	return ""
}

func validClientInstallationID(value string) bool {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return false
	}
	for index, char := range value {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			continue
		}
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')) {
			return false
		}
	}
	return true
}

func validE2EEDeviceID(value string) bool {
	return strings.HasPrefix(value, "dev_") && len(value) >= 20 && len(value) <= 64
}

func validE2EETextPayload(body, nonce string) bool {
	nonceBytes, nonceErr := base64.RawURLEncoding.DecodeString(nonce)
	bodyBytes, bodyErr := base64.RawURLEncoding.DecodeString(body)
	return nonceErr == nil && len(nonceBytes) == 12 && bodyErr == nil && len(bodyBytes) >= 16
}

func sanitizeHeaderFilename(name string) string {
	name = strings.ReplaceAll(name, `"`, "_")
	name = strings.ReplaceAll(name, "\r", "_")
	name = strings.ReplaceAll(name, "\n", "_")
	if name == "" {
		return "download"
	}
	return name
}

func attachmentContentDisposition(name string) string {
	fallback := sanitizeHeaderFilename(files.SanitizeName(name))
	encoded := url.PathEscape(files.OriginalName(name))
	return `attachment; filename="` + fallback + `"; filename*=UTF-8''` + encoded
}

func liveKitRoomName(serverID, channelID string) string {
	return "openspeak_" + serverID + "_" + channelID
}

func liveKitServerRoomName(serverID string) string {
	return "openspeak_" + serverID
}

func liveKitScreenShareRoomName(serverID, channelID, publisherUserID string) string {
	return "openspeak_screen_" + serverID + "_" + channelID + "_" + publisherUserID
}

func decodeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	defer r.Body.Close()
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return false
	}
	return true
}

func writeResult(w http.ResponseWriter, value any, err error) {
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "resource not found")
			return
		}
		slog.Error("request failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "internal server error")
		return
	}
	writeJSON(w, http.StatusOK, value)
}

func writeLiveKitError(w http.ResponseWriter, err error) {
	if errors.Is(err, livekit.ErrNotConfigured) {
		writeError(w, http.StatusServiceUnavailable, "livekit_not_configured", "LiveKit is not configured")
		return
	}
	if errors.Is(err, livekit.ErrInvalidTokenRequest) {
		writeError(w, http.StatusBadRequest, "invalid_livekit_request", err.Error())
		return
	}
	slog.Error("livekit request failed", "error", err)
	writeError(w, http.StatusInternalServerError, "livekit_error", "failed to create LiveKit token")
}

func liveKitConfigFromMediaNode(node store.MediaNode, tokenTTL time.Duration) config.LiveKitConfig {
	return config.LiveKitConfig{
		URL:       node.LiveKitURL,
		APIKey:    node.APIKey,
		APISecret: node.APISecret,
		TokenTTL:  tokenTTL,
	}
}

func trimOptionalString(value *string) *string {
	if value == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*value)
	return &trimmed
}

func validateMediaNodePatch(patch store.MediaNodePatch) error {
	if patch.Name != nil && *patch.Name == "" {
		return fmt.Errorf("name cannot be empty")
	}
	if patch.LiveKitURL != nil && *patch.LiveKitURL == "" {
		return fmt.Errorf("livekit_url cannot be empty")
	}
	if patch.APIKey != nil && *patch.APIKey == "" {
		return fmt.Errorf("api_key cannot be empty")
	}
	if patch.APISecret != nil && *patch.APISecret == "" {
		return fmt.Errorf("api_secret cannot be empty")
	}
	if patch.Weight != nil && *patch.Weight <= 0 {
		return fmt.Errorf("weight must be greater than 0")
	}
	if patch.MaxRelayBitrateKbps != nil && *patch.MaxRelayBitrateKbps < 0 {
		return fmt.Errorf("max_relay_bitrate_kbps cannot be negative")
	}
	if patch.MaxRooms != nil && *patch.MaxRooms < 0 {
		return fmt.Errorf("max_rooms cannot be negative")
	}
	return nil
}

func normalizeFileNodeURL(value string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(value))
	if err != nil || parsed.Host == "" || !strings.EqualFold(parsed.Scheme, "https") {
		return "", errors.New("invalid file node URL")
	}
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return strings.TrimRight(parsed.String(), "/"), nil
}

func validateScreenSharePolicy(policy store.ScreenSharePolicy) error {
	if policy.P2P.Enabled {
		return errors.New("p2p screen sharing is not available yet")
	}
	if err := validateScreenShareModePolicy("p2p", policy.P2P); err != nil {
		return err
	}
	if err := validateScreenShareModePolicy("relay", policy.Relay); err != nil {
		return err
	}
	return nil
}

func validateScreenShareModePolicy(name string, policy store.ScreenShareModePolicy) error {
	if len(policy.Allowed) != 9 {
		return fmt.Errorf("%s must expose all nine screen-share quality options", name)
	}
	seen := map[string]bool{}
	for _, capability := range policy.Allowed {
		if !validScreenResolution(capability.Resolution) {
			return fmt.Errorf("%s has unsupported resolution %q", name, capability.Resolution)
		}
		if !validScreenFPS(capability.FPS) {
			return fmt.Errorf("%s has unsupported fps %d", name, capability.FPS)
		}
		key := capability.Resolution + ":" + strconv.Itoa(capability.FPS)
		if seen[key] {
			return fmt.Errorf("%s has duplicate quality option %s", name, key)
		}
		seen[key] = true
	}
	return nil
}

func validScreenResolution(value string) bool {
	switch value {
	case "720p", "1080p", "source":
		return true
	default:
		return false
	}
}

func validScreenFPS(value int) bool {
	switch value {
	case 15, 30, 60:
		return true
	default:
		return false
	}
}

func normalizePermissions(values []string) ([]string, error) {
	if len(values) == 0 {
		return nil, nil
	}
	seen := map[string]bool{}
	permissions := []string{}
	for _, value := range values {
		if !validPermission(value) {
			return nil, fmt.Errorf("unsupported permission %q", value)
		}
		if seen[value] {
			continue
		}
		seen[value] = true
		permissions = append(permissions, value)
	}
	return permissions, nil
}

func validPermission(value string) bool {
	for _, permission := range store.DelegablePermissions() {
		if value == permission {
			return true
		}
	}
	return false
}

func permissionEnabled(permissions []string, wanted string) bool {
	for _, permission := range permissions {
		if permission == wanted {
			return true
		}
	}
	return false
}

func validateScreenShareQualityPermissions(role string, permissions []string) error {
	if !permissionEnabled(permissions, store.PermissionVoiceScreenShare) {
		return nil
	}
	hasResolution := permissionEnabled(permissions, store.PermissionVoiceScreenShareResolution720p) ||
		permissionEnabled(permissions, store.PermissionVoiceScreenShareResolution1080p) ||
		permissionEnabled(permissions, store.PermissionVoiceScreenShareResolutionSource)
	hasFPS := permissionEnabled(permissions, store.PermissionVoiceScreenShareFPS15) ||
		permissionEnabled(permissions, store.PermissionVoiceScreenShareFPS30) ||
		permissionEnabled(permissions, store.PermissionVoiceScreenShareFPS60)
	if !hasResolution || !hasFPS {
		return fmt.Errorf("%s screen sharing requires at least one resolution and one fps", role)
	}
	return nil
}

func (s *Server) enforceScreenSharePermissions(ctx context.Context, serverID string) {
	server, err := s.repo.GetServer(ctx, serverID)
	if err != nil {
		slog.Error("failed to load screen-share policy", "server_id", serverID, "error", err)
		return
	}
	for _, state := range s.hub.Snapshot(serverID).VoiceStates {
		if !state.ScreenSharing {
			continue
		}
		permissions, err := s.repo.EffectiveServerPermissions(ctx, serverID, state.UserID)
		if err != nil {
			slog.Error("failed to enforce screen-share permissions", "server_id", serverID, "user_id", state.UserID, "error", err)
			continue
		}
		if server.ScreenSharePolicy.Relay.Enabled &&
			permissionEnabled(permissions, store.PermissionVoiceScreenShare) &&
			store.ScreenShareQualityAllowed(permissions, state.ScreenShareResolution, state.ScreenShareFPS) {
			continue
		}
		state.ScreenSharing = false
		state.ScreenShareResolution = ""
		state.ScreenShareFPS = 0
		state.ScreenShareMediaNodeID = ""
		s.hub.SetVoiceState(state)
	}
}

func (s *Server) rotateServerChannelEpochs(ctx context.Context, serverID, reason string) error {
	server, err := s.repo.GetServer(ctx, serverID)
	if err != nil {
		return err
	}
	if server.EncryptionMode != "e2ee" {
		return nil
	}
	epochs, err := s.repo.RotateServerChannelEpochs(ctx, serverID, reason)
	if err != nil {
		return err
	}
	for _, epoch := range epochs {
		s.beginMediaKeyTransition(ctx, serverID, epoch)
		s.hub.Publish(realtime.Event{
			Type: "channel.epoch_changed", ServerID: serverID, ChannelID: epoch.ChannelID,
			Payload: map[string]any{"epoch": epoch},
		})
	}
	return nil
}

func mediaKeyClientID(serverID, userID string) string {
	return serverID + "\x00" + userID
}

func (s *Server) recordMediaKeyClient(serverID, userID string, supported bool) {
	s.mediaKeyMu.Lock()
	defer s.mediaKeyMu.Unlock()
	key := mediaKeyClientID(serverID, userID)
	if supported {
		s.mediaKeyClients[key] = true
	} else {
		delete(s.mediaKeyClients, key)
	}
}

func (s *Server) beginMediaKeyTransition(ctx context.Context, serverID string, epoch store.ChannelEpoch) bool {
	devices, err := s.repo.ListChannelDevices(ctx, epoch.ChannelID, epoch.ID, true)
	if err != nil {
		return false
	}
	eligible := make(map[string]bool, len(devices))
	for _, device := range devices {
		eligible[device.UserID] = true
	}
	expected := s.mediaKeyExpectedUsers(serverID, epoch.ChannelID, eligible)

	s.mediaKeyMu.Lock()
	defer s.mediaKeyMu.Unlock()
	for userID := range expected {
		if !s.mediaKeyClients[mediaKeyClientID(serverID, userID)] {
			delete(s.mediaKeys, epoch.ChannelID)
			return false
		}
	}
	activeIndex := 0
	if current := s.mediaKeys[epoch.ChannelID]; current != nil {
		if current.Activated {
			activeIndex = current.KeyIndex
		} else {
			activeIndex = 1 - current.KeyIndex
		}
	}
	s.mediaKeys[epoch.ChannelID] = &mediaKeyTransition{
		ServerID:   serverID,
		ChannelID:  epoch.ChannelID,
		EpochID:    epoch.ID,
		KeyIndex:   1 - activeIndex,
		ReadyUsers: make(map[string]bool),
		Activated:  len(expected) == 0,
	}
	return true
}

func (s *Server) mediaKeyExpectedUsers(serverID, channelID string, eligible map[string]bool) map[string]bool {
	expected := map[string]bool{}
	for _, state := range s.hub.Snapshot(serverID).VoiceStates {
		if state.ChannelID == channelID && eligible[state.UserID] {
			expected[state.UserID] = true
		}
	}
	return expected
}

func (s *Server) mediaKeyStatus(channelID, epochID string) (int, bool, bool) {
	s.mediaKeyMu.Lock()
	defer s.mediaKeyMu.Unlock()
	transition := s.mediaKeys[channelID]
	if transition == nil || transition.EpochID != epochID {
		return 0, true, false
	}
	return transition.KeyIndex, transition.Activated, true
}

func (s *Server) markMediaKeyReady(serverID, channelID, epochID, userID string, eligible map[string]bool) (int, bool, bool) {
	s.mediaKeyMu.Lock()
	transition := s.mediaKeys[channelID]
	if transition == nil || transition.EpochID != epochID || transition.ServerID != serverID {
		s.mediaKeyMu.Unlock()
		return 0, true, false
	}
	keyIndex := transition.KeyIndex
	activated := transition.Activated
	s.mediaKeyMu.Unlock()

	expected := s.mediaKeyExpectedUsers(serverID, channelID, eligible)
	if !expected[userID] {
		return keyIndex, activated, true
	}

	s.mediaKeyMu.Lock()
	transition = s.mediaKeys[channelID]
	if transition == nil || transition.EpochID != epochID {
		s.mediaKeyMu.Unlock()
		return 0, true, false
	}
	transition.ReadyUsers[userID] = true
	activate := !transition.Activated
	for expectedUserID := range expected {
		if !transition.ReadyUsers[expectedUserID] {
			activate = false
			break
		}
	}
	if activate {
		transition.Activated = true
	}
	keyIndex = transition.KeyIndex
	activated = transition.Activated
	s.mediaKeyMu.Unlock()

	if activate {
		s.hub.Publish(realtime.Event{
			Type: "e2ee.media_key_activated", ServerID: serverID, ChannelID: channelID,
			Payload: map[string]any{"epoch_id": epochID, "key_index": keyIndex},
		})
	}
	return keyIndex, activated, true
}

func (s *Server) disableMediaKeySlots(serverID, channelID, epochID string) bool {
	s.mediaKeyMu.Lock()
	transition := s.mediaKeys[channelID]
	if transition == nil || transition.EpochID != epochID {
		s.mediaKeyMu.Unlock()
		return false
	}
	delete(s.mediaKeys, channelID)
	s.mediaKeyMu.Unlock()
	s.hub.Publish(realtime.Event{
		Type: "e2ee.media_key_fallback", ServerID: serverID, ChannelID: channelID,
		Payload: map[string]any{"epoch_id": epochID},
	})
	return true
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]string{"error": code, "message_key": code, "message": message})
}

func deref(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
