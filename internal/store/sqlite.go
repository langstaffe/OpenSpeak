package store

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"openspeak/internal/ids"

	"golang.org/x/crypto/curve25519"
)

var (
	ErrNotFound         = errors.New("not found")
	ErrLastChannel      = errors.New("cannot delete the last channel")
	ErrDeviceConflict   = errors.New("device belongs to another user")
	ErrEpochConflict    = errors.New("channel epoch changed")
	ErrEncryptionMode   = errors.New("server encryption mode changed")
	ErrEnvelopeInvalid  = errors.New("invalid key envelope batch")
	ErrEnvelopeDenied   = errors.New("key envelope access denied")
	ErrEnvelopeConflict = errors.New("key envelopes already exist")
)

type SQLite struct {
	db *sql.DB
}

func NewSQLite(db *sql.DB) *SQLite {
	return &SQLite{db: db}
}

func ValidE2EEDeviceKeys(identityPublicKey, envelopePublicKey string) bool {
	identityKey, identityErr := base64.RawURLEncoding.DecodeString(identityPublicKey)
	envelopeKey, envelopeErr := base64.RawURLEncoding.DecodeString(envelopePublicKey)
	if identityErr != nil || len(identityKey) != 32 || envelopeErr != nil || len(envelopeKey) != 32 {
		return false
	}
	privateKey := make([]byte, 32)
	privateKey[0] = 1
	_, err := curve25519.X25519(privateKey, envelopeKey)
	return err == nil
}

func (s *SQLite) CreateUser(ctx context.Context, displayName string) (User, error) {
	u := User{ID: ids.New("usr"), DisplayName: displayName}
	var createdAt string
	err := s.db.QueryRowContext(ctx, `
		INSERT INTO users (id, display_name)
		VALUES (?, ?)
		RETURNING id, display_name, avatar_version, avatar_hash, created_at
	`, u.ID, u.DisplayName).Scan(&u.ID, &u.DisplayName, &u.AvatarVersion, &u.AvatarHash, &createdAt)
	u.CreatedAt = parseDBTime(createdAt)
	return u, err
}

func (s *SQLite) GetUser(ctx context.Context, userID string) (User, error) {
	var u User
	var createdAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT id, display_name, avatar_version, avatar_hash, created_at
		FROM users WHERE id = ?
	`, userID).Scan(&u.ID, &u.DisplayName, &u.AvatarVersion, &u.AvatarHash, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, ErrNotFound
	}
	u.CreatedAt = parseDBTime(createdAt)
	return u, err
}

func (s *SQLite) UpdateUserDisplayName(ctx context.Context, userID, displayName string) (User, error) {
	var u User
	var createdAt string
	err := s.db.QueryRowContext(ctx, `
		UPDATE users
		SET display_name = ?
		WHERE id = ?
		RETURNING id, display_name, avatar_version, avatar_hash, created_at
	`, displayName, userID).Scan(&u.ID, &u.DisplayName, &u.AvatarVersion, &u.AvatarHash, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, ErrNotFound
	}
	u.CreatedAt = parseDBTime(createdAt)
	return u, err
}

func (s *SQLite) IncrementUserAvatarVersion(ctx context.Context, userID, avatarHash string) (User, error) {
	var u User
	var createdAt string
	err := s.db.QueryRowContext(ctx, `
		UPDATE users SET avatar_version = avatar_version + 1, avatar_hash = ? WHERE id = ?
		RETURNING id, display_name, avatar_version, avatar_hash, created_at
	`, avatarHash, userID).Scan(&u.ID, &u.DisplayName, &u.AvatarVersion, &u.AvatarHash, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, ErrNotFound
	}
	u.CreatedAt = parseDBTime(createdAt)
	return u, err
}

func (s *SQLite) CountUsers(ctx context.Context) (int, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM users`).Scan(&count)
	return count, err
}

func (s *SQLite) RegisterDevice(ctx context.Context, d Device) (Device, error) {
	if d.ID == "" {
		d.ID = ids.New("dev")
	}
	var createdAt string
	var lastSeen sql.NullString
	err := s.db.QueryRowContext(ctx, `
		INSERT INTO user_devices (id, user_id, label, identity_public_key, envelope_public_key)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			label = excluded.label,
			identity_public_key = excluded.identity_public_key,
			envelope_public_key = excluded.envelope_public_key,
			last_seen_at = CURRENT_TIMESTAMP
		WHERE user_devices.user_id = excluded.user_id
		  AND user_devices.identity_public_key = excluded.identity_public_key
		  AND user_devices.envelope_public_key = excluded.envelope_public_key
		RETURNING id, user_id, label, identity_public_key, envelope_public_key, created_at, last_seen_at
	`, d.ID, d.UserID, d.Label, d.IdentityPublicKey, d.EnvelopePublicKey).
		Scan(&d.ID, &d.UserID, &d.Label, &d.IdentityPublicKey, &d.EnvelopePublicKey, &createdAt, &lastSeen)
	if errors.Is(err, sql.ErrNoRows) {
		return Device{}, ErrDeviceConflict
	}
	d.CreatedAt = parseDBTime(createdAt)
	d.LastSeenAt = parseOptionalDBTime(lastSeen)
	return d, err
}

func (s *SQLite) TouchDevice(ctx context.Context, deviceID string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE user_devices SET last_seen_at = CURRENT_TIMESTAMP WHERE id = ?`, deviceID)
	return err
}

func (s *SQLite) GetDevice(ctx context.Context, deviceID string) (Device, error) {
	var device Device
	var createdAt string
	var lastSeen sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT id, user_id, label, identity_public_key, envelope_public_key, created_at, last_seen_at
		FROM user_devices WHERE id = ?
	`, deviceID).Scan(&device.ID, &device.UserID, &device.Label, &device.IdentityPublicKey, &device.EnvelopePublicKey, &createdAt, &lastSeen)
	if errors.Is(err, sql.ErrNoRows) {
		return Device{}, ErrNotFound
	}
	device.CreatedAt = parseDBTime(createdAt)
	device.LastSeenAt = parseOptionalDBTime(lastSeen)
	return device, err
}

func (s *SQLite) CreateServer(ctx context.Context, server OSServer) (OSServer, error) {
	if server.ID == "" {
		server.ID = ids.New("srv")
	}
	if len(server.ScreenSharePolicy.P2P.Allowed) == 0 && len(server.ScreenSharePolicy.Relay.Allowed) == 0 {
		server.ScreenSharePolicy = DefaultScreenSharePolicy()
	}
	policyJSON, err := json.Marshal(server.ScreenSharePolicy)
	if err != nil {
		return OSServer{}, err
	}
	if !server.ScreenShareBitrateLimits.Valid() {
		server.ScreenShareBitrateLimits = DefaultScreenShareBitrateLimits()
	}
	bitrateLimitsJSON, err := json.Marshal(server.ScreenShareBitrateLimits)
	if err != nil {
		return OSServer{}, err
	}
	var createdAt string
	var policyText string
	var bitrateLimitsText string
	err = s.db.QueryRowContext(ctx, `
		INSERT INTO os_servers (id, name, encryption_mode, file_root, history_retention_days, screen_share_policy_json, screen_share_bitrate_limits_json)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		RETURNING id, name, avatar_version, avatar_hash, encryption_mode, file_root, history_retention_days,
			server_password_hash != '', screen_share_policy_json, default_channel_id,
			attachment_external_enabled, attachment_file_node_id, voice_audio_bitrate_kbps,
			screen_share_bitrate_limits_json,
			tls_certificate_type, tls_identifier, tls_status, tls_error, tls_expires_at, created_at
	`, server.ID, server.Name, server.EncryptionMode, server.FileRoot, server.HistoryRetentionDays, string(policyJSON), string(bitrateLimitsJSON)).
		Scan(&server.ID, &server.Name, &server.AvatarVersion, &server.AvatarHash, &server.EncryptionMode, &server.FileRoot, &server.HistoryRetentionDays, &server.PasswordProtected, &policyText, &server.DefaultChannelID, &server.AttachmentExternalEnabled, &server.AttachmentFileNodeID, &server.VoiceAudioBitrateKbps, &bitrateLimitsText, &server.TLSCertificateType, &server.TLSIdentifier, &server.TLSStatus, &server.TLSError, &server.TLSExpiresAt, &createdAt)
	if err != nil {
		return OSServer{}, err
	}
	server.CreatedAt = parseDBTime(createdAt)
	server.ScreenSharePolicy = decodeScreenSharePolicy(policyText)
	server.ScreenShareBitrateLimits = decodeScreenShareBitrateLimits(bitrateLimitsText)
	return server, nil
}

func (s *SQLite) ListServers(ctx context.Context) ([]OSServer, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, name, avatar_version, avatar_hash, encryption_mode, file_root, history_retention_days,
			server_password_hash != '', screen_share_policy_json, default_channel_id,
			attachment_external_enabled, attachment_file_node_id, voice_audio_bitrate_kbps,
			screen_share_bitrate_limits_json,
			tls_certificate_type, tls_identifier, tls_status, tls_error, tls_expires_at, created_at
		FROM os_servers ORDER BY created_at DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	servers := []OSServer{}
	for rows.Next() {
		var server OSServer
		var createdAt string
		var policyText string
		var bitrateLimitsText string
		if err := rows.Scan(&server.ID, &server.Name, &server.AvatarVersion, &server.AvatarHash, &server.EncryptionMode, &server.FileRoot, &server.HistoryRetentionDays, &server.PasswordProtected, &policyText, &server.DefaultChannelID, &server.AttachmentExternalEnabled, &server.AttachmentFileNodeID, &server.VoiceAudioBitrateKbps, &bitrateLimitsText, &server.TLSCertificateType, &server.TLSIdentifier, &server.TLSStatus, &server.TLSError, &server.TLSExpiresAt, &createdAt); err != nil {
			return nil, err
		}
		server.CreatedAt = parseDBTime(createdAt)
		server.ScreenSharePolicy = decodeScreenSharePolicy(policyText)
		server.ScreenShareBitrateLimits = decodeScreenShareBitrateLimits(bitrateLimitsText)
		servers = append(servers, server)
	}
	return servers, rows.Err()
}

func (s *SQLite) GetServer(ctx context.Context, serverID string) (OSServer, error) {
	var server OSServer
	var createdAt string
	var policyText string
	var bitrateLimitsText string
	err := s.db.QueryRowContext(ctx, `
		SELECT id, name, avatar_version, avatar_hash, encryption_mode, file_root, history_retention_days,
			server_password_hash != '', screen_share_policy_json, default_channel_id,
			attachment_external_enabled, attachment_file_node_id, voice_audio_bitrate_kbps,
			screen_share_bitrate_limits_json,
			tls_certificate_type, tls_identifier, tls_status, tls_error, tls_expires_at, created_at
		FROM os_servers WHERE id = ?
	`, serverID).Scan(&server.ID, &server.Name, &server.AvatarVersion, &server.AvatarHash, &server.EncryptionMode, &server.FileRoot, &server.HistoryRetentionDays, &server.PasswordProtected, &policyText, &server.DefaultChannelID, &server.AttachmentExternalEnabled, &server.AttachmentFileNodeID, &server.VoiceAudioBitrateKbps, &bitrateLimitsText, &server.TLSCertificateType, &server.TLSIdentifier, &server.TLSStatus, &server.TLSError, &server.TLSExpiresAt, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return OSServer{}, ErrNotFound
	}
	server.CreatedAt = parseDBTime(createdAt)
	server.ScreenSharePolicy = decodeScreenSharePolicy(policyText)
	server.ScreenShareBitrateLimits = decodeScreenShareBitrateLimits(bitrateLimitsText)
	return server, err
}

func (s *SQLite) GetServerPasswordHash(ctx context.Context, serverID string) (string, error) {
	var passwordHash string
	err := s.db.QueryRowContext(ctx, `
		SELECT server_password_hash
		FROM os_servers WHERE id = ?
	`, serverID).Scan(&passwordHash)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return passwordHash, err
}

func (s *SQLite) UpdateServer(ctx context.Context, serverID string, name *string, encryptionMode *string, fileRoot *string, historyRetentionDays *int, serverPasswordHash *string, screenSharePolicy *ScreenSharePolicy, defaultChannelID *string, attachmentExternalEnabled *bool, attachmentFileNodeID *string, voiceAudioBitrateKbps *int, screenShareBitrateLimits *ScreenShareBitrateLimits) (OSServer, error) {
	var policyValue any
	if screenSharePolicy != nil {
		policyJSON, err := json.Marshal(screenSharePolicy)
		if err != nil {
			return OSServer{}, err
		}
		policyValue = string(policyJSON)
	}
	var server OSServer
	var externalEnabled any
	if attachmentExternalEnabled != nil {
		externalEnabled = boolToInt(*attachmentExternalEnabled)
	}
	var bitrateLimitsValue any
	if screenShareBitrateLimits != nil {
		bitrateLimitsJSON, err := json.Marshal(screenShareBitrateLimits)
		if err != nil {
			return OSServer{}, err
		}
		bitrateLimitsValue = string(bitrateLimitsJSON)
	}
	var createdAt string
	var policyText string
	var bitrateLimitsText string
	err := s.db.QueryRowContext(ctx, `
		UPDATE os_servers
		SET name = COALESCE(?, name),
			encryption_mode = COALESCE(?, encryption_mode),
			file_root = COALESCE(?, file_root),
			history_retention_days = COALESCE(?, history_retention_days),
			server_password_hash = COALESCE(?, server_password_hash),
			screen_share_policy_json = COALESCE(?, screen_share_policy_json),
			default_channel_id = COALESCE(?, default_channel_id),
			attachment_external_enabled = COALESCE(?, attachment_external_enabled),
			attachment_file_node_id = COALESCE(?, attachment_file_node_id),
			voice_audio_bitrate_kbps = COALESCE(?, voice_audio_bitrate_kbps),
			screen_share_bitrate_limits_json = COALESCE(?, screen_share_bitrate_limits_json)
		WHERE id = ?
		RETURNING id, name, avatar_version, avatar_hash, encryption_mode, file_root, history_retention_days,
			server_password_hash != '', screen_share_policy_json, default_channel_id,
			attachment_external_enabled, attachment_file_node_id, voice_audio_bitrate_kbps,
			screen_share_bitrate_limits_json,
			tls_certificate_type, tls_identifier, tls_status, tls_error, tls_expires_at, created_at
	`, name, encryptionMode, fileRoot, historyRetentionDays, serverPasswordHash, policyValue, defaultChannelID, externalEnabled, attachmentFileNodeID, voiceAudioBitrateKbps, bitrateLimitsValue, serverID).
		Scan(&server.ID, &server.Name, &server.AvatarVersion, &server.AvatarHash, &server.EncryptionMode, &server.FileRoot, &server.HistoryRetentionDays, &server.PasswordProtected, &policyText, &server.DefaultChannelID, &server.AttachmentExternalEnabled, &server.AttachmentFileNodeID, &server.VoiceAudioBitrateKbps, &bitrateLimitsText, &server.TLSCertificateType, &server.TLSIdentifier, &server.TLSStatus, &server.TLSError, &server.TLSExpiresAt, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return OSServer{}, ErrNotFound
	}
	server.CreatedAt = parseDBTime(createdAt)
	server.ScreenSharePolicy = decodeScreenSharePolicy(policyText)
	server.ScreenShareBitrateLimits = decodeScreenShareBitrateLimits(bitrateLimitsText)
	return server, err
}

func (s *SQLite) UpdateServerTLS(ctx context.Context, serverID, certificateType, identifier, status, tlsError string, expiresAt *time.Time, encryptionMode *string) (OSServer, error) {
	_, err := s.db.ExecContext(ctx, `
		UPDATE os_servers SET tls_certificate_type = ?, tls_identifier = ?, tls_status = ?,
			tls_error = ?, tls_expires_at = ?, encryption_mode = COALESCE(?, encryption_mode)
		WHERE id = ?
	`, certificateType, identifier, status, tlsError, expiresAt, encryptionMode, serverID)
	if err != nil {
		return OSServer{}, err
	}
	return s.GetServer(ctx, serverID)
}

func (s *SQLite) IncrementServerAvatarVersion(ctx context.Context, serverID, avatarHash string) (OSServer, error) {
	if _, err := s.db.ExecContext(ctx, `UPDATE os_servers SET avatar_version = avatar_version + 1, avatar_hash = ? WHERE id = ?`, avatarHash, serverID); err != nil {
		return OSServer{}, err
	}
	return s.GetServer(ctx, serverID)
}

func (s *SQLite) IsServerOwnerOrAdmin(ctx context.Context, serverID, userID string) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*)
		FROM os_servers srv
		JOIN server_members sm
			ON sm.server_id = srv.id
			AND sm.user_id = ?
		WHERE srv.id = ?
		  AND sm.role IN ('owner', 'admin')
	`, userID, serverID).Scan(&count)
	return count > 0, err
}

func (s *SQLite) IsServerOwnerOrHasPermission(ctx context.Context, serverID, userID, permission string) (bool, error) {
	var member ServerMember
	var permissionsText sql.NullString
	var joinedAt sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT COALESCE(sm.role, ''), rp.permissions_json, sm.joined_at
		FROM os_servers srv
		LEFT JOIN server_members sm
			ON sm.server_id = srv.id
			AND sm.user_id = ?
		LEFT JOIN server_role_permissions rp
			ON rp.server_id = srv.id AND rp.role = sm.role
		WHERE srv.id = ?
	`, userID, serverID).Scan(&member.Role, &permissionsText, &joinedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return false, ErrNotFound
	}
	if err != nil {
		return false, err
	}
	if member.Role == RoleOwner {
		return true, nil
	}
	if member.Role != RoleAdmin && member.Role != RoleUser {
		return false, nil
	}
	permissions := DefaultPermissionsForRole(member.Role)
	if permissionsText.Valid {
		_ = json.Unmarshal([]byte(permissionsText.String), &permissions)
		permissions = withDefaultScreenShareQualityPermissions(filterDelegablePermissions(permissions))
	}
	return hasPermission(permissions, permission), nil
}

func (s *SQLite) GetServerRolePermissions(ctx context.Context, serverID string) (ServerRolePermissions, error) {
	if _, err := s.GetServer(ctx, serverID); err != nil {
		return ServerRolePermissions{}, err
	}
	result := ServerRolePermissions{ServerID: serverID, Admin: AdminPermissions(), User: UserPermissions()}
	rows, err := s.db.QueryContext(ctx, `SELECT role, permissions_json, COALESCE(updated_by_user_id, ''), updated_at FROM server_role_permissions WHERE server_id = ?`, serverID)
	if err != nil {
		return ServerRolePermissions{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var role, raw, updatedBy, updatedAt string
		if err := rows.Scan(&role, &raw, &updatedBy, &updatedAt); err != nil {
			return ServerRolePermissions{}, err
		}
		var permissions []string
		_ = json.Unmarshal([]byte(raw), &permissions)
		permissions = withDefaultScreenShareQualityPermissions(filterDelegablePermissions(permissions))
		if role == RoleAdmin {
			result.Admin = permissions
		} else if role == RoleUser {
			result.User = permissions
		}
		result.UpdatedBy = updatedBy
		result.UpdatedAt = parseDBTime(updatedAt)
	}
	return result, rows.Err()
}

func (s *SQLite) SetServerRolePermissions(ctx context.Context, serverID string, admin, user []string, actorUserID string) (ServerRolePermissions, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ServerRolePermissions{}, err
	}
	defer tx.Rollback()
	for role, permissions := range map[string][]string{RoleAdmin: admin, RoleUser: user} {
		raw, err := json.Marshal(permissions)
		if err != nil {
			return ServerRolePermissions{}, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO server_role_permissions (server_id, role, permissions_json, updated_by_user_id, updated_at) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP) ON CONFLICT(server_id, role) DO UPDATE SET permissions_json = excluded.permissions_json, updated_by_user_id = excluded.updated_by_user_id, updated_at = CURRENT_TIMESTAMP`, serverID, role, string(raw), actorUserID); err != nil {
			return ServerRolePermissions{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return ServerRolePermissions{}, err
	}
	return s.GetServerRolePermissions(ctx, serverID)
}

func (s *SQLite) GetMessageRetractWindowMinutes(ctx context.Context, serverID string) (int, error) {
	var minutes int
	err := s.db.QueryRowContext(ctx, `SELECT message_retract_window_minutes FROM os_servers WHERE id = ?`, serverID).Scan(&minutes)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	return minutes, err
}

func (s *SQLite) SetMessageRetractWindowMinutes(ctx context.Context, serverID string, minutes int) error {
	result, err := s.db.ExecContext(ctx, `UPDATE os_servers SET message_retract_window_minutes = ? WHERE id = ?`, minutes, serverID)
	if err != nil {
		return err
	}
	updated, err := result.RowsAffected()
	if err == nil && updated == 0 {
		return ErrNotFound
	}
	return err
}

func (s *SQLite) EffectiveServerPermissions(ctx context.Context, serverID, userID string) ([]string, error) {
	member, err := s.GetServerMember(ctx, serverID, userID)
	if err != nil {
		return nil, err
	}
	if member.Role == RoleOwner {
		return AllPermissions(), nil
	}
	settings, err := s.GetServerRolePermissions(ctx, serverID)
	if err != nil {
		return nil, err
	}
	if member.Role == RoleAdmin {
		return settings.Admin, nil
	}
	return settings.User, nil
}

func (s *SQLite) IsServerMember(ctx context.Context, serverID, userID string) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*)
		FROM server_members
		WHERE server_id = ?
		  AND user_id = ?
	`, serverID, userID).Scan(&count)
	return count > 0, err
}

func (s *SQLite) IsChannelServerOwnerOrAdmin(ctx context.Context, channelID, userID string) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*)
		FROM channels c
		JOIN os_servers srv ON srv.id = c.server_id
		JOIN server_members sm
			ON sm.server_id = srv.id
			AND sm.user_id = ?
		WHERE c.id = ?
		  AND sm.role IN ('owner', 'admin')
	`, userID, channelID).Scan(&count)
	return count > 0, err
}

func (s *SQLite) IsChannelServerOwnerOrHasPermission(ctx context.Context, channelID, userID, permission string) (bool, error) {
	var serverID string
	err := s.db.QueryRowContext(ctx, `SELECT server_id FROM channels WHERE id = ?`, channelID).Scan(&serverID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, ErrNotFound
	}
	if err != nil {
		return false, err
	}
	return s.IsServerOwnerOrHasPermission(ctx, serverID, userID, permission)
}

func (s *SQLite) IsDeviceOwnerOrAdmin(ctx context.Context, deviceID, userID string) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*)
		FROM user_devices d
		WHERE d.id = ?
		  AND d.user_id = ?
	`, deviceID, userID).Scan(&count)
	return count > 0, err
}

func (s *SQLite) IsChannelMemberOrOwnerOrAdmin(ctx context.Context, channelID, userID string) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*)
		FROM channels c
		JOIN os_servers srv ON srv.id = c.server_id
		LEFT JOIN channel_members m
			ON m.channel_id = c.id
			AND m.user_id = ?
			AND m.left_at IS NULL
		LEFT JOIN server_members sm
			ON sm.server_id = srv.id
			AND sm.user_id = ?
		WHERE c.id = ?
		  AND (
			sm.role IN ('owner', 'admin')
			OR m.user_id IS NOT NULL
		  )
	`, userID, userID, channelID).Scan(&count)
	return count > 0, err
}

func (s *SQLite) SetServerMember(ctx context.Context, serverID, userID, role string, permissions []string) (ServerMember, error) {
	role = NormalizeServerRole(role)
	if role == "owner" {
		permissions = AllPermissions()
	}
	permissionsJSON, err := json.Marshal(permissions)
	if err != nil {
		return ServerMember{}, err
	}
	member := ServerMember{ServerID: serverID, UserID: userID, Role: role, Permissions: permissions}
	var permissionsText string
	var joinedAt string
	err = s.db.QueryRowContext(ctx, `
		INSERT INTO server_members (server_id, user_id, role, permissions_json, joined_at)
		VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(server_id, user_id) DO UPDATE
		SET role = excluded.role,
			permissions_json = excluded.permissions_json
		RETURNING server_id, user_id, role, permissions_json, joined_at
	`, serverID, userID, role, string(permissionsJSON)).
		Scan(&member.ServerID, &member.UserID, &member.Role, &permissionsText, &joinedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ServerMember{}, ErrNotFound
	}
	if err != nil {
		return ServerMember{}, err
	}
	_ = json.Unmarshal([]byte(permissionsText), &member.Permissions)
	member.JoinedAt = parseDBTime(joinedAt)
	return member, nil
}

func (s *SQLite) ListServerMembers(ctx context.Context, serverID string) ([]ServerMember, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT server_id, user_id, role, permissions_json, joined_at
		FROM server_members
		WHERE server_id = ?
		ORDER BY joined_at ASC
	`, serverID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	members := []ServerMember{}
	for rows.Next() {
		var member ServerMember
		var permissionsText string
		var joinedAt string
		if err := rows.Scan(&member.ServerID, &member.UserID, &member.Role, &permissionsText, &joinedAt); err != nil {
			return nil, err
		}
		_ = json.Unmarshal([]byte(permissionsText), &member.Permissions)
		member.JoinedAt = parseDBTime(joinedAt)
		members = append(members, member)
	}
	return members, rows.Err()
}

func (s *SQLite) GetServerMember(ctx context.Context, serverID, userID string) (ServerMember, error) {
	var member ServerMember
	var permissionsText string
	var joinedAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT server_id, user_id, role, permissions_json, joined_at
		FROM server_members
		WHERE server_id = ? AND user_id = ?
	`, serverID, userID).Scan(&member.ServerID, &member.UserID, &member.Role, &permissionsText, &joinedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ServerMember{}, ErrNotFound
	}
	if err != nil {
		return ServerMember{}, err
	}
	_ = json.Unmarshal([]byte(permissionsText), &member.Permissions)
	member.JoinedAt = parseDBTime(joinedAt)
	return member, nil
}

func (s *SQLite) FindUserByClientInstallation(ctx context.Context, serverID, installationHash string) (User, error) {
	var user User
	var createdAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT u.id, u.display_name, u.avatar_version, u.avatar_hash, u.created_at
		FROM client_installations ci
		JOIN users u ON u.id = ci.user_id
		WHERE ci.server_id = ? AND ci.installation_hash = ?
	`, serverID, installationHash).Scan(&user.ID, &user.DisplayName, &user.AvatarVersion, &user.AvatarHash, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, ErrNotFound
	}
	user.CreatedAt = parseDBTime(createdAt)
	return user, err
}

func (s *SQLite) BindClientInstallation(ctx context.Context, serverID, installationHash, userID, displayName string) error {
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO client_installations (server_id, installation_hash, user_id)
		VALUES (?, ?, ?)
		ON CONFLICT(server_id, installation_hash) DO UPDATE
		SET last_seen_at = CURRENT_TIMESTAMP
	`, serverID, installationHash, userID); err != nil {
		return err
	}
	return s.TouchClientInstallation(ctx, serverID, installationHash, userID, displayName)
}

func (s *SQLite) TouchClientInstallation(ctx context.Context, serverID, installationHash, userID, displayName string) error {
	if _, err := s.db.ExecContext(ctx, `
		UPDATE client_installations
		SET last_seen_at = CURRENT_TIMESTAMP
		WHERE server_id = ? AND installation_hash = ? AND user_id = ?
	`, serverID, installationHash, userID); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO member_aliases (server_id, user_id, display_name)
		VALUES (?, ?, ?)
		ON CONFLICT(server_id, user_id, display_name) DO UPDATE
		SET last_used_at = CURRENT_TIMESTAMP
	`, serverID, userID, displayName)
	return err
}

func (s *SQLite) IsClientInstallationBanned(ctx context.Context, serverID, installationHash string) (ServerBan, bool, error) {
	return s.activeServerBan(ctx, serverID, "installation_hash = ?", installationHash)
}

func (s *SQLite) IsServerUserBanned(ctx context.Context, serverID, userID string) (ServerBan, bool, error) {
	return s.activeServerBan(ctx, serverID, "user_id = ?", userID)
}

func (s *SQLite) activeServerBan(ctx context.Context, serverID, predicate, value string) (ServerBan, bool, error) {
	var ban ServerBan
	var createdAt string
	var expiresAt sql.NullString
	var revokedAt sql.NullString
	var revokedBy sql.NullString
	query := `
		SELECT id, server_id, user_id, installation_hash, reason,
			created_by_user_id, created_at, expires_at, revoked_at, revoked_by_user_id
		FROM server_bans
		WHERE server_id = ? AND ` + predicate + `
		  AND revoked_at IS NULL
		  AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)
		ORDER BY created_at DESC
		LIMIT 1
	`
	err := s.db.QueryRowContext(ctx, query, serverID, value).Scan(
		&ban.ID, &ban.ServerID, &ban.UserID, &ban.InstallationHash, &ban.Reason,
		&ban.CreatedByUserID, &createdAt, &expiresAt, &revokedAt, &revokedBy,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return ServerBan{}, false, nil
	}
	if err != nil {
		return ServerBan{}, false, err
	}
	ban.CreatedAt = parseDBTime(createdAt)
	ban.ExpiresAt = parseOptionalDBTime(expiresAt)
	ban.RevokedAt = parseOptionalDBTime(revokedAt)
	if revokedBy.Valid {
		ban.RevokedByUserID = &revokedBy.String
	}
	return ban, true, nil
}

func (s *SQLite) ListManagedServerMembers(ctx context.Context, serverID string) ([]ManagedServerMember, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT sm.server_id, sm.user_id, u.display_name, sm.role,
			sm.permissions_json, sm.joined_at,
			ci.first_seen_at, ci.last_seen_at, COALESCE(ci.installation_hash, ''),
			COALESCE(b.id, ''), COALESCE(b.reason, ''), b.expires_at
		FROM server_members sm
		JOIN users u ON u.id = sm.user_id
		LEFT JOIN client_installations ci
			ON ci.server_id = sm.server_id AND ci.user_id = sm.user_id
		LEFT JOIN server_bans b ON b.id = (
			SELECT id FROM server_bans active
			WHERE active.server_id = sm.server_id
			  AND active.user_id = sm.user_id
			  AND active.revoked_at IS NULL
			  AND (active.expires_at IS NULL OR active.expires_at > CURRENT_TIMESTAMP)
			ORDER BY active.created_at DESC LIMIT 1
		)
		WHERE sm.server_id = ?
		ORDER BY COALESCE(ci.last_seen_at, sm.joined_at) DESC
	`, serverID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	members := []ManagedServerMember{}
	for rows.Next() {
		var member ManagedServerMember
		var permissionsText string
		var joinedAt string
		var firstSeen sql.NullString
		var lastSeen sql.NullString
		var installationHash string
		var expiresAt sql.NullString
		if err := rows.Scan(
			&member.ServerID, &member.UserID, &member.DisplayName, &member.Role,
			&permissionsText, &joinedAt, &firstSeen, &lastSeen, &installationHash,
			&member.BanID, &member.BanReason, &expiresAt,
		); err != nil {
			return nil, err
		}
		_ = json.Unmarshal([]byte(permissionsText), &member.Permissions)
		member.JoinedAt = parseDBTime(joinedAt)
		member.FirstSeenAt = parseOptionalDBTime(firstSeen)
		member.LastSeenAt = parseOptionalDBTime(lastSeen)
		member.Legacy = installationHash == ""
		if installationHash != "" {
			fingerprint := installationHash
			if len(fingerprint) > 12 {
				fingerprint = fingerprint[:12]
			}
			member.InstallationFingerprint = fingerprint
		}
		member.Banned = member.BanID != ""
		member.BanExpiresAt = parseOptionalDBTime(expiresAt)
		members = append(members, member)
	}
	return members, rows.Err()
}

func (s *SQLite) CreateServerBan(ctx context.Context, serverID, userID, reason, actorUserID string, expiresAt *time.Time) (ServerBan, error) {
	var installationHash string
	err := s.db.QueryRowContext(ctx, `
		SELECT installation_hash FROM client_installations
		WHERE server_id = ? AND user_id = ?
	`, serverID, userID).Scan(&installationHash)
	if errors.Is(err, sql.ErrNoRows) {
		return ServerBan{}, ErrNotFound
	}
	if err != nil {
		return ServerBan{}, err
	}
	if existing, ok, err := s.IsClientInstallationBanned(ctx, serverID, installationHash); err != nil {
		return ServerBan{}, err
	} else if ok {
		return existing, nil
	}
	ban := ServerBan{
		ID: ids.New("ban"), ServerID: serverID, UserID: userID,
		InstallationHash: installationHash, Reason: reason, CreatedByUserID: actorUserID,
		ExpiresAt: expiresAt,
	}
	var createdAt string
	var expiresText sql.NullString
	err = s.db.QueryRowContext(ctx, `
		INSERT INTO server_bans (
			id, server_id, user_id, installation_hash, reason, created_by_user_id, expires_at
		) VALUES (?, ?, ?, ?, ?, ?, ?)
		RETURNING created_at, expires_at
	`, ban.ID, ban.ServerID, ban.UserID, ban.InstallationHash, ban.Reason, ban.CreatedByUserID, ban.ExpiresAt).
		Scan(&createdAt, &expiresText)
	ban.CreatedAt = parseDBTime(createdAt)
	ban.ExpiresAt = parseOptionalDBTime(expiresText)
	return ban, err
}

func (s *SQLite) RevokeServerBan(ctx context.Context, serverID, userID, actorUserID string) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE server_bans
		SET revoked_at = CURRENT_TIMESTAMP, revoked_by_user_id = ?
		WHERE server_id = ? AND user_id = ? AND revoked_at IS NULL
	`, actorUserID, serverID, userID)
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if count == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *SQLite) CreateMediaNode(ctx context.Context, node MediaNode) (MediaNode, error) {
	if node.ID == "" {
		node.ID = ids.New("med")
	}
	if node.Weight <= 0 {
		node.Weight = 100
	}
	var createdAt string
	var updatedAt string
	err := s.db.QueryRowContext(ctx, `
		INSERT INTO media_nodes (
			id, server_id, name, livekit_url, api_key, api_secret, region,
			weight, enabled, draining, max_relay_bitrate_kbps, max_rooms
		)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		RETURNING id, server_id, name, livekit_url, api_key, api_secret != '',
			region, weight, enabled, draining, max_relay_bitrate_kbps, max_rooms,
			created_at, updated_at
	`, node.ID, node.ServerID, node.Name, node.LiveKitURL, node.APIKey, node.APISecret, node.Region,
		node.Weight, boolToInt(node.Enabled), boolToInt(node.Draining), node.MaxRelayBitrateKbps, node.MaxRooms).
		Scan(&node.ID, &node.ServerID, &node.Name, &node.LiveKitURL, &node.APIKey, &node.APISecretSet,
			&node.Region, &node.Weight, &node.Enabled, &node.Draining, &node.MaxRelayBitrateKbps, &node.MaxRooms,
			&createdAt, &updatedAt)
	if err != nil {
		return MediaNode{}, err
	}
	node.APISecret = ""
	node.CreatedAt = parseDBTime(createdAt)
	node.UpdatedAt = parseDBTime(updatedAt)
	return node, nil
}

func (s *SQLite) ListMediaNodes(ctx context.Context, serverID string) ([]MediaNode, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, server_id, name, livekit_url, api_key, api_secret != '',
			region, weight, enabled, draining, max_relay_bitrate_kbps, max_rooms,
			created_at, updated_at
		FROM media_nodes
		WHERE server_id = ?
		ORDER BY weight DESC, created_at ASC
	`, serverID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	nodes := []MediaNode{}
	for rows.Next() {
		var node MediaNode
		var createdAt string
		var updatedAt string
		if err := rows.Scan(&node.ID, &node.ServerID, &node.Name, &node.LiveKitURL, &node.APIKey, &node.APISecretSet,
			&node.Region, &node.Weight, &node.Enabled, &node.Draining, &node.MaxRelayBitrateKbps, &node.MaxRooms,
			&createdAt, &updatedAt); err != nil {
			return nil, err
		}
		node.CreatedAt = parseDBTime(createdAt)
		node.UpdatedAt = parseDBTime(updatedAt)
		nodes = append(nodes, node)
	}
	return nodes, rows.Err()
}

// GetMediaNode returns the stored credentials for server-side token signing.
// API responses must continue to use ListMediaNodes, which never exposes the secret.
func (s *SQLite) GetMediaNode(ctx context.Context, serverID, nodeID string) (MediaNode, error) {
	var node MediaNode
	var createdAt string
	var updatedAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT id, server_id, name, livekit_url, api_key, api_secret,
			region, weight, enabled, draining, max_relay_bitrate_kbps, max_rooms,
			created_at, updated_at
		FROM media_nodes
		WHERE server_id = ? AND id = ?
	`, serverID, nodeID).Scan(&node.ID, &node.ServerID, &node.Name, &node.LiveKitURL, &node.APIKey, &node.APISecret,
		&node.Region, &node.Weight, &node.Enabled, &node.Draining, &node.MaxRelayBitrateKbps, &node.MaxRooms,
		&createdAt, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return MediaNode{}, ErrNotFound
	}
	if err != nil {
		return MediaNode{}, err
	}
	node.APISecretSet = node.APISecret != ""
	node.CreatedAt = parseDBTime(createdAt)
	node.UpdatedAt = parseDBTime(updatedAt)
	return node, nil
}

func (s *SQLite) UpdateMediaNode(ctx context.Context, serverID, nodeID string, patch MediaNodePatch) (MediaNode, error) {
	var enabled any
	if patch.Enabled != nil {
		enabled = boolToInt(*patch.Enabled)
	}
	var draining any
	if patch.Draining != nil {
		draining = boolToInt(*patch.Draining)
	}
	var node MediaNode
	var createdAt string
	var updatedAt string
	err := s.db.QueryRowContext(ctx, `
		UPDATE media_nodes
		SET name = COALESCE(?, name),
			livekit_url = COALESCE(?, livekit_url),
			api_key = COALESCE(?, api_key),
			api_secret = COALESCE(?, api_secret),
			region = COALESCE(?, region),
			weight = COALESCE(?, weight),
			enabled = COALESCE(?, enabled),
			draining = COALESCE(?, draining),
			max_relay_bitrate_kbps = COALESCE(?, max_relay_bitrate_kbps),
			max_rooms = COALESCE(?, max_rooms),
			updated_at = CURRENT_TIMESTAMP
		WHERE id = ? AND server_id = ?
		RETURNING id, server_id, name, livekit_url, api_key, api_secret != '',
			region, weight, enabled, draining, max_relay_bitrate_kbps, max_rooms,
			created_at, updated_at
	`, patch.Name, patch.LiveKitURL, patch.APIKey, patch.APISecret, patch.Region, patch.Weight, enabled, draining,
		patch.MaxRelayBitrateKbps, patch.MaxRooms, nodeID, serverID).
		Scan(&node.ID, &node.ServerID, &node.Name, &node.LiveKitURL, &node.APIKey, &node.APISecretSet,
			&node.Region, &node.Weight, &node.Enabled, &node.Draining, &node.MaxRelayBitrateKbps, &node.MaxRooms,
			&createdAt, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return MediaNode{}, ErrNotFound
	}
	if err != nil {
		return MediaNode{}, err
	}
	node.CreatedAt = parseDBTime(createdAt)
	node.UpdatedAt = parseDBTime(updatedAt)
	return node, nil
}

// SelectMediaNode currently returns one enabled, non-draining LiveKit node for a server.
// This intentionally keeps the first implementation simple for a single relay server.
// Future multi-node load balancing should be implemented here, using fields such as
// weight, max_relay_bitrate_kbps, max_rooms, and live runtime reservations.
func (s *SQLite) SelectMediaNode(ctx context.Context, serverID string) (MediaNode, error) {
	var node MediaNode
	var createdAt string
	var updatedAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT id, server_id, name, livekit_url, api_key, api_secret,
			region, weight, enabled, draining, max_relay_bitrate_kbps, max_rooms,
			created_at, updated_at
		FROM media_nodes
		WHERE server_id = ?
		  AND enabled = 1
		  AND draining = 0
		ORDER BY weight DESC, created_at ASC
		LIMIT 1
	`, serverID).Scan(&node.ID, &node.ServerID, &node.Name, &node.LiveKitURL, &node.APIKey, &node.APISecret,
		&node.Region, &node.Weight, &node.Enabled, &node.Draining, &node.MaxRelayBitrateKbps, &node.MaxRooms,
		&createdAt, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return MediaNode{}, ErrNotFound
	}
	if err != nil {
		return MediaNode{}, err
	}
	node.APISecretSet = node.APISecret != ""
	node.CreatedAt = parseDBTime(createdAt)
	node.UpdatedAt = parseDBTime(updatedAt)
	return node, nil
}

func (s *SQLite) CreateFileNode(ctx context.Context, node FileNode) (FileNode, error) {
	if node.ID == "" {
		node.ID = ids.New("fnd")
	}
	var createdAt, updatedAt string
	err := s.db.QueryRowContext(ctx, `
		INSERT INTO file_nodes (id, server_id, name, base_url, secret, enabled)
		VALUES (?, ?, ?, ?, ?, ?)
		RETURNING id, server_id, name, base_url, secret != '', enabled, created_at, updated_at
	`, node.ID, node.ServerID, node.Name, node.BaseURL, node.Secret, boolToInt(node.Enabled)).
		Scan(&node.ID, &node.ServerID, &node.Name, &node.BaseURL, &node.SecretSet, &node.Enabled, &createdAt, &updatedAt)
	if err != nil {
		return FileNode{}, err
	}
	node.Secret = ""
	node.CreatedAt = parseDBTime(createdAt)
	node.UpdatedAt = parseDBTime(updatedAt)
	return node, nil
}

func (s *SQLite) ListFileNodes(ctx context.Context, serverID string) ([]FileNode, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, server_id, name, base_url, secret != '', enabled, created_at, updated_at
		FROM file_nodes WHERE server_id = ? ORDER BY created_at ASC
	`, serverID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	nodes := []FileNode{}
	for rows.Next() {
		var node FileNode
		var createdAt, updatedAt string
		if err := rows.Scan(&node.ID, &node.ServerID, &node.Name, &node.BaseURL, &node.SecretSet, &node.Enabled, &createdAt, &updatedAt); err != nil {
			return nil, err
		}
		node.CreatedAt = parseDBTime(createdAt)
		node.UpdatedAt = parseDBTime(updatedAt)
		nodes = append(nodes, node)
	}
	return nodes, rows.Err()
}

func (s *SQLite) GetFileNode(ctx context.Context, serverID, nodeID string) (FileNode, error) {
	var node FileNode
	var createdAt, updatedAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT id, server_id, name, base_url, secret, enabled, created_at, updated_at
		FROM file_nodes WHERE id = ? AND server_id = ?
	`, nodeID, serverID).Scan(&node.ID, &node.ServerID, &node.Name, &node.BaseURL, &node.Secret, &node.Enabled, &createdAt, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return FileNode{}, ErrNotFound
	}
	if err != nil {
		return FileNode{}, err
	}
	node.SecretSet = node.Secret != ""
	node.CreatedAt = parseDBTime(createdAt)
	node.UpdatedAt = parseDBTime(updatedAt)
	return node, nil
}

func (s *SQLite) UpdateFileNode(ctx context.Context, serverID, nodeID string, patch FileNodePatch) (FileNode, error) {
	var enabled any
	if patch.Enabled != nil {
		enabled = boolToInt(*patch.Enabled)
	}
	var node FileNode
	var createdAt, updatedAt string
	err := s.db.QueryRowContext(ctx, `
		UPDATE file_nodes SET name = COALESCE(?, name), base_url = COALESCE(?, base_url),
			secret = COALESCE(?, secret), enabled = COALESCE(?, enabled), updated_at = CURRENT_TIMESTAMP
		WHERE id = ? AND server_id = ?
		RETURNING id, server_id, name, base_url, secret != '', enabled, created_at, updated_at
	`, patch.Name, patch.BaseURL, patch.Secret, enabled, nodeID, serverID).
		Scan(&node.ID, &node.ServerID, &node.Name, &node.BaseURL, &node.SecretSet, &node.Enabled, &createdAt, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return FileNode{}, ErrNotFound
	}
	if err != nil {
		return FileNode{}, err
	}
	node.CreatedAt = parseDBTime(createdAt)
	node.UpdatedAt = parseDBTime(updatedAt)
	return node, nil
}

func (s *SQLite) GetChannel(ctx context.Context, channelID string) (Channel, error) {
	var c Channel
	var createdAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT id, server_id, name, sort_order, created_at
		FROM channels WHERE id = ?
	`, channelID).Scan(&c.ID, &c.ServerID, &c.Name, &c.SortOrder, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Channel{}, ErrNotFound
	}
	c.CreatedAt = parseDBTime(createdAt)
	return c, err
}

func (s *SQLite) CreateChannel(ctx context.Context, c Channel) (Channel, error) {
	if c.ID == "" {
		c.ID = ids.New("chn")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Channel{}, err
	}
	defer tx.Rollback()
	var createdAt string
	err = tx.QueryRowContext(ctx, `
		INSERT INTO channels (id, server_id, name, sort_order)
		VALUES (?, ?, ?, ?)
		RETURNING id, server_id, name, sort_order, created_at
	`, c.ID, c.ServerID, c.Name, c.SortOrder).
		Scan(&c.ID, &c.ServerID, &c.Name, &c.SortOrder, &createdAt)
	if err != nil {
		return Channel{}, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO channel_epochs (id, channel_id, epoch_number, reason)
		VALUES (?, ?, 1, 'initial')
	`, ids.New("epc"), c.ID); err != nil {
		return Channel{}, err
	}
	if err := tx.Commit(); err != nil {
		return Channel{}, err
	}
	c.CreatedAt = parseDBTime(createdAt)
	return c, nil
}

func (s *SQLite) UpdateChannel(ctx context.Context, channelID string, name *string, sortOrder *int) (Channel, error) {
	var channel Channel
	var createdAt string
	err := s.db.QueryRowContext(ctx, `
		UPDATE channels
		SET name = COALESCE(?, name), sort_order = COALESCE(?, sort_order)
		WHERE id = ?
		RETURNING id, server_id, name, sort_order, created_at
	`, name, sortOrder, channelID).Scan(
		&channel.ID, &channel.ServerID, &channel.Name, &channel.SortOrder, &createdAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return Channel{}, ErrNotFound
	}
	channel.CreatedAt = parseDBTime(createdAt)
	return channel, err
}

func (s *SQLite) DeleteChannel(ctx context.Context, channelID string) error {
	result, err := s.db.ExecContext(ctx, `
		DELETE FROM channels
		WHERE id = ?
		  AND (SELECT COUNT(*) FROM channels
		       WHERE server_id = (SELECT server_id FROM channels WHERE id = ?)) > 1
	`, channelID, channelID)
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err != nil || count > 0 {
		return err
	}
	if _, err := s.GetChannel(ctx, channelID); err != nil {
		return err
	}
	return ErrLastChannel
}

func (s *SQLite) ListChannels(ctx context.Context, serverID string) ([]Channel, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, server_id, name, sort_order, created_at
		FROM channels WHERE server_id = ? ORDER BY sort_order ASC, created_at ASC
	`, serverID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	channels := []Channel{}
	for rows.Next() {
		var c Channel
		var createdAt string
		if err := rows.Scan(&c.ID, &c.ServerID, &c.Name, &c.SortOrder, &createdAt); err != nil {
			return nil, err
		}
		c.CreatedAt = parseDBTime(createdAt)
		channels = append(channels, c)
	}
	return channels, rows.Err()
}

func (s *SQLite) AddChannelMember(ctx context.Context, channelID, userID, role string) error {
	if role == "" {
		role = "member"
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO channel_members (channel_id, user_id, role, joined_at, left_at)
		VALUES (?, ?, ?, CURRENT_TIMESTAMP, NULL)
		ON CONFLICT(channel_id, user_id) DO UPDATE
		SET role = excluded.role, joined_at = CURRENT_TIMESTAMP, left_at = NULL
	`, channelID, userID, role)
	return err
}

func (s *SQLite) ListChannelMembers(ctx context.Context, channelID string) ([]ChannelMember, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT channel_id, user_id, role, joined_at, left_at
		FROM channel_members
		WHERE channel_id = ?
		  AND left_at IS NULL
		ORDER BY joined_at ASC
	`, channelID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	members := []ChannelMember{}
	for rows.Next() {
		var member ChannelMember
		var joinedAt string
		var leftAt sql.NullString
		if err := rows.Scan(&member.ChannelID, &member.UserID, &member.Role, &joinedAt, &leftAt); err != nil {
			return nil, err
		}
		member.JoinedAt = parseDBTime(joinedAt)
		member.LeftAt = parseOptionalDBTime(leftAt)
		members = append(members, member)
	}
	return members, rows.Err()
}

func (s *SQLite) LeaveChannel(ctx context.Context, channelID, userID string) error {
	_, err := s.db.ExecContext(ctx, `
		UPDATE channel_members SET left_at = CURRENT_TIMESTAMP
		WHERE channel_id = ? AND user_id = ?
	`, channelID, userID)
	return err
}

func (s *SQLite) CreateEpoch(ctx context.Context, channelID, reason string) (ChannelEpoch, error) {
	e := ChannelEpoch{ID: ids.New("epc"), ChannelID: channelID, Reason: reason}
	var createdAt string
	err := s.db.QueryRowContext(ctx, `
		INSERT INTO channel_epochs (id, channel_id, epoch_number, reason)
		VALUES (
			?,
			?,
			(SELECT COALESCE(MAX(epoch_number), 0) + 1 FROM channel_epochs WHERE channel_id = ?),
			?
		)
		RETURNING id, channel_id, epoch_number, reason, created_at
	`, e.ID, channelID, channelID, reason).Scan(&e.ID, &e.ChannelID, &e.EpochNumber, &e.Reason, &createdAt)
	e.CreatedAt = parseDBTime(createdAt)
	return e, err
}

func (s *SQLite) RotateServerChannelEpochs(ctx context.Context, serverID, reason string) ([]ChannelEpoch, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, `SELECT id FROM channels WHERE server_id = ? ORDER BY id`, serverID)
	if err != nil {
		return nil, err
	}
	channelIDs := []string{}
	for rows.Next() {
		var channelID string
		if err := rows.Scan(&channelID); err != nil {
			rows.Close()
			return nil, err
		}
		channelIDs = append(channelIDs, channelID)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	epochs := make([]ChannelEpoch, 0, len(channelIDs))
	for _, channelID := range channelIDs {
		epoch := ChannelEpoch{ID: ids.New("epc"), ChannelID: channelID, Reason: reason}
		var createdAt string
		if err := tx.QueryRowContext(ctx, `
			INSERT INTO channel_epochs (id, channel_id, epoch_number, reason)
			VALUES (?, ?, (SELECT COALESCE(MAX(epoch_number), 0) + 1 FROM channel_epochs WHERE channel_id = ?), ?)
			RETURNING epoch_number, created_at
		`, epoch.ID, channelID, channelID, reason).Scan(&epoch.EpochNumber, &createdAt); err != nil {
			return nil, err
		}
		epoch.CreatedAt = parseDBTime(createdAt)
		epochs = append(epochs, epoch)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return epochs, nil
}

func (s *SQLite) GetLatestEpoch(ctx context.Context, channelID string) (ChannelEpoch, error) {
	var epoch ChannelEpoch
	var createdAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT id, channel_id, epoch_number, reason, created_at
		FROM channel_epochs
		WHERE channel_id = ?
		ORDER BY epoch_number DESC
		LIMIT 1
	`, channelID).Scan(&epoch.ID, &epoch.ChannelID, &epoch.EpochNumber, &epoch.Reason, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ChannelEpoch{}, ErrNotFound
	}
	epoch.CreatedAt = parseDBTime(createdAt)
	return epoch, err
}

func (s *SQLite) ListChannelDevices(ctx context.Context, channelID, epochID string, media bool) ([]ChannelDevice, error) {
	scope, permission := envelopeAccess(media)
	rows, err := s.db.QueryContext(ctx, `
		SELECT d.id, d.user_id, d.label, d.identity_public_key, d.envelope_public_key,
			d.created_at, d.last_seen_at,
			EXISTS(SELECT 1 FROM key_envelopes e WHERE e.epoch_id = ? AND e.scope = ? AND e.recipient_device_id = d.id),
			sm.role, COALESCE(rp.permissions_json, ''), cm.user_id IS NOT NULL
		FROM channels c
		JOIN server_members sm ON sm.server_id = c.server_id
		JOIN user_devices d ON d.user_id = sm.user_id
		LEFT JOIN server_role_permissions rp ON rp.server_id = c.server_id AND rp.role = sm.role
		LEFT JOIN channel_members cm ON cm.channel_id = c.id AND cm.user_id = sm.user_id AND cm.left_at IS NULL
		WHERE c.id = ?
		  AND d.identity_public_key <> ''
		  AND d.envelope_public_key <> ''
		  AND NOT EXISTS (
			SELECT 1 FROM server_bans b
			WHERE b.server_id = c.server_id AND b.user_id = sm.user_id
			  AND b.revoked_at IS NULL
			  AND (b.expires_at IS NULL OR b.expires_at > CURRENT_TIMESTAMP)
		  )
		ORDER BY d.id
	`, epochID, scope, channelID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	devices := []ChannelDevice{}
	for rows.Next() {
		var device ChannelDevice
		var createdAt string
		var lastSeen sql.NullString
		var role, permissionsJSON string
		var channelMember bool
		if err := rows.Scan(&device.ID, &device.UserID, &device.Label, &device.IdentityPublicKey, &device.EnvelopePublicKey, &createdAt, &lastSeen, &device.HasEnvelope, &role, &permissionsJSON, &channelMember); err != nil {
			return nil, err
		}
		if !ValidE2EEDeviceKeys(device.IdentityPublicKey, device.EnvelopePublicKey) {
			continue
		}
		if role != RoleOwner {
			if role != RoleAdmin && !channelMember {
				continue
			}
			permissions := DefaultPermissionsForRole(role)
			if permissionsJSON != "" {
				_ = json.Unmarshal([]byte(permissionsJSON), &permissions)
			}
			if !hasPermission(permissions, permission) {
				continue
			}
		}
		device.CreatedAt = parseDBTime(createdAt)
		device.LastSeenAt = parseOptionalDBTime(lastSeen)
		devices = append(devices, device)
	}
	return devices, rows.Err()
}

func (s *SQLite) StoreEnvelopeBatch(ctx context.Context, channelID, epochID, senderDeviceID, senderUserID string, envelopes []KeyEnvelope, media bool) ([]KeyEnvelope, error) {
	if len(envelopes) == 0 {
		return nil, ErrEnvelopeInvalid
	}
	scope, permission := envelopeAccess(media)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	var serverID, latestEpochID string
	if err := tx.QueryRowContext(ctx, `
		SELECT c.server_id, e.id
		FROM channels c
		JOIN channel_epochs e ON e.channel_id = c.id
		WHERE c.id = ?
		ORDER BY e.epoch_number DESC
		LIMIT 1
	`, channelID).Scan(&serverID, &latestEpochID); errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	} else if err != nil {
		return nil, err
	}
	if latestEpochID != epochID {
		return nil, ErrEpochConflict
	}

	rows, err := tx.QueryContext(ctx, `
		SELECT d.id, d.user_id, d.identity_public_key, d.envelope_public_key,
			sm.role, COALESCE(rp.permissions_json, ''), cm.user_id IS NOT NULL
		FROM channels c
		JOIN server_members sm ON sm.server_id = c.server_id
		JOIN user_devices d ON d.user_id = sm.user_id
		LEFT JOIN server_role_permissions rp ON rp.server_id = c.server_id AND rp.role = sm.role
		LEFT JOIN channel_members cm ON cm.channel_id = c.id AND cm.user_id = sm.user_id AND cm.left_at IS NULL
		WHERE c.id = ?
		  AND d.identity_public_key <> ''
		  AND d.envelope_public_key <> ''
		  AND NOT EXISTS (
			SELECT 1 FROM server_bans b
			WHERE b.server_id = c.server_id AND b.user_id = sm.user_id
			  AND b.revoked_at IS NULL
			  AND (b.expires_at IS NULL OR b.expires_at > CURRENT_TIMESTAMP)
		  )
	`, channelID)
	if err != nil {
		return nil, err
	}
	type eligibleDevice struct {
		userID            string
		identityPublicKey string
	}
	eligible := map[string]eligibleDevice{}
	for rows.Next() {
		var deviceID, userID, identityPublicKey, envelopePublicKey, role, permissionsJSON string
		var channelMember bool
		if err := rows.Scan(&deviceID, &userID, &identityPublicKey, &envelopePublicKey, &role, &permissionsJSON, &channelMember); err != nil {
			rows.Close()
			return nil, err
		}
		if !ValidE2EEDeviceKeys(identityPublicKey, envelopePublicKey) {
			continue
		}
		if role != RoleOwner {
			if role != RoleAdmin && !channelMember {
				continue
			}
			permissions := DefaultPermissionsForRole(role)
			if permissionsJSON != "" {
				_ = json.Unmarshal([]byte(permissionsJSON), &permissions)
			}
			if !hasPermission(permissions, permission) {
				continue
			}
		}
		eligible[deviceID] = eligibleDevice{userID: userID, identityPublicKey: identityPublicKey}
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	sender, ok := eligible[senderDeviceID]
	if !ok || sender.userID != senderUserID {
		return nil, ErrEnvelopeDenied
	}

	existingRows, err := tx.QueryContext(ctx, `SELECT recipient_device_id FROM key_envelopes WHERE epoch_id = ? AND scope = ?`, epochID, scope)
	if err != nil {
		return nil, err
	}
	existing := map[string]bool{}
	for existingRows.Next() {
		var deviceID string
		if err := existingRows.Scan(&deviceID); err != nil {
			existingRows.Close()
			return nil, err
		}
		existing[deviceID] = true
	}
	if err := existingRows.Close(); err != nil {
		return nil, err
	}
	if len(existing) == 0 && len(envelopes) != len(eligible) {
		return nil, ErrEnvelopeConflict
	}
	if len(existing) > 0 && !existing[senderDeviceID] {
		return nil, ErrEnvelopeDenied
	}

	seen := map[string]bool{}
	stored := make([]KeyEnvelope, 0, len(envelopes))
	for _, envelope := range envelopes {
		if existing[envelope.RecipientDeviceID] {
			return nil, ErrEnvelopeConflict
		}
		recipient, ok := eligible[envelope.RecipientDeviceID]
		if !ok || recipient.userID != envelope.RecipientUserID || seen[envelope.RecipientDeviceID] {
			return nil, ErrEnvelopeInvalid
		}
		seen[envelope.RecipientDeviceID] = true
		envelope.ID = ids.New("env")
		envelope.Scope = scope
		envelope.ServerID = &serverID
		envelope.ChannelID = &channelID
		envelope.EpochID = &epochID
		envelope.SenderUserID = senderUserID
		envelope.SenderDeviceID = senderDeviceID
		envelope.SenderIdentityPublicKey = sender.identityPublicKey
		var createdAt string
		err := tx.QueryRowContext(ctx, `
			INSERT INTO key_envelopes (
				id, scope, server_id, channel_id, epoch_id, recipient_user_id,
				recipient_device_id, sender_user_id, sender_device_id, sender_identity_public_key,
				algorithm, ciphertext
			)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			RETURNING created_at
		`, envelope.ID, envelope.Scope, envelope.ServerID, envelope.ChannelID, envelope.EpochID,
			envelope.RecipientUserID, envelope.RecipientDeviceID, envelope.SenderUserID,
			envelope.SenderDeviceID, envelope.SenderIdentityPublicKey, envelope.Algorithm,
			envelope.Ciphertext).Scan(&createdAt)
		if err != nil {
			if strings.Contains(strings.ToLower(err.Error()), "unique") {
				return nil, ErrEnvelopeConflict
			}
			return nil, err
		}
		envelope.CreatedAt = parseDBTime(createdAt)
		stored = append(stored, envelope)
	}
	if len(existing) == 0 && len(seen) != len(eligible) {
		return nil, ErrEnvelopeConflict
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return stored, nil
}

func (s *SQLite) ListEnvelopes(ctx context.Context, recipientDeviceID string, channelID *string, media bool) ([]KeyEnvelope, error) {
	scope, _ := envelopeAccess(media)
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, scope, server_id, channel_id, epoch_id, recipient_user_id,
			recipient_device_id, sender_user_id, sender_device_id, sender_identity_public_key,
			algorithm, ciphertext, created_at
		FROM key_envelopes
		WHERE recipient_device_id = ? AND scope = ?
		  AND (? IS NULL OR channel_id = ?)
		ORDER BY created_at ASC
	`, recipientDeviceID, scope, channelID, channelID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	envelopes := []KeyEnvelope{}
	for rows.Next() {
		var e KeyEnvelope
		var createdAt string
		if err := rows.Scan(&e.ID, &e.Scope, &e.ServerID, &e.ChannelID, &e.EpochID,
			&e.RecipientUserID, &e.RecipientDeviceID, &e.SenderUserID, &e.SenderDeviceID,
			&e.SenderIdentityPublicKey, &e.Algorithm, &e.Ciphertext, &createdAt); err != nil {
			return nil, err
		}
		e.CreatedAt = parseDBTime(createdAt)
		envelopes = append(envelopes, e)
	}
	return envelopes, rows.Err()
}

func envelopeAccess(media bool) (scope, permission string) {
	if media {
		return "media", PermissionVoiceJoin
	}
	return "channel", PermissionChannelMessagesView
}

func (s *SQLite) StoreChannelMessage(ctx context.Context, m ChannelMessage) (ChannelMessage, error) {
	if m.ID == "" {
		m.ID = ids.New("msg")
	}
	metadata, err := json.Marshal(m.Metadata)
	if err != nil {
		return ChannelMessage{}, err
	}
	var createdAt string
	var metadataText string
	err = s.db.QueryRowContext(ctx, `
		INSERT INTO channel_messages (
			id, channel_id, sender_user_id, kind, encryption_mode, epoch_id, body, nonce, metadata
		)
		SELECT ?, c.id, ?, ?, ?, ?, ?, ?, ?
		FROM channels c JOIN os_servers s ON s.id = c.server_id
		WHERE c.id = ? AND s.encryption_mode = ? AND (
			? <> 'e2ee' OR ? = (
				SELECT id FROM channel_epochs WHERE channel_id = c.id ORDER BY epoch_number DESC LIMIT 1
			)
		)
		RETURNING id, channel_id, sender_user_id, kind, encryption_mode, epoch_id, body, nonce, metadata, created_at
	`, m.ID, m.SenderUserID, m.Kind, m.EncryptionMode, m.EpochID, m.Body, m.Nonce, string(metadata), m.ChannelID, m.EncryptionMode, m.EncryptionMode, m.EpochID).
		Scan(&m.ID, &m.ChannelID, &m.SenderUserID, &m.Kind, &m.EncryptionMode, &m.EpochID, &m.Body, &m.Nonce, &metadataText, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		var currentMode string
		modeErr := s.db.QueryRowContext(ctx, `
			SELECT s.encryption_mode FROM channels c
			JOIN os_servers s ON s.id = c.server_id WHERE c.id = ?
		`, m.ChannelID).Scan(&currentMode)
		if modeErr == nil && currentMode != m.EncryptionMode {
			return ChannelMessage{}, ErrEncryptionMode
		}
		if m.EncryptionMode == "e2ee" {
			return ChannelMessage{}, ErrEpochConflict
		}
	}
	if err != nil {
		return ChannelMessage{}, err
	}
	m.CreatedAt = parseDBTime(createdAt)
	_ = json.Unmarshal([]byte(metadataText), &m.Metadata)
	if user, userErr := s.GetUser(ctx, m.SenderUserID); userErr == nil {
		m.SenderDisplayName = user.DisplayName
		m.SenderAvatarVersion = user.AvatarVersion
	}
	return m, nil
}

func (s *SQLite) GetChannelMessage(ctx context.Context, messageID string) (ChannelMessage, error) {
	var message ChannelMessage
	var metadata, createdAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT id, channel_id, sender_user_id, kind, encryption_mode, epoch_id, body, nonce, metadata, created_at
		FROM channel_messages WHERE id = ?
	`, messageID).Scan(
		&message.ID, &message.ChannelID, &message.SenderUserID, &message.Kind,
		&message.EncryptionMode, &message.EpochID, &message.Body, &message.Nonce,
		&metadata, &createdAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return ChannelMessage{}, ErrNotFound
	}
	if err != nil {
		return ChannelMessage{}, err
	}
	_ = json.Unmarshal([]byte(metadata), &message.Metadata)
	message.CreatedAt = parseDBTime(createdAt)
	return message, nil
}

func (s *SQLite) DeleteChannelMessage(ctx context.Context, messageID, removalKind string) error {
	metadata, err := json.Marshal(map[string]string{"removal_kind": removalKind})
	if err != nil {
		return err
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE channel_messages
		SET kind = 'removed', body = '', nonce = '', epoch_id = NULL, metadata = ?
		WHERE id = ?
	`, string(metadata), messageID)
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err == nil && count == 0 {
		return ErrNotFound
	}
	return err
}

func (s *SQLite) ListChannelMessages(ctx context.Context, channelID string, limit int) ([]ChannelMessage, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT m.id, m.channel_id, m.sender_user_id, COALESCE(u.display_name, ''),
			COALESCE(u.avatar_version, 0),
			m.kind, m.encryption_mode, m.epoch_id, m.body, m.nonce, m.metadata, m.created_at
		FROM channel_messages m
		LEFT JOIN users u ON u.id = m.sender_user_id
		WHERE m.channel_id = ?
		ORDER BY m.created_at DESC, m.rowid DESC
		LIMIT ?
	`, channelID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	messages := []ChannelMessage{}
	for rows.Next() {
		var m ChannelMessage
		var metadataText string
		var createdAt string
		if err := rows.Scan(&m.ID, &m.ChannelID, &m.SenderUserID, &m.SenderDisplayName, &m.SenderAvatarVersion, &m.Kind, &m.EncryptionMode, &m.EpochID, &m.Body, &m.Nonce, &metadataText, &createdAt); err != nil {
			return nil, err
		}
		m.CreatedAt = parseDBTime(createdAt)
		_ = json.Unmarshal([]byte(metadataText), &m.Metadata)
		messages = append(messages, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i, j := 0, len(messages)-1; i < j; i, j = i+1, j-1 {
		messages[i], messages[j] = messages[j], messages[i]
	}
	return messages, nil
}

func (s *SQLite) StoreFile(ctx context.Context, f StoredFile) (StoredFile, error) {
	if f.ID == "" {
		f.ID = ids.New("fil")
	}
	metadata, err := json.Marshal(f.Metadata)
	if err != nil {
		return StoredFile{}, err
	}
	var createdAt string
	var metadataText string
	err = s.db.QueryRowContext(ctx, `
		INSERT INTO stored_files (
			id, server_id, channel_id, uploader_user_id, kind, original_name,
			content_type, size_bytes, sha256_hex, relative_path, file_node_id, object_key, encryption_mode, metadata
		)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		RETURNING id, server_id, channel_id, uploader_user_id, kind, original_name,
			content_type, size_bytes, sha256_hex, relative_path, file_node_id, object_key, encryption_mode, metadata, created_at
	`, f.ID, f.ServerID, f.ChannelID, f.UploaderUserID, f.Kind, f.OriginalName, f.ContentType, f.SizeBytes, f.SHA256Hex, f.RelativePath, f.FileNodeID, f.ObjectKey, f.EncryptionMode, string(metadata)).
		Scan(&f.ID, &f.ServerID, &f.ChannelID, &f.UploaderUserID, &f.Kind, &f.OriginalName, &f.ContentType, &f.SizeBytes, &f.SHA256Hex, &f.RelativePath, &f.FileNodeID, &f.ObjectKey, &f.EncryptionMode, &metadataText, &createdAt)
	if err != nil {
		return StoredFile{}, err
	}
	f.CreatedAt = parseDBTime(createdAt)
	_ = json.Unmarshal([]byte(metadataText), &f.Metadata)
	return f, nil
}

func (s *SQLite) GetFile(ctx context.Context, fileID string) (StoredFile, error) {
	var f StoredFile
	var metadataText string
	var createdAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT id, server_id, channel_id, uploader_user_id, kind, original_name,
			content_type, size_bytes, sha256_hex, relative_path, file_node_id, object_key, encryption_mode, metadata, created_at
		FROM stored_files
		WHERE id = ?
	`, fileID).Scan(&f.ID, &f.ServerID, &f.ChannelID, &f.UploaderUserID, &f.Kind, &f.OriginalName, &f.ContentType, &f.SizeBytes, &f.SHA256Hex, &f.RelativePath, &f.FileNodeID, &f.ObjectKey, &f.EncryptionMode, &metadataText, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return StoredFile{}, ErrNotFound
	}
	if err != nil {
		return StoredFile{}, err
	}
	f.CreatedAt = parseDBTime(createdAt)
	_ = json.Unmarshal([]byte(metadataText), &f.Metadata)
	return f, nil
}

func (s *SQLite) DeleteFile(ctx context.Context, fileID string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM stored_files WHERE id = ?`, fileID)
	return err
}

func (s *SQLite) DeleteExpiredChannelHistory(ctx context.Context, before time.Time) error {
	_, err := s.db.ExecContext(ctx, `
		DELETE FROM channel_messages
		WHERE created_at < ?
	`, before.UTC().Format(dbTimeLayout))
	return err
}

func (s *SQLite) CreateAuditLog(ctx context.Context, entry AuditLog) (AuditLog, error) {
	if entry.ID == "" {
		entry.ID = ids.New("aud")
	}
	metadata, err := json.Marshal(entry.Metadata)
	if err != nil {
		return AuditLog{}, err
	}
	var createdAt string
	err = s.db.QueryRowContext(ctx, `
		INSERT INTO audit_logs (id, server_id, actor_user_id, action, target_id, metadata_json)
		VALUES (?, ?, ?, ?, ?, ?)
		RETURNING created_at
	`, entry.ID, entry.ServerID, entry.ActorUserID, entry.Action, entry.TargetID, string(metadata)).Scan(&createdAt)
	entry.CreatedAt = parseDBTime(createdAt)
	return entry, err
}

func (s *SQLite) ListAuditLogs(ctx context.Context, serverID string, limit int) ([]AuditLog, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, server_id, actor_user_id, action, target_id, metadata_json, created_at
		FROM audit_logs WHERE server_id = ? ORDER BY created_at DESC LIMIT ?
	`, serverID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	entries := []AuditLog{}
	for rows.Next() {
		var entry AuditLog
		var metadata, createdAt string
		if err := rows.Scan(&entry.ID, &entry.ServerID, &entry.ActorUserID, &entry.Action, &entry.TargetID, &metadata, &createdAt); err != nil {
			return nil, err
		}
		_ = json.Unmarshal([]byte(metadata), &entry.Metadata)
		entry.CreatedAt = parseDBTime(createdAt)
		entries = append(entries, entry)
	}
	return entries, rows.Err()
}

func (s *SQLite) DeleteExpiredRetainedMessages(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
		DELETE FROM channel_messages
		WHERE id IN (
			SELECT m.id
			FROM channel_messages m
			JOIN channels c ON c.id = m.channel_id
			JOIN os_servers srv ON srv.id = c.server_id
			WHERE srv.history_retention_days >= 0
			  AND m.created_at < datetime('now', '-' || srv.history_retention_days || ' days')
		)
	`)
	return err
}

func (s *SQLite) ListExpiredRetainedFiles(ctx context.Context) ([]StoredFile, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT f.id, f.server_id, f.channel_id, f.uploader_user_id, f.kind,
			f.original_name, f.content_type, f.size_bytes, f.sha256_hex,
			f.relative_path, f.file_node_id, f.object_key, f.encryption_mode,
			f.metadata, f.created_at
		FROM stored_files f
		LEFT JOIN channels c ON c.id = f.channel_id
		LEFT JOIN os_servers srv ON srv.id = c.server_id
		WHERE f.channel_id IS NULL
		   OR (srv.history_retention_days >= 0
		       AND f.created_at < datetime('now', '-' || srv.history_retention_days || ' days'))
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []StoredFile{}
	for rows.Next() {
		var file StoredFile
		var metadataText, createdAt string
		if err := rows.Scan(&file.ID, &file.ServerID, &file.ChannelID, &file.UploaderUserID, &file.Kind, &file.OriginalName, &file.ContentType, &file.SizeBytes, &file.SHA256Hex, &file.RelativePath, &file.FileNodeID, &file.ObjectKey, &file.EncryptionMode, &metadataText, &createdAt); err != nil {
			return nil, err
		}
		file.CreatedAt = parseDBTime(createdAt)
		_ = json.Unmarshal([]byte(metadataText), &file.Metadata)
		result = append(result, file)
	}
	return result, rows.Err()
}

const dbTimeLayout = "2006-01-02 15:04:05"

func parseDBTime(value string) time.Time {
	if value == "" {
		return time.Time{}
	}
	for _, layout := range []string{
		time.RFC3339Nano,
		time.RFC3339,
		"2006-01-02 15:04:05.999999999-07:00",
		"2006-01-02 15:04:05.999999999",
		dbTimeLayout,
	} {
		t, err := time.Parse(layout, value)
		if err == nil {
			return t.UTC()
		}
	}
	return time.Time{}
}

func parseOptionalDBTime(value sql.NullString) *time.Time {
	if !value.Valid {
		return nil
	}
	t := parseDBTime(value.String)
	return &t
}

func boolToInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

const (
	RoleOwner = "owner"
	RoleAdmin = "admin"
	RoleUser  = "user"

	PermissionServerProfileUpdate              = "server.profile.update"
	PermissionServerSettingsUpdate             = "server.settings.update"
	PermissionServerTransportUpdate            = "server.transport.update"
	PermissionAuditView                        = "audit.view"
	PermissionChannelCreate                    = "channel.create"
	PermissionChannelEdit                      = "channel.edit"
	PermissionChannelDelete                    = "channel.delete"
	PermissionChannelReorder                   = "channel.reorder"
	PermissionMemberView                       = "member.view"
	PermissionMemberMove                       = "member.move"
	PermissionMemberKick                       = "member.kick"
	PermissionMemberBan                        = "member.ban"
	PermissionMemberUnban                      = "member.unban"
	PermissionMemberMute                       = "member.mute"
	PermissionMemberDeafen                     = "member.deafen"
	PermissionChannelMessagesView              = "channel.messages.view"
	PermissionChannelMessagesSendText          = "channel.messages.send_text"
	PermissionChannelMessagesSendImage         = "channel.messages.send_image"
	PermissionChannelMessagesSendFile          = "channel.messages.send_file"
	PermissionChannelAttachmentsDownload       = "channel.attachments.download"
	PermissionChannelMessagesManage            = "channel.messages.manage"
	PermissionVoiceJoin                        = "voice.join"
	PermissionVoiceSpeak                       = "voice.speak"
	PermissionVoiceScreenShare                 = "voice.screen_share"
	PermissionVoiceScreenShareResolution720p   = "voice.screen_share.resolution.720p"
	PermissionVoiceScreenShareResolution1080p  = "voice.screen_share.resolution.1080p"
	PermissionVoiceScreenShareResolutionSource = "voice.screen_share.resolution.source"
	PermissionVoiceScreenShareFPS15            = "voice.screen_share.fps.15"
	PermissionVoiceScreenShareFPS30            = "voice.screen_share.fps.30"
	PermissionVoiceScreenShareFPS60            = "voice.screen_share.fps.60"
	PermissionVoiceBypassLimit                 = "voice.bypass_limit"
	PermissionDirectSendText                   = "direct.send_text"
	PermissionDirectSendImage                  = "direct.send_image"
	PermissionDirectSendFile                   = "direct.send_file"
)

func NormalizeServerRole(role string) string {
	switch role {
	case RoleOwner, RoleAdmin, RoleUser:
		return role
	default:
		return RoleUser
	}
}

func AllPermissions() []string {
	return DelegablePermissions()
}

func AdminPermissions() []string {
	return []string{
		PermissionChannelCreate, PermissionChannelDelete, PermissionChannelReorder,
		PermissionMemberView, PermissionMemberMove, PermissionMemberKick,
		PermissionMemberBan, PermissionMemberUnban, PermissionMemberMute, PermissionMemberDeafen,
		PermissionChannelMessagesView, PermissionChannelMessagesSendText,
		PermissionChannelMessagesSendImage, PermissionChannelMessagesSendFile,
		PermissionChannelAttachmentsDownload,
		PermissionVoiceJoin, PermissionVoiceSpeak, PermissionVoiceScreenShare,
		PermissionVoiceScreenShareResolution720p, PermissionVoiceScreenShareResolution1080p,
		PermissionVoiceScreenShareResolutionSource, PermissionVoiceScreenShareFPS15,
		PermissionVoiceScreenShareFPS30, PermissionVoiceScreenShareFPS60,
		PermissionVoiceBypassLimit, PermissionDirectSendText,
		PermissionDirectSendImage, PermissionDirectSendFile,
	}
}

func UserPermissions() []string {
	return []string{
		PermissionChannelMessagesView, PermissionChannelMessagesSendText,
		PermissionChannelMessagesSendImage, PermissionChannelMessagesSendFile,
		PermissionChannelAttachmentsDownload,
		PermissionVoiceJoin, PermissionVoiceSpeak, PermissionVoiceScreenShare,
		PermissionVoiceScreenShareResolution720p, PermissionVoiceScreenShareResolution1080p,
		PermissionVoiceScreenShareResolutionSource, PermissionVoiceScreenShareFPS15,
		PermissionVoiceScreenShareFPS30, PermissionVoiceScreenShareFPS60,
		PermissionDirectSendText, PermissionDirectSendImage, PermissionDirectSendFile,
	}
}

func DefaultPermissionsForRole(role string) []string {
	if role == RoleAdmin {
		return AdminPermissions()
	}
	if role == RoleUser {
		return UserPermissions()
	}
	if role == RoleOwner {
		return AllPermissions()
	}
	return nil
}

func DelegablePermissions() []string {
	return []string{
		PermissionServerProfileUpdate, PermissionServerSettingsUpdate,
		PermissionServerTransportUpdate, PermissionAuditView,
		PermissionChannelCreate, PermissionChannelEdit, PermissionChannelDelete,
		PermissionChannelReorder, PermissionMemberView, PermissionMemberMove,
		PermissionMemberKick, PermissionMemberBan, PermissionMemberUnban,
		PermissionMemberMute, PermissionMemberDeafen, PermissionChannelMessagesView,
		PermissionChannelMessagesSendText, PermissionChannelMessagesSendImage,
		PermissionChannelMessagesSendFile,
		PermissionChannelAttachmentsDownload, PermissionChannelMessagesManage,
		PermissionVoiceJoin, PermissionVoiceSpeak, PermissionVoiceScreenShare,
		PermissionVoiceScreenShareResolution720p, PermissionVoiceScreenShareResolution1080p,
		PermissionVoiceScreenShareResolutionSource, PermissionVoiceScreenShareFPS15,
		PermissionVoiceScreenShareFPS30, PermissionVoiceScreenShareFPS60,
		PermissionVoiceBypassLimit, PermissionDirectSendText,
		PermissionDirectSendImage, PermissionDirectSendFile,
	}
}

func filterDelegablePermissions(values []string) []string {
	allowed := make(map[string]bool, len(DelegablePermissions()))
	for _, permission := range DelegablePermissions() {
		allowed[permission] = true
	}
	result := make([]string, 0, len(values))
	for _, permission := range values {
		if allowed[permission] {
			result = append(result, permission)
		}
	}
	return result
}

func ScreenShareQualityPermissions() []string {
	return []string{
		PermissionVoiceScreenShareResolution720p,
		PermissionVoiceScreenShareResolution1080p,
		PermissionVoiceScreenShareResolutionSource,
		PermissionVoiceScreenShareFPS15,
		PermissionVoiceScreenShareFPS30,
		PermissionVoiceScreenShareFPS60,
	}
}

func ScreenShareQualityAllowed(permissions []string, resolution string, fps int) bool {
	resolutionPermission := map[string]string{
		"720p":   PermissionVoiceScreenShareResolution720p,
		"1080p":  PermissionVoiceScreenShareResolution1080p,
		"source": PermissionVoiceScreenShareResolutionSource,
	}[resolution]
	fpsPermission := map[int]string{
		15: PermissionVoiceScreenShareFPS15,
		30: PermissionVoiceScreenShareFPS30,
		60: PermissionVoiceScreenShareFPS60,
	}[fps]
	return resolutionPermission != "" && fpsPermission != "" &&
		hasPermission(permissions, resolutionPermission) && hasPermission(permissions, fpsPermission)
}

func withDefaultScreenShareQualityPermissions(values []string) []string {
	for _, permission := range ScreenShareQualityPermissions() {
		if hasPermission(values, permission) {
			return values
		}
	}
	return append(values, ScreenShareQualityPermissions()...)
}

func DefaultScreenSharePolicy() ScreenSharePolicy {
	allowed := []ScreenShareCapability{
		{Resolution: "720p", FPS: 15},
		{Resolution: "720p", FPS: 30},
		{Resolution: "720p", FPS: 60},
		{Resolution: "1080p", FPS: 15},
		{Resolution: "1080p", FPS: 30},
		{Resolution: "1080p", FPS: 60},
		{Resolution: "source", FPS: 15},
		{Resolution: "source", FPS: 30},
		{Resolution: "source", FPS: 60},
	}
	return ScreenSharePolicy{
		P2P: ScreenShareModePolicy{
			Enabled: false,
			Allowed: append([]ScreenShareCapability(nil), allowed...),
		},
		Relay: ScreenShareModePolicy{
			Enabled: true,
			Allowed: append([]ScreenShareCapability(nil), allowed...),
		},
	}
}

func decodeScreenSharePolicy(value string) ScreenSharePolicy {
	if value == "" {
		return DefaultScreenSharePolicy()
	}
	var policy ScreenSharePolicy
	if err := json.Unmarshal([]byte(value), &policy); err != nil {
		return DefaultScreenSharePolicy()
	}
	for _, mode := range []ScreenShareModePolicy{policy.P2P, policy.Relay} {
		if !completeScreenShareCapabilities(mode.Allowed) {
			return DefaultScreenSharePolicy()
		}
	}
	policy.P2P.Enabled = false
	return policy
}

func decodeScreenShareBitrateLimits(value string) ScreenShareBitrateLimits {
	var limits ScreenShareBitrateLimits
	if value == "" || json.Unmarshal([]byte(value), &limits) != nil || !limits.Valid() {
		return DefaultScreenShareBitrateLimits()
	}
	return limits
}

func completeScreenShareCapabilities(values []ScreenShareCapability) bool {
	if len(values) != 9 {
		return false
	}
	seen := make(map[string]bool, len(values))
	for _, capability := range values {
		key := capability.Resolution + ":" + strconv.Itoa(capability.FPS)
		if seen[key] {
			return false
		}
		seen[key] = true
	}
	for _, resolution := range []string{"720p", "1080p", "source"} {
		for _, fps := range []int{15, 30, 60} {
			if !seen[resolution+":"+strconv.Itoa(fps)] {
				return false
			}
		}
	}
	return true
}

func hasPermission(permissions []string, permission string) bool {
	for _, value := range permissions {
		if value == permission {
			return true
		}
	}
	return false
}
