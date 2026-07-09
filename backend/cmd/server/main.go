package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Supanat-Smost/tennis/backend/internal/config"
	"github.com/Supanat-Smost/tennis/backend/internal/handler"
	"github.com/Supanat-Smost/tennis/backend/internal/service"
	"github.com/Supanat-Smost/tennis/backend/internal/store"
)

func main() {
	// --- slog JSON handler (configured first so even config/pool failures log as JSON) ---
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	// --- config (fail loud; never log the signing key) ---
	cfg, err := config.Load()
	if err != nil {
		slog.Error("configuration error", "err", err)
		os.Exit(1)
	}

	// --- DB pool ---
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		slog.Error("failed to create db pool", "err", err)
		os.Exit(1)
	}
	defer pool.Close()

	// --- dependencies (handler → service → store) ---
	st := store.New(pool)
	tokens := service.NewTokenService(cfg.JWTSigningKey)
	authSvc := service.NewAuthService(st, tokens)
	authH := handler.NewAuthHandler(authSvc)

	router := handler.BuildRouter(authH, tokens, st)

	// --- listen ---
	addr := ":" + cfg.Port
	slog.Info("server starting", "addr", addr)

	if err := http.ListenAndServe(addr, router); err != nil {
		slog.Error("server stopped", "err", err)
		os.Exit(1)
	}
}
