package database

import (
	"context"
	"path/filepath"
	"testing"
)

func TestMigrateFlattensLegacyChannelHierarchy(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "openspeak.db")
	db, err := OpenSQLite(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `ALTER TABLE channels ADD COLUMN parent_id TEXT REFERENCES channels(id) ON DELETE CASCADE`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO os_servers (id, name, file_root) VALUES ('server', 'Server', '.')`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO channels (id, server_id, name, parent_id) VALUES ('parent', 'server', 'Parent', NULL), ('child', 'server', 'Child', 'parent')`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	db, err = OpenSQLite(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var nested int
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM channels WHERE parent_id IS NOT NULL`).Scan(&nested); err != nil {
		t.Fatal(err)
	}
	if nested != 0 {
		t.Fatalf("nested channels remaining = %d", nested)
	}
}

func TestMigrateClearsInterruptedTLSActivation(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "openspeak.db")
	db, err := OpenSQLite(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO os_servers (id, name, file_root, encryption_mode, tls_status) VALUES ('server', 'Server', '.', 'transport', 'pending')`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	db, err = OpenSQLite(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var mode, status, tlsError string
	if err := db.QueryRowContext(ctx, `SELECT encryption_mode, tls_status, tls_error FROM os_servers WHERE id = 'server'`).Scan(&mode, &status, &tlsError); err != nil {
		t.Fatal(err)
	}
	if mode != "none" || status != "error" || tlsError == "" {
		t.Fatalf("mode=%q status=%q error=%q", mode, status, tlsError)
	}
}

func TestMigrateClearsPrototypeDeviceKeys(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "openspeak.db")
	db, err := OpenSQLite(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO users (id, display_name) VALUES ('user', 'User')`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `
		INSERT INTO user_devices (id, user_id, identity_public_key, envelope_public_key)
		VALUES ('device', 'user', 'prototype-identity-public-key', 'prototype-envelope-public-key')
	`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	db, err = OpenSQLite(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var identityKey, envelopeKey string
	if err := db.QueryRowContext(ctx, `SELECT identity_public_key, envelope_public_key FROM user_devices WHERE id = 'device'`).Scan(&identityKey, &envelopeKey); err != nil {
		t.Fatal(err)
	}
	if identityKey != "" || envelopeKey != "" {
		t.Fatalf("prototype keys not cleared: identity=%q envelope=%q", identityKey, envelopeKey)
	}
}

func TestMigrateCreatesInitialEpochForExistingChannel(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "openspeak.db")
	db, err := OpenSQLite(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO os_servers (id, name, file_root) VALUES ('server', 'Server', '.')`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO channels (id, server_id, name) VALUES ('channel', 'server', 'General')`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	db, err = OpenSQLite(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var count, number int
	var reason string
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*), epoch_number, reason FROM channel_epochs WHERE channel_id = 'channel'`).Scan(&count, &number, &reason); err != nil {
		t.Fatal(err)
	}
	if count != 1 || number != 1 || reason != "initial" {
		t.Fatalf("epoch count=%d number=%d reason=%q", count, number, reason)
	}
}
