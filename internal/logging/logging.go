package logging

import (
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"openspeak/internal/config"
)

func Configure(cfg config.LogConfig) (func(), error) {
	var writer io.Writer = os.Stdout
	var file *os.File
	if cfg.File != "" {
		if err := os.MkdirAll(filepath.Dir(cfg.File), 0o750); err != nil {
			return nil, err
		}
		f, err := os.OpenFile(cfg.File, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
		if err != nil {
			return nil, err
		}
		file = f
		writer = io.MultiWriter(os.Stdout, f)
	}

	level := slog.LevelInfo
	switch strings.ToLower(cfg.Level) {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	}

	handler := slog.NewJSONHandler(writer, &slog.HandlerOptions{
		Level: level,
		ReplaceAttr: func(groups []string, attr slog.Attr) slog.Attr {
			if attr.Key == slog.TimeKey {
				attr.Value = slog.StringValue(attr.Value.Time().UTC().Format(time.RFC3339Nano))
			}
			return attr
		},
	})
	slog.SetDefault(slog.New(handler))

	return func() {
		if file != nil {
			_ = file.Close()
		}
	}, nil
}
