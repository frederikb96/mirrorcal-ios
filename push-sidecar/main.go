// Command push-sidecar is MirrorCal's push sidecar: a single long-running process holding
// both the registration HTTP endpoint and the internal ticker that fans a silent push out
// to every registered device on a schedule. See README.md for the full design and the
// contract the app side of registration must implement.
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
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	cfg, err := LoadConfig()
	if err != nil {
		log.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	store, err := NewStore(cfg.DataDir)
	if err != nil {
		log.Error("could not open token store", "error", err)
		os.Exit(1)
	}

	pusher, err := NewAPNSPusher(cfg.APNSAuthKeyPath, cfg.APNSKeyID, cfg.APNSTeamID, cfg.APNSTopic)
	if err != nil {
		log.Error("could not build APNs client", "error", err)
		os.Exit(1)
	}

	metrics := NewMetrics()
	server := NewServer(store, cfg.RegistrationSharedSecret, metrics, log)
	scheduler := NewScheduler(store, pusher, metrics, time.Duration(cfg.PushIntervalMinutes)*time.Minute, log)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go scheduler.Run(ctx)

	httpServer := &http.Server{Addr: cfg.ListenAddr, Handler: server.Handler()}
	go func() {
		log.Info("listening", "addr", cfg.ListenAddr, "push_interval_minutes", cfg.PushIntervalMinutes)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("http server failed", "error", err)
			stop()
		}
	}()

	<-ctx.Done()
	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		log.Error("error during shutdown", "error", err)
	}
}
