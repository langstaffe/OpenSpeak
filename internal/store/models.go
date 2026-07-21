package store

import "time"

type User struct {
	ID            string    `json:"id"`
	DisplayName   string    `json:"display_name"`
	AvatarVersion int64     `json:"avatar_version"`
	AvatarHash    string    `json:"avatar_hash,omitempty"`
	CreatedAt     time.Time `json:"created_at"`
}

type Device struct {
	ID                string     `json:"id"`
	UserID            string     `json:"user_id"`
	Label             string     `json:"label"`
	IdentityPublicKey string     `json:"identity_public_key"`
	EnvelopePublicKey string     `json:"envelope_public_key"`
	CreatedAt         time.Time  `json:"created_at"`
	LastSeenAt        *time.Time `json:"last_seen_at,omitempty"`
}

type ChannelDevice struct {
	Device
	HasEnvelope bool `json:"has_envelope"`
}

type OwnerSecurity struct {
	ServerID       string     `json:"server_id"`
	OwnerUserID    string     `json:"owner_user_id"`
	Claimed        bool       `json:"claimed"`
	AuthGeneration int64      `json:"auth_generation"`
	ClaimExpiresAt *time.Time `json:"claim_expires_at,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}

type OwnerDevice struct {
	ID                   string     `json:"id"`
	ServerID             string     `json:"server_id"`
	Label                string     `json:"label"`
	Platform             string     `json:"platform"`
	ClientVersion        string     `json:"client_version"`
	PublicKey            string     `json:"public_key"`
	PublicKeyFingerprint string     `json:"public_key_fingerprint"`
	AuthorizationMethod  string     `json:"authorization_method"`
	SessionGeneration    int64      `json:"session_generation"`
	CreatedAt            time.Time  `json:"created_at"`
	LastSeenAt           *time.Time `json:"last_seen_at,omitempty"`
	RevokedAt            *time.Time `json:"revoked_at,omitempty"`
	Online               bool       `json:"online"`
}

type OSServer struct {
	ID                        string                   `json:"id"`
	Name                      string                   `json:"name"`
	AvatarVersion             int64                    `json:"avatar_version"`
	AvatarHash                string                   `json:"avatar_hash,omitempty"`
	EncryptionMode            string                   `json:"encryption_mode"`
	FileRoot                  string                   `json:"file_root"`
	HistoryRetentionDays      int                      `json:"history_retention_days"`
	PasswordProtected         bool                     `json:"password_protected"`
	ScreenSharePolicy         ScreenSharePolicy        `json:"screen_share_policy"`
	DefaultChannelID          *string                  `json:"default_channel_id,omitempty"`
	AttachmentExternalEnabled bool                     `json:"attachment_external_enabled"`
	AttachmentFileNodeID      *string                  `json:"attachment_file_node_id,omitempty"`
	VoiceAudioBitrateKbps     int                      `json:"voice_audio_bitrate_kbps"`
	ScreenShareBitrateLimits  ScreenShareBitrateLimits `json:"screen_share_bitrate_limits_mbps"`
	TLSCertificateType        string                   `json:"tls_certificate_type"`
	TLSIdentifier             string                   `json:"tls_identifier"`
	TLSStatus                 string                   `json:"tls_status"`
	TLSError                  string                   `json:"tls_error,omitempty"`
	TLSExpiresAt              *time.Time               `json:"tls_expires_at,omitempty"`
	TLSRenewalAt              *time.Time               `json:"tls_renewal_at,omitempty"`
	CreatedAt                 time.Time                `json:"created_at"`
}

type ServerMember struct {
	ServerID    string    `json:"server_id"`
	UserID      string    `json:"user_id"`
	Role        string    `json:"role"`
	Permissions []string  `json:"permissions"`
	JoinedAt    time.Time `json:"joined_at"`
}

type ServerRolePermissions struct {
	ServerID  string    `json:"server_id"`
	Admin     []string  `json:"admin"`
	User      []string  `json:"user"`
	UpdatedBy string    `json:"updated_by,omitempty"`
	UpdatedAt time.Time `json:"updated_at"`
}

type AuditLog struct {
	ID          string            `json:"id"`
	ServerID    string            `json:"server_id"`
	ActorUserID string            `json:"actor_user_id"`
	Action      string            `json:"action"`
	TargetID    string            `json:"target_id,omitempty"`
	Metadata    map[string]string `json:"metadata,omitempty"`
	CreatedAt   time.Time         `json:"created_at"`
}

type ManagedServerMember struct {
	ServerID                string     `json:"server_id"`
	UserID                  string     `json:"user_id"`
	DisplayName             string     `json:"display_name"`
	Role                    string     `json:"role"`
	Permissions             []string   `json:"permissions"`
	JoinedAt                time.Time  `json:"joined_at"`
	FirstSeenAt             *time.Time `json:"first_seen_at,omitempty"`
	LastSeenAt              *time.Time `json:"last_seen_at,omitempty"`
	InstallationFingerprint string     `json:"installation_fingerprint,omitempty"`
	Legacy                  bool       `json:"legacy"`
	Online                  bool       `json:"online"`
	Banned                  bool       `json:"banned"`
	BanID                   string     `json:"ban_id,omitempty"`
	BanReason               string     `json:"ban_reason,omitempty"`
	BanExpiresAt            *time.Time `json:"ban_expires_at,omitempty"`
}

type ServerBan struct {
	ID               string     `json:"id"`
	ServerID         string     `json:"server_id"`
	UserID           string     `json:"user_id"`
	InstallationHash string     `json:"-"`
	Reason           string     `json:"reason"`
	CreatedByUserID  string     `json:"created_by_user_id"`
	CreatedAt        time.Time  `json:"created_at"`
	ExpiresAt        *time.Time `json:"expires_at,omitempty"`
	RevokedAt        *time.Time `json:"revoked_at,omitempty"`
	RevokedByUserID  *string    `json:"revoked_by_user_id,omitempty"`
}

type ScreenSharePolicy struct {
	P2P   ScreenShareModePolicy `json:"p2p"`
	Relay ScreenShareModePolicy `json:"relay"`
}

type ScreenShareModePolicy struct {
	Enabled bool                    `json:"enabled"`
	Allowed []ScreenShareCapability `json:"allowed"`
}

type ScreenShareCapability struct {
	Resolution string `json:"resolution"`
	FPS        int    `json:"fps"`
}

type ScreenShareBitrateLimits struct {
	P720   ScreenShareFrameBitrates `json:"720p"`
	P1080  ScreenShareFrameBitrates `json:"1080p"`
	Source ScreenShareFrameBitrates `json:"source"`
}

type ScreenShareFrameBitrates struct {
	FPS15 int `json:"15"`
	FPS30 int `json:"30"`
	FPS60 int `json:"60"`
}

func DefaultScreenShareBitrateLimits() ScreenShareBitrateLimits {
	return ScreenShareBitrateLimits{
		P720:   ScreenShareFrameBitrates{FPS15: 2, FPS30: 4, FPS60: 8},
		P1080:  ScreenShareFrameBitrates{FPS15: 4, FPS30: 8, FPS60: 16},
		Source: ScreenShareFrameBitrates{FPS15: 8, FPS30: 16, FPS60: 32},
	}
}

func (limits ScreenShareBitrateLimits) BitrateMbps(resolution string, fps int) int {
	var row ScreenShareFrameBitrates
	switch resolution {
	case "720p":
		row = limits.P720
	case "1080p":
		row = limits.P1080
	case "source":
		row = limits.Source
	default:
		return 0
	}
	switch fps {
	case 15:
		return row.FPS15
	case 30:
		return row.FPS30
	case 60:
		return row.FPS60
	default:
		return 0
	}
}

func (limits ScreenShareBitrateLimits) Valid() bool {
	for _, resolution := range []string{"720p", "1080p", "source"} {
		for _, fps := range []int{15, 30, 60} {
			value := limits.BitrateMbps(resolution, fps)
			if value < 1 || value > 200 {
				return false
			}
		}
	}
	return true
}

type MediaNode struct {
	ID                  string    `json:"id"`
	ServerID            string    `json:"server_id"`
	Name                string    `json:"name"`
	LiveKitURL          string    `json:"livekit_url"`
	APIKey              string    `json:"api_key"`
	APISecret           string    `json:"-"`
	APISecretSet        bool      `json:"api_secret_set"`
	IsLocal             bool      `json:"is_local"`
	Region              string    `json:"region,omitempty"`
	Weight              int       `json:"weight"`
	Enabled             bool      `json:"enabled"`
	Draining            bool      `json:"draining"`
	MaxRelayBitrateKbps int       `json:"max_relay_bitrate_kbps"`
	MaxRooms            int       `json:"max_rooms"`
	CreatedAt           time.Time `json:"created_at"`
	UpdatedAt           time.Time `json:"updated_at"`
}

type MediaNodePatch struct {
	Name                *string
	LiveKitURL          *string
	APIKey              *string
	APISecret           *string
	Region              *string
	Weight              *int
	Enabled             *bool
	Draining            *bool
	MaxRelayBitrateKbps *int
	MaxRooms            *int
}

type FileNode struct {
	ID        string    `json:"id"`
	ServerID  string    `json:"server_id"`
	Name      string    `json:"name"`
	BaseURL   string    `json:"base_url"`
	Secret    string    `json:"-"`
	SecretSet bool      `json:"secret_set"`
	Enabled   bool      `json:"enabled"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type FileNodePatch struct {
	Name    *string
	BaseURL *string
	Secret  *string
	Enabled *bool
}

type Channel struct {
	ID        string    `json:"id"`
	ServerID  string    `json:"server_id"`
	Name      string    `json:"name"`
	SortOrder int       `json:"sort_order"`
	CreatedAt time.Time `json:"created_at"`
}

type ChannelEpoch struct {
	ID          string    `json:"id"`
	ChannelID   string    `json:"channel_id"`
	EpochNumber int64     `json:"epoch_number"`
	Reason      string    `json:"reason"`
	CreatedAt   time.Time `json:"created_at"`
}

// ChannelMember is a persistent channel access grant. It is not evidence that
// the user is online or currently present in the channel; realtime presence is
// owned by realtime.Hub.
type ChannelMember struct {
	ChannelID string     `json:"channel_id"`
	UserID    string     `json:"user_id"`
	Role      string     `json:"role"`
	JoinedAt  time.Time  `json:"joined_at"`
	LeftAt    *time.Time `json:"left_at,omitempty"`
}

type KeyEnvelope struct {
	ID                      string    `json:"id"`
	Scope                   string    `json:"scope"`
	ServerID                *string   `json:"server_id,omitempty"`
	ChannelID               *string   `json:"channel_id,omitempty"`
	EpochID                 *string   `json:"epoch_id,omitempty"`
	RecipientUserID         string    `json:"recipient_user_id"`
	RecipientDeviceID       string    `json:"recipient_device_id"`
	SenderUserID            string    `json:"sender_user_id"`
	SenderDeviceID          string    `json:"sender_device_id"`
	SenderIdentityPublicKey string    `json:"sender_identity_public_key"`
	Algorithm               string    `json:"algorithm"`
	Ciphertext              string    `json:"ciphertext"`
	CreatedAt               time.Time `json:"created_at"`
}

type ChannelMessage struct {
	ID                  string            `json:"id"`
	ChannelID           string            `json:"channel_id"`
	SenderUserID        string            `json:"sender_user_id"`
	SenderDisplayName   string            `json:"sender_display_name"`
	SenderAvatarVersion int64             `json:"sender_avatar_version"`
	Kind                string            `json:"kind"`
	EncryptionMode      string            `json:"encryption_mode"`
	EpochID             *string           `json:"epoch_id,omitempty"`
	Body                string            `json:"body"`
	Nonce               string            `json:"nonce,omitempty"`
	Metadata            map[string]string `json:"metadata,omitempty"`
	CreatedAt           time.Time         `json:"created_at"`
}

type StoredFile struct {
	ID             string            `json:"id"`
	ServerID       string            `json:"server_id"`
	ChannelID      *string           `json:"channel_id,omitempty"`
	UploaderUserID string            `json:"uploader_user_id"`
	Kind           string            `json:"kind"`
	OriginalName   string            `json:"original_name"`
	ContentType    string            `json:"content_type"`
	SizeBytes      int64             `json:"size_bytes"`
	SHA256Hex      string            `json:"sha256_hex"`
	RelativePath   string            `json:"relative_path"`
	FileNodeID     *string           `json:"file_node_id,omitempty"`
	ObjectKey      string            `json:"object_key,omitempty"`
	EncryptionMode string            `json:"encryption_mode"`
	Metadata       map[string]string `json:"metadata,omitempty"`
	CreatedAt      time.Time         `json:"created_at"`
}
