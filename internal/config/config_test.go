package config

import (
	"net/url"
	"path/filepath"
	"testing"
)

func TestLoadDirectFileSettings(t *testing.T) {
	databasePath := filepath.Join(t.TempDir(), "openspeak.db")
	t.Setenv("OS_DATABASE_PATH", databasePath)
	t.Setenv("OS_DIRECT_FILE_ROOT", "")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	wantRoot := filepath.Join(filepath.Dir(databasePath), "tmp", "direct_files")
	if cfg.DirectFileRoot != wantRoot {
		t.Fatalf("direct file root = %q, want %q", cfg.DirectFileRoot, wantRoot)
	}
	wantCaddyConfig := filepath.Join(filepath.Dir(databasePath), "caddy", "Caddyfile")
	if cfg.TLS.CaddyConfigPath != wantCaddyConfig {
		t.Fatalf("Caddy config path = %q, want %q", cfg.TLS.CaddyConfigPath, wantCaddyConfig)
	}
	wantCaddyAdmin := "unix://" + filepath.Join(filepath.Dir(databasePath), "caddy", "admin.sock")
	if cfg.TLS.CaddyAdminURL != wantCaddyAdmin {
		t.Fatalf("Caddy admin URL = %q, want %q", cfg.TLS.CaddyAdminURL, wantCaddyAdmin)
	}
}

func TestLoadUsesAbsoluteCaddyPathsForRelativeDatabase(t *testing.T) {
	t.Setenv("OS_DATABASE_PATH", "openspeak.db")
	t.Setenv("OS_CADDY_ADMIN_URL", "")
	t.Setenv("OS_CADDY_CONFIG_PATH", "")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if !filepath.IsAbs(cfg.TLS.CaddyConfigPath) {
		t.Fatalf("Caddy config path is not absolute: %q", cfg.TLS.CaddyConfigPath)
	}
	adminURL, err := url.Parse(cfg.TLS.CaddyAdminURL)
	if err != nil {
		t.Fatal(err)
	}
	if adminURL.Scheme != "unix" || adminURL.Host != "" || !filepath.IsAbs(adminURL.Path) {
		t.Fatalf("Caddy admin URL is not an absolute Unix socket URL: %q", cfg.TLS.CaddyAdminURL)
	}
}

func TestLoadPublicPorts(t *testing.T) {
	t.Setenv("OS_PLAIN_PUBLIC_PORT", "28080")
	t.Setenv("OS_TLS_PUBLIC_PORT", "28443")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.TLS.PlainPublicPort != 28080 {
		t.Fatalf("plain public port = %d", cfg.TLS.PlainPublicPort)
	}
	if cfg.TLS.SecurePublicPort != 28443 || cfg.TLS.VerifyAddr != "127.0.0.1:28443" {
		t.Fatalf("secure public port = %d, verify addr = %q", cfg.TLS.SecurePublicPort, cfg.TLS.VerifyAddr)
	}

	t.Setenv("OS_PLAIN_PUBLIC_PORT", "70000")
	if _, err := Load(); err == nil {
		t.Fatal("invalid plain public port accepted")
	}
	t.Setenv("OS_PLAIN_PUBLIC_PORT", "28443")
	if _, err := Load(); err == nil {
		t.Fatal("matching public ports accepted")
	}
}
