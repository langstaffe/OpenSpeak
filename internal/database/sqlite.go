package database

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

func OpenSQLite(ctx context.Context, databasePath string) (*sql.DB, error) {
	if err := os.MkdirAll(filepath.Dir(databasePath), 0o750); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", databasePath+"?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	if err := Migrate(ctx, db); err != nil {
		_ = db.Close()
		return nil, err
	}
	return db, nil
}

func Migrate(ctx context.Context, db *sql.DB) error {
	if _, err := db.ExecContext(ctx, schemaSQL); err != nil {
		return err
	}
	migrations := []struct {
		table  string
		column string
		sql    string
	}{
		{"users", "avatar_version", "ALTER TABLE users ADD COLUMN avatar_version INTEGER NOT NULL DEFAULT 0"},
		{"users", "avatar_hash", "ALTER TABLE users ADD COLUMN avatar_hash TEXT NOT NULL DEFAULT ''"},
		{"os_servers", "avatar_version", "ALTER TABLE os_servers ADD COLUMN avatar_version INTEGER NOT NULL DEFAULT 0"},
		{"os_servers", "avatar_hash", "ALTER TABLE os_servers ADD COLUMN avatar_hash TEXT NOT NULL DEFAULT ''"},
		{"os_servers", "server_password_hash", "ALTER TABLE os_servers ADD COLUMN server_password_hash TEXT NOT NULL DEFAULT ''"},
		{"os_servers", "screen_share_policy_json", "ALTER TABLE os_servers ADD COLUMN screen_share_policy_json TEXT NOT NULL DEFAULT ''"},
		{"os_servers", "default_channel_id", "ALTER TABLE os_servers ADD COLUMN default_channel_id TEXT REFERENCES channels(id) ON DELETE SET NULL"},
		{"os_servers", "attachment_external_enabled", "ALTER TABLE os_servers ADD COLUMN attachment_external_enabled INTEGER NOT NULL DEFAULT 0"},
		{"os_servers", "attachment_file_node_id", "ALTER TABLE os_servers ADD COLUMN attachment_file_node_id TEXT REFERENCES file_nodes(id) ON DELETE SET NULL"},
		{"os_servers", "voice_audio_bitrate_kbps", "ALTER TABLE os_servers ADD COLUMN voice_audio_bitrate_kbps INTEGER NOT NULL DEFAULT 64"},
		{"os_servers", "screen_share_bitrate_limits_json", "ALTER TABLE os_servers ADD COLUMN screen_share_bitrate_limits_json TEXT NOT NULL DEFAULT ''"},
		{"os_servers", "message_retract_window_minutes", "ALTER TABLE os_servers ADD COLUMN message_retract_window_minutes INTEGER NOT NULL DEFAULT 30"},
		{"os_servers", "tls_certificate_type", "ALTER TABLE os_servers ADD COLUMN tls_certificate_type TEXT NOT NULL DEFAULT ''"},
		{"os_servers", "tls_identifier", "ALTER TABLE os_servers ADD COLUMN tls_identifier TEXT NOT NULL DEFAULT ''"},
		{"os_servers", "tls_status", "ALTER TABLE os_servers ADD COLUMN tls_status TEXT NOT NULL DEFAULT 'disabled'"},
		{"os_servers", "tls_error", "ALTER TABLE os_servers ADD COLUMN tls_error TEXT NOT NULL DEFAULT ''"},
		{"os_servers", "tls_expires_at", "ALTER TABLE os_servers ADD COLUMN tls_expires_at DATETIME"},
		{"stored_files", "file_node_id", "ALTER TABLE stored_files ADD COLUMN file_node_id TEXT REFERENCES file_nodes(id) ON DELETE SET NULL"},
		{"stored_files", "object_key", "ALTER TABLE stored_files ADD COLUMN object_key TEXT NOT NULL DEFAULT ''"},
		{"key_envelopes", "sender_device_id", "ALTER TABLE key_envelopes ADD COLUMN sender_device_id TEXT NOT NULL DEFAULT ''"},
		{"key_envelopes", "sender_identity_public_key", "ALTER TABLE key_envelopes ADD COLUMN sender_identity_public_key TEXT NOT NULL DEFAULT ''"},
	}
	for _, migration := range migrations {
		ok, err := columnExists(ctx, db, migration.table, migration.column)
		if err != nil {
			return err
		}
		if !ok {
			if _, err := db.ExecContext(ctx, migration.sql); err != nil {
				return err
			}
		}
	}
	if ok, err := columnExists(ctx, db, "channels", "parent_id"); err != nil {
		return err
	} else if ok {
		if _, err := db.ExecContext(ctx, `UPDATE channels SET parent_id = NULL WHERE parent_id IS NOT NULL`); err != nil {
			return err
		}
	}
	if _, err := db.ExecContext(ctx, `UPDATE owner_security SET recovery_public_key = '' WHERE recovery_public_key <> ''`); err != nil {
		return err
	}
	if _, err := db.ExecContext(ctx, `
		UPDATE user_devices
		SET identity_public_key = '', envelope_public_key = ''
		WHERE identity_public_key = 'prototype-identity-public-key'
		  AND envelope_public_key = 'prototype-envelope-public-key'
	`); err != nil {
		return err
	}
	if _, err := db.ExecContext(ctx, `UPDATE os_servers SET encryption_mode = 'none' WHERE tls_status <> 'active' AND encryption_mode IN ('transport', 'e2ee')`); err != nil {
		return err
	}
	if _, err := db.ExecContext(ctx, `UPDATE os_servers SET tls_status = 'error', tls_error = 'TLS 启用流程被服务器重启中断，请重新启用' WHERE tls_status = 'pending'`); err != nil {
		return err
	}
	if _, err := db.ExecContext(ctx, `
		INSERT INTO channel_epochs (id, channel_id, epoch_number, reason)
		SELECT 'epc_' || lower(hex(randomblob(16))), c.id, 1, 'initial'
		FROM channels c
		WHERE NOT EXISTS (SELECT 1 FROM channel_epochs e WHERE e.channel_id = c.id)
	`); err != nil {
		return err
	}
	if _, err := db.ExecContext(ctx, `
		DELETE FROM key_envelopes
		WHERE epoch_id IS NOT NULL AND rowid NOT IN (
			SELECT MIN(rowid) FROM key_envelopes WHERE epoch_id IS NOT NULL GROUP BY epoch_id, scope, recipient_device_id
		)
	`); err != nil {
		return err
	}
	if _, err := db.ExecContext(ctx, `DROP INDEX IF EXISTS idx_key_envelopes_epoch_device`); err != nil {
		return err
	}
	if _, err := db.ExecContext(ctx, `CREATE UNIQUE INDEX IF NOT EXISTS idx_key_envelopes_epoch_scope_device ON key_envelopes(epoch_id, scope, recipient_device_id)`); err != nil {
		return err
	}
	_, err := db.ExecContext(ctx, `DROP INDEX IF EXISTS idx_users_username`)
	return err
}

func columnExists(ctx context.Context, db *sql.DB, table, column string) (bool, error) {
	rows, err := db.QueryContext(ctx, `PRAGMA table_info(`+table+`)`)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name string
		var typ string
		var notNull int
		var defaultValue any
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return false, err
		}
		if name == column {
			return true, nil
		}
	}
	return false, rows.Err()
}

const schemaSQL = `
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS users (
	id TEXT PRIMARY KEY,
	display_name TEXT NOT NULL,
	avatar_version INTEGER NOT NULL DEFAULT 0,
	avatar_hash TEXT NOT NULL DEFAULT '',
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS user_devices (
	id TEXT PRIMARY KEY,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	label TEXT NOT NULL DEFAULT '',
	identity_public_key TEXT NOT NULL DEFAULT '',
	envelope_public_key TEXT NOT NULL DEFAULT '',
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	last_seen_at DATETIME
);

CREATE TABLE IF NOT EXISTS os_servers (
	id TEXT PRIMARY KEY,
	name TEXT NOT NULL,
	avatar_version INTEGER NOT NULL DEFAULT 0,
	avatar_hash TEXT NOT NULL DEFAULT '',
	encryption_mode TEXT NOT NULL DEFAULT 'none',
	file_root TEXT NOT NULL,
	history_retention_days INTEGER NOT NULL DEFAULT 30,
	server_password_hash TEXT NOT NULL DEFAULT '',
	screen_share_policy_json TEXT NOT NULL DEFAULT '',
	default_channel_id TEXT REFERENCES channels(id) ON DELETE SET NULL,
	attachment_external_enabled INTEGER NOT NULL DEFAULT 0,
	attachment_file_node_id TEXT REFERENCES file_nodes(id) ON DELETE SET NULL,
	voice_audio_bitrate_kbps INTEGER NOT NULL DEFAULT 64,
	screen_share_bitrate_limits_json TEXT NOT NULL DEFAULT '',
	message_retract_window_minutes INTEGER NOT NULL DEFAULT 30,
	tls_certificate_type TEXT NOT NULL DEFAULT '',
	tls_identifier TEXT NOT NULL DEFAULT '',
	tls_status TEXT NOT NULL DEFAULT 'disabled',
	tls_error TEXT NOT NULL DEFAULT '',
	tls_expires_at DATETIME,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS server_members (
	server_id TEXT NOT NULL REFERENCES os_servers(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	role TEXT NOT NULL DEFAULT 'user',
	permissions_json TEXT NOT NULL DEFAULT '[]',
	joined_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	PRIMARY KEY(server_id, user_id)
);

CREATE TABLE IF NOT EXISTS server_role_permissions (
	server_id TEXT NOT NULL REFERENCES os_servers(id) ON DELETE CASCADE,
	role TEXT NOT NULL CHECK(role IN ('admin', 'user')),
	permissions_json TEXT NOT NULL DEFAULT '[]',
	updated_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
	updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	PRIMARY KEY(server_id, role)
);

CREATE TABLE IF NOT EXISTS audit_logs (
	id TEXT PRIMARY KEY,
	server_id TEXT NOT NULL REFERENCES os_servers(id) ON DELETE CASCADE,
	actor_user_id TEXT NOT NULL,
	action TEXT NOT NULL,
	target_id TEXT NOT NULL DEFAULT '',
	metadata_json TEXT NOT NULL DEFAULT '{}',
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_server_created
	ON audit_logs(server_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_server_members_single_owner
	ON server_members(server_id)
	WHERE role = 'owner';

CREATE TABLE IF NOT EXISTS client_installations (
	server_id TEXT NOT NULL REFERENCES os_servers(id) ON DELETE CASCADE,
	installation_hash TEXT NOT NULL,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	first_seen_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	last_seen_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	PRIMARY KEY(server_id, installation_hash),
	UNIQUE(server_id, user_id)
);

CREATE TABLE IF NOT EXISTS member_aliases (
	server_id TEXT NOT NULL REFERENCES os_servers(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	display_name TEXT NOT NULL,
	first_used_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	last_used_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	PRIMARY KEY(server_id, user_id, display_name)
);

CREATE TABLE IF NOT EXISTS server_bans (
	id TEXT PRIMARY KEY,
	server_id TEXT NOT NULL REFERENCES os_servers(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	installation_hash TEXT NOT NULL,
	reason TEXT NOT NULL DEFAULT '',
	created_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	expires_at DATETIME,
	revoked_at DATETIME,
	revoked_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_server_bans_active_installation
	ON server_bans(server_id, installation_hash, revoked_at, expires_at);

CREATE TABLE IF NOT EXISTS owner_security (
	server_id TEXT PRIMARY KEY REFERENCES os_servers(id) ON DELETE CASCADE,
	owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	claim_token_hash TEXT NOT NULL DEFAULT '',
	claim_expires_at DATETIME,
	recovery_public_key TEXT NOT NULL DEFAULT '',
	auth_generation INTEGER NOT NULL DEFAULT 1,
	claimed_at DATETIME,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_owner_security_owner_user
	ON owner_security(owner_user_id);

CREATE TABLE IF NOT EXISTS owner_devices (
	id TEXT PRIMARY KEY,
	server_id TEXT NOT NULL REFERENCES owner_security(server_id) ON DELETE CASCADE,
	label TEXT NOT NULL DEFAULT '',
	platform TEXT NOT NULL DEFAULT '',
	client_version TEXT NOT NULL DEFAULT '',
	public_key TEXT NOT NULL,
	public_key_fingerprint TEXT NOT NULL,
	authorization_method TEXT NOT NULL,
	session_generation INTEGER NOT NULL DEFAULT 1,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	last_seen_at DATETIME,
	revoked_at DATETIME,
	UNIQUE(server_id, public_key)
);

CREATE INDEX IF NOT EXISTS idx_owner_devices_server_active
	ON owner_devices(server_id, revoked_at);

CREATE TABLE IF NOT EXISTS owner_pairing_tokens (
	id TEXT PRIMARY KEY,
	server_id TEXT NOT NULL REFERENCES owner_security(server_id) ON DELETE CASCADE,
	token_hash TEXT NOT NULL UNIQUE,
	created_by_device_id TEXT NOT NULL REFERENCES owner_devices(id) ON DELETE CASCADE,
	expires_at DATETIME NOT NULL,
	consumed_at DATETIME,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS media_nodes (
	id TEXT PRIMARY KEY,
	server_id TEXT NOT NULL REFERENCES os_servers(id) ON DELETE CASCADE,
	name TEXT NOT NULL,
	livekit_url TEXT NOT NULL,
	api_key TEXT NOT NULL,
	api_secret TEXT NOT NULL,
	region TEXT NOT NULL DEFAULT '',
	weight INTEGER NOT NULL DEFAULT 100,
	enabled INTEGER NOT NULL DEFAULT 1,
	draining INTEGER NOT NULL DEFAULT 0,
	max_relay_bitrate_kbps INTEGER NOT NULL DEFAULT 0,
	max_rooms INTEGER NOT NULL DEFAULT 0,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_media_nodes_server_enabled
	ON media_nodes(server_id, enabled, draining, weight DESC);

CREATE TABLE IF NOT EXISTS file_nodes (
	id TEXT PRIMARY KEY,
	server_id TEXT NOT NULL REFERENCES os_servers(id) ON DELETE CASCADE,
	name TEXT NOT NULL,
	base_url TEXT NOT NULL,
	secret TEXT NOT NULL,
	enabled INTEGER NOT NULL DEFAULT 1,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_file_nodes_server_enabled
	ON file_nodes(server_id, enabled);

CREATE TABLE IF NOT EXISTS channels (
	id TEXT PRIMARY KEY,
	server_id TEXT NOT NULL REFERENCES os_servers(id) ON DELETE CASCADE,
	name TEXT NOT NULL,
	sort_order INTEGER NOT NULL DEFAULT 0,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS channel_members (
	channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	role TEXT NOT NULL DEFAULT 'member',
	joined_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	left_at DATETIME,
	PRIMARY KEY(channel_id, user_id)
);

CREATE TABLE IF NOT EXISTS channel_epochs (
	id TEXT PRIMARY KEY,
	channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
	epoch_number INTEGER NOT NULL,
	reason TEXT NOT NULL,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	UNIQUE(channel_id, epoch_number)
);

CREATE TABLE IF NOT EXISTS key_envelopes (
	id TEXT PRIMARY KEY,
	scope TEXT NOT NULL,
	server_id TEXT REFERENCES os_servers(id) ON DELETE CASCADE,
	channel_id TEXT REFERENCES channels(id) ON DELETE CASCADE,
	epoch_id TEXT REFERENCES channel_epochs(id) ON DELETE CASCADE,
	recipient_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	recipient_device_id TEXT NOT NULL REFERENCES user_devices(id) ON DELETE CASCADE,
	sender_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	sender_device_id TEXT NOT NULL DEFAULT '',
	sender_identity_public_key TEXT NOT NULL DEFAULT '',
	algorithm TEXT NOT NULL,
	ciphertext TEXT NOT NULL,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS channel_messages (
	id TEXT PRIMARY KEY,
	channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
	sender_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	kind TEXT NOT NULL,
	encryption_mode TEXT NOT NULL,
	epoch_id TEXT REFERENCES channel_epochs(id) ON DELETE SET NULL,
	body TEXT NOT NULL,
	nonce TEXT NOT NULL DEFAULT '',
	metadata TEXT NOT NULL DEFAULT '{}',
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_channel_messages_channel_created
	ON channel_messages(channel_id, created_at DESC);

CREATE TABLE IF NOT EXISTS stored_files (
	id TEXT PRIMARY KEY,
	server_id TEXT NOT NULL REFERENCES os_servers(id) ON DELETE CASCADE,
	channel_id TEXT REFERENCES channels(id) ON DELETE SET NULL,
	uploader_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	kind TEXT NOT NULL,
	original_name TEXT NOT NULL,
	content_type TEXT NOT NULL,
	size_bytes INTEGER NOT NULL,
	sha256_hex TEXT NOT NULL,
	relative_path TEXT NOT NULL,
	file_node_id TEXT REFERENCES file_nodes(id) ON DELETE SET NULL,
	object_key TEXT NOT NULL DEFAULT '',
	encryption_mode TEXT NOT NULL DEFAULT 'none',
	metadata TEXT NOT NULL DEFAULT '{}',
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_stored_files_server_created
	ON stored_files(server_id, created_at DESC);
`
