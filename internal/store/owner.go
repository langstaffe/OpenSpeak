package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"openspeak/internal/ids"
)

var (
	ErrOwnerAlreadyClaimed = errors.New("owner already claimed")
	ErrInvalidOwnerToken   = errors.New("invalid or expired owner token")
	ErrOwnerDeviceRevoked  = errors.New("owner device revoked")
	ErrLastOwnerDevice     = errors.New("cannot revoke the last owner device")
)

func (s *SQLite) CreateOwnerSecurity(ctx context.Context, serverID, ownerUserID, claimTokenHash string, claimExpiresAt time.Time) (OwnerSecurity, error) {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO owner_security (
			server_id, owner_user_id, claim_token_hash, claim_expires_at
		) VALUES (?, ?, ?, ?)
	`, serverID, ownerUserID, claimTokenHash, claimExpiresAt.UTC())
	if err != nil {
		return OwnerSecurity{}, err
	}
	return s.GetOwnerSecurity(ctx, serverID)
}

func (s *SQLite) EnsureOwnerSecurity(ctx context.Context, serverID, claimTokenHash string, claimExpiresAt time.Time) (OwnerSecurity, error) {
	var ownerUserID string
	err := s.db.QueryRowContext(ctx, `
		SELECT user_id FROM server_members
		WHERE server_id = ? AND role = 'owner'
	`, serverID).Scan(&ownerUserID)
	if errors.Is(err, sql.ErrNoRows) {
		return OwnerSecurity{}, ErrNotFound
	}
	if err != nil {
		return OwnerSecurity{}, err
	}
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO owner_security (
			server_id, owner_user_id, claim_token_hash, claim_expires_at
		) VALUES (?, ?, ?, ?)
		ON CONFLICT(server_id) DO NOTHING
	`, serverID, ownerUserID, claimTokenHash, claimExpiresAt.UTC())
	if err != nil {
		return OwnerSecurity{}, err
	}
	return s.GetOwnerSecurity(ctx, serverID)
}

func (s *SQLite) GetOwnerSecurity(ctx context.Context, serverID string) (OwnerSecurity, error) {
	return scanOwnerSecurity(s.db.QueryRowContext(ctx, `
		SELECT server_id, owner_user_id, auth_generation,
			claimed_at IS NOT NULL, claim_expires_at, created_at, updated_at
		FROM owner_security WHERE server_id = ?
	`, serverID))
}

func (s *SQLite) FindOwnerSecurityByUser(ctx context.Context, userID string) (OwnerSecurity, error) {
	return scanOwnerSecurity(s.db.QueryRowContext(ctx, `
		SELECT server_id, owner_user_id, auth_generation,
			claimed_at IS NOT NULL, claim_expires_at, created_at, updated_at
		FROM owner_security WHERE owner_user_id = ?
	`, userID))
}

func (s *SQLite) ListOwnerSecurities(ctx context.Context) ([]OwnerSecurity, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT server_id, owner_user_id, auth_generation,
			claimed_at IS NOT NULL, claim_expires_at, created_at, updated_at
		FROM owner_security
		ORDER BY server_id
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []OwnerSecurity{}
	for rows.Next() {
		security, err := scanOwnerSecurity(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, security)
	}
	return items, rows.Err()
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanOwnerSecurity(row rowScanner) (OwnerSecurity, error) {
	var security OwnerSecurity
	var claimExpiresAt sql.NullString
	var createdAt, updatedAt string
	err := row.Scan(
		&security.ServerID,
		&security.OwnerUserID,
		&security.AuthGeneration,
		&security.Claimed,
		&claimExpiresAt,
		&createdAt,
		&updatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return OwnerSecurity{}, ErrNotFound
	}
	if err != nil {
		return OwnerSecurity{}, err
	}
	security.ClaimExpiresAt = parseOptionalDBTime(claimExpiresAt)
	security.CreatedAt = parseDBTime(createdAt)
	security.UpdatedAt = parseDBTime(updatedAt)
	return security, nil
}

func (s *SQLite) ClaimOwner(ctx context.Context, serverID, tokenHash string, device OwnerDevice) (OwnerSecurity, OwnerDevice, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return OwnerSecurity{}, OwnerDevice{}, err
	}
	defer tx.Rollback()

	var storedHash string
	var expiresAt sql.NullString
	var claimed bool
	err = tx.QueryRowContext(ctx, `
		SELECT claim_token_hash, claim_expires_at, claimed_at IS NOT NULL
		FROM owner_security WHERE server_id = ?
	`, serverID).Scan(&storedHash, &expiresAt, &claimed)
	if errors.Is(err, sql.ErrNoRows) {
		return OwnerSecurity{}, OwnerDevice{}, ErrNotFound
	}
	if err != nil {
		return OwnerSecurity{}, OwnerDevice{}, err
	}
	if claimed {
		return OwnerSecurity{}, OwnerDevice{}, ErrOwnerAlreadyClaimed
	}
	if storedHash == "" || storedHash != tokenHash || !expiresAt.Valid || !parseDBTime(expiresAt.String).After(time.Now().UTC()) {
		return OwnerSecurity{}, OwnerDevice{}, ErrInvalidOwnerToken
	}
	device.ServerID = serverID
	device.AuthorizationMethod = "initial_claim"
	device.SessionGeneration = 1
	if device.ID == "" {
		device.ID = ids.New("odev")
	}
	if err := insertOwnerDevice(ctx, tx, device); err != nil {
		return OwnerSecurity{}, OwnerDevice{}, err
	}
	_, err = tx.ExecContext(ctx, `
		UPDATE owner_security
		SET claim_token_hash = '', claim_expires_at = NULL,
			recovery_public_key = '', claimed_at = CURRENT_TIMESTAMP,
			updated_at = CURRENT_TIMESTAMP
		WHERE server_id = ?
	`, serverID)
	if err != nil {
		return OwnerSecurity{}, OwnerDevice{}, err
	}
	if err := tx.Commit(); err != nil {
		return OwnerSecurity{}, OwnerDevice{}, err
	}
	security, err := s.GetOwnerSecurity(ctx, serverID)
	if err != nil {
		return OwnerSecurity{}, OwnerDevice{}, err
	}
	saved, err := s.GetOwnerDevice(ctx, serverID, device.ID)
	return security, saved, err
}

func insertOwnerDevice(ctx context.Context, tx *sql.Tx, device OwnerDevice) error {
	_, err := tx.ExecContext(ctx, `
		INSERT INTO owner_devices (
			id, server_id, label, platform, client_version, public_key,
			public_key_fingerprint, authorization_method, session_generation
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, device.ID, device.ServerID, device.Label, device.Platform,
		device.ClientVersion, device.PublicKey, device.PublicKeyFingerprint,
		device.AuthorizationMethod, device.SessionGeneration)
	return err
}

func (s *SQLite) GetOwnerDevice(ctx context.Context, serverID, deviceID string) (OwnerDevice, error) {
	var device OwnerDevice
	var createdAt string
	var lastSeenAt, revokedAt sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT id, server_id, label, platform, client_version, public_key,
			public_key_fingerprint, authorization_method, session_generation,
			created_at, last_seen_at, revoked_at
		FROM owner_devices WHERE server_id = ? AND id = ?
	`, serverID, deviceID).Scan(
		&device.ID, &device.ServerID, &device.Label, &device.Platform,
		&device.ClientVersion, &device.PublicKey, &device.PublicKeyFingerprint,
		&device.AuthorizationMethod, &device.SessionGeneration, &createdAt,
		&lastSeenAt, &revokedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return OwnerDevice{}, ErrNotFound
	}
	if err != nil {
		return OwnerDevice{}, err
	}
	device.CreatedAt = parseDBTime(createdAt)
	device.LastSeenAt = parseOptionalDBTime(lastSeenAt)
	device.RevokedAt = parseOptionalDBTime(revokedAt)
	return device, nil
}

func (s *SQLite) ListOwnerDevices(ctx context.Context, serverID string) ([]OwnerDevice, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, server_id, label, platform, client_version, public_key,
			public_key_fingerprint, authorization_method, session_generation,
			created_at, last_seen_at, revoked_at
		FROM owner_devices
		WHERE server_id = ?
		ORDER BY revoked_at IS NOT NULL, created_at
	`, serverID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	devices := []OwnerDevice{}
	for rows.Next() {
		var device OwnerDevice
		var createdAt string
		var lastSeenAt, revokedAt sql.NullString
		if err := rows.Scan(
			&device.ID, &device.ServerID, &device.Label, &device.Platform,
			&device.ClientVersion, &device.PublicKey, &device.PublicKeyFingerprint,
			&device.AuthorizationMethod, &device.SessionGeneration, &createdAt,
			&lastSeenAt, &revokedAt,
		); err != nil {
			return nil, err
		}
		device.CreatedAt = parseDBTime(createdAt)
		device.LastSeenAt = parseOptionalDBTime(lastSeenAt)
		device.RevokedAt = parseOptionalDBTime(revokedAt)
		devices = append(devices, device)
	}
	return devices, rows.Err()
}

func (s *SQLite) ValidateOwnerSession(ctx context.Context, serverID, userID, deviceID string, authGeneration, sessionGeneration int64) (OwnerDevice, error) {
	var device OwnerDevice
	var createdAt string
	var lastSeenAt sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT d.id, d.server_id, d.label, d.platform, d.client_version,
			d.public_key, d.public_key_fingerprint, d.authorization_method,
			d.session_generation, d.created_at, d.last_seen_at
		FROM owner_security s
		JOIN owner_devices d ON d.server_id = s.server_id
		WHERE s.server_id = ? AND s.owner_user_id = ?
		  AND s.auth_generation = ? AND s.claimed_at IS NOT NULL
		  AND d.id = ? AND d.session_generation = ? AND d.revoked_at IS NULL
	`, serverID, userID, authGeneration, deviceID, sessionGeneration).Scan(
		&device.ID, &device.ServerID, &device.Label, &device.Platform,
		&device.ClientVersion, &device.PublicKey, &device.PublicKeyFingerprint,
		&device.AuthorizationMethod, &device.SessionGeneration, &createdAt,
		&lastSeenAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return OwnerDevice{}, ErrOwnerDeviceRevoked
	}
	if err != nil {
		return OwnerDevice{}, err
	}
	device.CreatedAt = parseDBTime(createdAt)
	device.LastSeenAt = parseOptionalDBTime(lastSeenAt)
	_, _ = s.db.ExecContext(ctx, `UPDATE owner_devices SET last_seen_at = CURRENT_TIMESTAMP WHERE id = ?`, deviceID)
	return device, nil
}

func (s *SQLite) CreateOwnerPairingToken(ctx context.Context, serverID, tokenHash, creatorDeviceID string, expiresAt time.Time) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO owner_pairing_tokens (
			id, server_id, token_hash, created_by_device_id, expires_at
		) VALUES (?, ?, ?, ?, ?)
	`, ids.New("opair"), serverID, tokenHash, creatorDeviceID, expiresAt.UTC())
	return err
}

func (s *SQLite) ConsumeOwnerPairingToken(ctx context.Context, serverID, tokenHash string, device OwnerDevice) (OwnerSecurity, OwnerDevice, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return OwnerSecurity{}, OwnerDevice{}, err
	}
	defer tx.Rollback()
	var tokenID string
	err = tx.QueryRowContext(ctx, `
		SELECT id FROM owner_pairing_tokens
		WHERE server_id = ? AND token_hash = ? AND consumed_at IS NULL
		  AND expires_at > CURRENT_TIMESTAMP
	`, serverID, tokenHash).Scan(&tokenID)
	if errors.Is(err, sql.ErrNoRows) {
		return OwnerSecurity{}, OwnerDevice{}, ErrInvalidOwnerToken
	}
	if err != nil {
		return OwnerSecurity{}, OwnerDevice{}, err
	}
	device.ServerID = serverID
	device.AuthorizationMethod = "pairing_code"
	device.SessionGeneration = 1
	if device.ID == "" {
		device.ID = ids.New("odev")
	}
	if err := insertOwnerDevice(ctx, tx, device); err != nil {
		return OwnerSecurity{}, OwnerDevice{}, err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE owner_pairing_tokens SET consumed_at = CURRENT_TIMESTAMP
		WHERE id = ? AND consumed_at IS NULL
	`, tokenID)
	if err != nil {
		return OwnerSecurity{}, OwnerDevice{}, err
	}
	if changed, _ := result.RowsAffected(); changed != 1 {
		return OwnerSecurity{}, OwnerDevice{}, ErrInvalidOwnerToken
	}
	if err := tx.Commit(); err != nil {
		return OwnerSecurity{}, OwnerDevice{}, err
	}
	security, err := s.GetOwnerSecurity(ctx, serverID)
	if err != nil {
		return OwnerSecurity{}, OwnerDevice{}, err
	}
	saved, err := s.GetOwnerDevice(ctx, serverID, device.ID)
	return security, saved, err
}

func (s *SQLite) KickOwnerDevice(ctx context.Context, serverID, deviceID string) (OwnerDevice, error) {
	result, err := s.db.ExecContext(ctx, `
		UPDATE owner_devices
		SET session_generation = session_generation + 1
		WHERE server_id = ? AND id = ? AND revoked_at IS NULL
	`, serverID, deviceID)
	if err != nil {
		return OwnerDevice{}, err
	}
	if changed, _ := result.RowsAffected(); changed != 1 {
		return OwnerDevice{}, ErrNotFound
	}
	return s.GetOwnerDevice(ctx, serverID, deviceID)
}

func (s *SQLite) RevokeOwnerDevice(ctx context.Context, serverID, deviceID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var count int
	if err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM owner_devices
		WHERE server_id = ? AND revoked_at IS NULL
	`, serverID).Scan(&count); err != nil {
		return err
	}
	if count <= 1 {
		return ErrLastOwnerDevice
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE owner_devices
		SET revoked_at = CURRENT_TIMESTAMP,
			session_generation = session_generation + 1
		WHERE server_id = ? AND id = ? AND revoked_at IS NULL
	`, serverID, deviceID)
	if err != nil {
		return err
	}
	if changed, _ := result.RowsAffected(); changed != 1 {
		return ErrNotFound
	}
	return tx.Commit()
}

func (s *SQLite) ResetOwnerCredentials(ctx context.Context, serverID, claimTokenHash string, claimExpiresAt time.Time) (OwnerSecurity, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return OwnerSecurity{}, err
	}
	defer tx.Rollback()
	var ownerUserID string
	err = tx.QueryRowContext(ctx, `
		SELECT user_id FROM server_members
		WHERE server_id = ? AND role = 'owner'
	`, serverID).Scan(&ownerUserID)
	if errors.Is(err, sql.ErrNoRows) {
		return OwnerSecurity{}, ErrNotFound
	}
	if err != nil {
		return OwnerSecurity{}, err
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO owner_security (
			server_id, owner_user_id, claim_token_hash, claim_expires_at
		) VALUES (?, ?, ?, ?)
		ON CONFLICT(server_id) DO UPDATE SET
			owner_user_id = excluded.owner_user_id,
			claim_token_hash = excluded.claim_token_hash,
			claim_expires_at = excluded.claim_expires_at,
			recovery_public_key = '',
			auth_generation = owner_security.auth_generation + 1,
			claimed_at = NULL,
			updated_at = CURRENT_TIMESTAMP
	`, serverID, ownerUserID, claimTokenHash, claimExpiresAt.UTC())
	if err != nil {
		return OwnerSecurity{}, err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE owner_devices
		SET revoked_at = COALESCE(revoked_at, CURRENT_TIMESTAMP),
			session_generation = session_generation + 1
		WHERE server_id = ?
	`, serverID); err != nil {
		return OwnerSecurity{}, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM owner_pairing_tokens WHERE server_id = ?`, serverID); err != nil {
		return OwnerSecurity{}, err
	}
	if err := tx.Commit(); err != nil {
		return OwnerSecurity{}, err
	}
	return s.GetOwnerSecurity(ctx, serverID)
}

func (s *SQLite) RefreshOwnerClaimToken(ctx context.Context, serverID, claimTokenHash string, claimExpiresAt time.Time) (OwnerSecurity, error) {
	security, err := s.EnsureOwnerSecurity(ctx, serverID, claimTokenHash, claimExpiresAt)
	if err != nil {
		return OwnerSecurity{}, err
	}
	if security.Claimed {
		return OwnerSecurity{}, ErrOwnerAlreadyClaimed
	}
	_, err = s.db.ExecContext(ctx, `
		UPDATE owner_security
		SET claim_token_hash = ?, claim_expires_at = ?, updated_at = CURRENT_TIMESTAMP
		WHERE server_id = ? AND claimed_at IS NULL
	`, claimTokenHash, claimExpiresAt.UTC(), serverID)
	if err != nil {
		return OwnerSecurity{}, err
	}
	return s.GetOwnerSecurity(ctx, serverID)
}
