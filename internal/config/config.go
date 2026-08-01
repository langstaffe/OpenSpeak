package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	HTTP                        HTTPConfig
	Log                         LogConfig
	DatabasePath                string
	FileRoot                    string
	DirectFileRoot              string
	WebRoot                     string
	JWTSecret                   string
	JWTTTL                      time.Duration
	DefaultHistoryRetentionDays int
	DefaultEncryptionMode       string
	LiveKit                     LiveKitConfig
	TLS                         TLSConfig
}

type HTTPConfig struct {
	Addr string
}

type LogConfig struct {
	Level string
	File  string
}

type LiveKitConfig struct {
	URL       string
	APIKey    string
	APISecret string
	TokenTTL  time.Duration
}

type TLSConfig struct {
	CaddyAdminURL    string
	CaddyConfigPath  string
	VerifyAddr       string
	BackendUpstream  string
	LiveKitUpstream  string
	PlainPublicPort  int
	SecurePublicPort int
	ApplyTimeout     time.Duration
}

func Load() (Config, error) {
	databasePath := env("OS_DATABASE_PATH", "/opt/openspeak/openspeak.db")
	securePublicPort := envInt("OS_TLS_PUBLIC_PORT", 27412)
	caddyDir, err := filepath.Abs(filepath.Join(filepath.Dir(databasePath), "caddy"))
	if err != nil {
		return Config{}, fmt.Errorf("resolve Caddy directory: %w", err)
	}
	cfg := Config{
		HTTP: HTTPConfig{
			Addr: env("OS_ADDR", ":27410"),
		},
		Log: LogConfig{
			Level: env("OS_LOG_LEVEL", "info"),
			File:  os.Getenv("OS_LOG_FILE"),
		},
		DatabasePath:                databasePath,
		FileRoot:                    env("OS_FILE_ROOT", "/opt/openspeak/files"),
		DirectFileRoot:              env("OS_DIRECT_FILE_ROOT", filepath.Join(filepath.Dir(databasePath), "tmp", "direct_files")),
		WebRoot:                     env("OS_WEB_ROOT", "/opt/openspeak/web"),
		JWTSecret:                   os.Getenv("OS_JWT_SECRET"),
		JWTTTL:                      time.Duration(envInt("OS_JWT_TTL_SECONDS", 86400)) * time.Second,
		DefaultHistoryRetentionDays: envInt("OS_DEFAULT_HISTORY_RETENTION_DAYS", 30),
		DefaultEncryptionMode:       env("OS_DEFAULT_ENCRYPTION_MODE", "none"),
		LiveKit: LiveKitConfig{
			URL:       os.Getenv("OS_LIVEKIT_URL"),
			APIKey:    os.Getenv("OS_LIVEKIT_API_KEY"),
			APISecret: os.Getenv("OS_LIVEKIT_API_SECRET"),
			TokenTTL:  time.Duration(envInt("OS_LIVEKIT_TOKEN_TTL_SECONDS", 3600)) * time.Second,
		},
		TLS: TLSConfig{
			CaddyAdminURL:    env("OS_CADDY_ADMIN_URL", "unix://"+filepath.Join(caddyDir, "admin.sock")),
			CaddyConfigPath:  env("OS_CADDY_CONFIG_PATH", filepath.Join(caddyDir, "Caddyfile")),
			VerifyAddr:       env("OS_TLS_VERIFY_ADDR", fmt.Sprintf("127.0.0.1:%d", securePublicPort)),
			BackendUpstream:  env("OS_TLS_BACKEND_UPSTREAM", "127.0.0.1:27410"),
			LiveKitUpstream:  env("OS_TLS_LIVEKIT_UPSTREAM", "127.0.0.1:27420"),
			PlainPublicPort:  envInt("OS_PLAIN_PUBLIC_PORT", 27410),
			SecurePublicPort: securePublicPort,
			ApplyTimeout:     time.Duration(envInt("OS_TLS_APPLY_TIMEOUT_SECONDS", 120)) * time.Second,
		},
	}

	if strings.TrimSpace(cfg.DatabasePath) == "" {
		return Config{}, errors.New("OS_DATABASE_PATH is required")
	}
	if strings.TrimSpace(cfg.DirectFileRoot) == "" {
		return Config{}, errors.New("OS_DIRECT_FILE_ROOT must not be empty")
	}
	if strings.TrimSpace(cfg.JWTSecret) == "" {
		cfg.JWTSecret = "dev-only-change-me"
	}
	if cfg.DefaultHistoryRetentionDays < -1 {
		return Config{}, errors.New("OS_DEFAULT_HISTORY_RETENTION_DAYS must be -1 or greater")
	}
	if cfg.TLS.PlainPublicPort < 1 || cfg.TLS.PlainPublicPort > 65535 {
		return Config{}, errors.New("OS_PLAIN_PUBLIC_PORT must be between 1 and 65535")
	}
	if cfg.TLS.SecurePublicPort < 1 || cfg.TLS.SecurePublicPort > 65535 {
		return Config{}, errors.New("OS_TLS_PUBLIC_PORT must be between 1 and 65535")
	}
	if cfg.TLS.SecurePublicPort == cfg.TLS.PlainPublicPort {
		return Config{}, errors.New("OS_TLS_PUBLIC_PORT must differ from OS_PLAIN_PUBLIC_PORT")
	}
	mode, ok := NormalizeEncryptionMode(cfg.DefaultEncryptionMode)
	if !ok {
		return Config{}, errors.New("OS_DEFAULT_ENCRYPTION_MODE must be none, transport, or e2ee")
	}
	cfg.DefaultEncryptionMode = mode
	return cfg, nil
}

func NormalizeEncryptionMode(value string) (string, bool) {
	mode := strings.ToLower(strings.TrimSpace(value))
	switch mode {
	case "none", "transport", "e2ee":
		return mode, true
	default:
		return "", false
	}
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func envInt(key string, fallback int) int {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	n, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return n
}
