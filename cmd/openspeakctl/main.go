package main

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os"
	"strings"
	"time"

	"openspeak/internal/auth"
	"openspeak/internal/config"
	"openspeak/internal/database"
	apphttp "openspeak/internal/httpapi"
	"openspeak/internal/store"
)

func main() {
	ownerCommand := len(os.Args) >= 3 && os.Args[1] == "owner" &&
		(os.Args[2] == "bootstrap" || os.Args[2] == "recover" || os.Args[2] == "claim-token")
	tlsDisableCommand := len(os.Args) >= 3 && os.Args[1] == "tls" && os.Args[2] == "disable"
	if !ownerCommand && !tlsDisableCommand {
		printUsage()
		os.Exit(2)
	}
	loadInstalledEnvironment()
	cfg, err := config.Load()
	if err != nil {
		fatal(err)
	}
	if tlsDisableCommand {
		running, err := backendListening(cfg.HTTP.Addr)
		if err != nil {
			fatal(err)
		}
		if running {
			fatal(fmt.Errorf("OpenSpeak backend is still running; stop it first (systemd: sudo systemctl stop openspeak)"))
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	db, err := database.OpenSQLite(ctx, cfg.DatabasePath)
	if err != nil {
		fatal(err)
	}
	defer db.Close()
	repo := store.NewSQLite(db)
	if tlsDisableCommand {
		serverID := serverIDArgument(ctx, repo)
		_, plainURL, err := apphttp.DisableTLSFromHost(ctx, cfg, repo, serverID)
		if err != nil {
			fatal(err)
		}
		if _, err := repo.CreateAuditLog(ctx, store.AuditLog{
			ServerID: serverID, ActorUserID: "host-root", Action: "server.encryption_downgraded",
			TargetID: serverID, Metadata: map[string]string{"source": "openspeakctl"},
		}); err != nil {
			fmt.Fprintln(os.Stderr, "openspeakctl: warning: failed to write audit log:", err)
		}
		fmt.Println("OpenSpeak transport encryption disabled.")
		fmt.Printf("Database path: %s\n", cfg.DatabasePath)
		fmt.Printf("Server ID: %s\n", serverID)
		fmt.Printf("Plain URL: %s\n", plainURL)
		fmt.Println("Start the OpenSpeak backend again (systemd: sudo systemctl start openspeak).")
		return
	}
	claimKey, err := auth.RandomToken(32)
	if err != nil {
		fatal(err)
	}
	expiresAt := time.Now().UTC().Add(24 * time.Hour)
	if os.Args[2] == "bootstrap" {
		bootstrapOwner(ctx, cfg, repo, claimKey, expiresAt)
		return
	}
	serverID := serverIDArgument(ctx, repo)
	switch os.Args[2] {
	case "recover":
		if _, err := repo.ResetOwnerCredentials(
			ctx, serverID, auth.SecretHash(claimKey), expiresAt,
		); err != nil {
			fatal(err)
		}
		fmt.Println("OpenSpeak owner credentials reset.")
	case "claim-token":
		if _, err := repo.RefreshOwnerClaimToken(
			ctx, serverID, auth.SecretHash(claimKey), expiresAt,
		); err != nil {
			fatal(err)
		}
		fmt.Println("OpenSpeak owner claim key refreshed.")
	}
	fmt.Printf("Database path: %s\n", cfg.DatabasePath)
	fmt.Printf("Server ID: %s\n", serverID)
	fmt.Printf("Owner claim key: %s\n", claimKey)
	fmt.Printf("Expires at: %s\n", expiresAt.Format(time.RFC3339))
	if os.Args[2] == "recover" {
		fmt.Println("All previous owner devices, sessions, and pairing codes are now invalid.")
	}
}

func printUsage() {
	fmt.Fprintln(os.Stderr, "usage:")
	fmt.Fprintln(os.Stderr, "  openspeakctl owner <bootstrap|recover|claim-token> [server_id]")
	fmt.Fprintln(os.Stderr, "  openspeakctl tls disable [server_id]")
}

func serverIDArgument(ctx context.Context, repo *store.SQLite) string {
	if len(os.Args) >= 4 {
		return os.Args[3]
	}
	servers, err := repo.ListServers(ctx)
	if err != nil {
		fatal(err)
	}
	if len(servers) != 1 {
		fatal(fmt.Errorf("server_id is required when the database contains %d servers", len(servers)))
	}
	return servers[0].ID
}

func backendListening(address string) (bool, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return false, fmt.Errorf("invalid OS_ADDR %q: %w", address, err)
	}
	if host == "" || host == "0.0.0.0" {
		host = "127.0.0.1"
	} else if host == "::" {
		host = "::1"
	}
	connection, err := net.DialTimeout("tcp", net.JoinHostPort(host, port), 500*time.Millisecond)
	if err != nil {
		return false, nil
	}
	_ = connection.Close()
	return true, nil
}

func bootstrapOwner(ctx context.Context, cfg config.Config, repo *store.SQLite, claimKey string, expiresAt time.Time) {
	servers, err := repo.ListServers(ctx)
	if err != nil {
		fatal(err)
	}
	if len(servers) != 0 {
		fatal(fmt.Errorf("owner bootstrap is only available when no OpenSpeak server exists"))
	}
	owner, err := repo.CreateUser(ctx, "Owner")
	if err != nil {
		fatal(err)
	}
	serverRecord, err := repo.CreateServer(ctx, store.OSServer{
		Name:                 "OpenSpeak Server",
		EncryptionMode:       cfg.DefaultEncryptionMode,
		FileRoot:             cfg.FileRoot,
		HistoryRetentionDays: cfg.DefaultHistoryRetentionDays,
	})
	if err != nil {
		fatal(err)
	}
	if _, err := repo.SetServerMember(
		ctx, serverRecord.ID, owner.ID, store.RoleOwner, store.AllPermissions(),
	); err != nil {
		fatal(err)
	}
	channel, err := repo.CreateChannel(ctx, store.Channel{
		ServerID: serverRecord.ID,
		Name:     "General",
	})
	if err != nil {
		fatal(err)
	}
	if _, err := repo.UpdateServer(
		ctx, serverRecord.ID, nil, nil, nil, nil, nil, nil,
		&channel.ID, nil, nil, nil, nil,
	); err != nil {
		fatal(err)
	}
	if _, err := repo.CreateOwnerSecurity(
		ctx, serverRecord.ID, owner.ID, auth.SecretHash(claimKey), expiresAt,
	); err != nil {
		fatal(err)
	}
	fmt.Println("OpenSpeak server and owner identity initialized.")
	fmt.Printf("Server ID: %s\n", serverRecord.ID)
	fmt.Printf("Owner claim key: %s\n", claimKey)
	fmt.Printf("Expires at: %s\n", expiresAt.Format(time.RFC3339))
	fmt.Println("Enter this key in the OpenSpeak client. It can be used once.")
}

func loadInstalledEnvironment() {
	if os.Getenv("OS_DATABASE_PATH") != "" {
		return
	}
	file, err := os.Open("/etc/openspeak/openspeak.env")
	if err != nil {
		return
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		if key == "" || os.Getenv(key) != "" {
			continue
		}
		value = strings.Trim(strings.TrimSpace(value), `"'`)
		_ = os.Setenv(key, value)
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "openspeakctl:", err)
	os.Exit(1)
}
