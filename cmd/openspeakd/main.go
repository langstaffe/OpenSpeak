package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"openspeak/internal/config"
	"openspeak/internal/database"
	apphttp "openspeak/internal/httpapi"
	"openspeak/internal/logging"
	"openspeak/internal/realtime"
	"openspeak/internal/store"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		slog.Error("failed to load config", "error", err)
		os.Exit(1)
	}

	closeLogs, err := logging.Configure(cfg.Log)
	if err != nil {
		slog.Error("failed to configure logging", "error", err)
		os.Exit(1)
	}
	defer closeLogs()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	db, err := database.OpenSQLite(ctx, cfg.DatabasePath)
	if err != nil {
		slog.Error("failed to open sqlite database", "error", err)
		os.Exit(1)
	}
	defer db.Close()

	repo := store.NewSQLite(db)
	hub := realtime.NewHub()
	go hub.Run(ctx)

	app := apphttp.NewServer(cfg, repo, hub)
	go runRetentionCleaner(ctx, repo, app)
	go app.RunDirectFileCleaner(ctx)
	go app.RunOwnerCredentialMonitor(ctx)
	go app.RunTLSMonitor(ctx)
	server := &http.Server{
		Addr:              cfg.HTTP.Addr,
		Handler:           app,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	go func() {
		slog.Info("openspeak backend listening", "addr", cfg.HTTP.Addr)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("http server stopped unexpectedly", "error", err)
			stop()
		}
	}()

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		slog.Error("http shutdown failed", "error", err)
	}
}

type retentionCleaner interface {
	DeleteExpiredRetainedMessages(ctx context.Context) error
	ListExpiredRetainedFiles(ctx context.Context) ([]store.StoredFile, error)
}

type retainedFileCleaner interface {
	CleanupRetainedFile(ctx context.Context, file store.StoredFile) error
}

func runRetentionCleaner(ctx context.Context, cleaner retentionCleaner, files retainedFileCleaner) {
	ticker := time.NewTicker(6 * time.Hour)
	defer ticker.Stop()
	for {
		if err := cleaner.DeleteExpiredRetainedMessages(ctx); err != nil && ctx.Err() == nil {
			slog.Error("history retention cleanup failed", "error", err)
		}
		expired, err := cleaner.ListExpiredRetainedFiles(ctx)
		if err != nil && ctx.Err() == nil {
			slog.Error("retained attachment scan failed", "error", err)
		}
		for _, file := range expired {
			if err := files.CleanupRetainedFile(ctx, file); err != nil && ctx.Err() == nil {
				slog.Warn("retained attachment cleanup will be retried", "file_id", file.ID, "error", err)
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
