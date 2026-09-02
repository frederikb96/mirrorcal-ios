package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Config is the whole configuration surface of this service. It is deliberately flat env
// vars rather than a YAML-plus-overrides loader: the surface is small enough (a handful of
// values, one Secret and one ConfigMap in Kubernetes terms) that a merge chain would be
// machinery this service does not earn. Every value not given a default below must be set,
// or the process refuses to start — a service silently running with a guessed key id sends
// pushes APNs rejects for a reason nobody sees until a phone stops syncing.
type Config struct {
	// APNs identity. None of these are secret — see the auth key below for the one value
	// that is.
	APNSKeyID  string
	APNSTeamID string
	// APNSTopic is the bundle id every registered device belongs to. APNs rejects a push
	// whose topic does not match the token's own app, so a wrong value here fails loud
	// (DeviceTokenNotForTopic) rather than silently reaching nothing.
	APNSTopic string
	// APNSAuthKeyPath points at the mounted .p8 private key file (PEM, EC P-256). This is
	// the one value here that must never be logged or echoed back by any handler.
	APNSAuthKeyPath string

	// RegistrationSharedSecret gates POST /api/register. The one secret an installer sets
	// twice — once in the chart's values, once in the app's own settings screen — since
	// there is no account system on either side to hand it out through.
	RegistrationSharedSecret string

	// PushInterval is how often the scheduler ticks and fans a silent push out to every
	// registered device. Twenty minutes sits inside Apple's own throttle (roughly 2-3
	// background pushes per hour) with headroom, carried over from pai-cloud's own
	// SILENT_PUSH_MIN_INTERVAL_S rather than invented.
	PushIntervalMinutes int

	// DataDir holds tokens.json — the whole persisted state, on a small PVC. Losing it
	// costs one push cycle, not data: the app re-registers on every foreground launch.
	DataDir string

	// ListenAddr is what the HTTP server binds — the registration endpoint, /healthz and
	// /metrics all share it, since 2-3 requests an hour plus one registration call per
	// app launch is nowhere near enough traffic to justify separate ports.
	ListenAddr string
}

// requireEnv reads an env var and fails fast if it is unset or empty — the config-loading
// convention this project follows everywhere else: no default value ever masks a missing
// required one, so a broken install fails at startup with a name, not months later as a
// push nobody can explain.
func requireEnv(name string) (string, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return "", fmt.Errorf("%s is required and must not be empty", name)
	}
	return v, nil
}

func envOrDefault(name, def string) string {
	if v := strings.TrimSpace(os.Getenv(name)); v != "" {
		return v
	}
	return def
}

// LoadConfig reads and validates the whole configuration surface in one place, so main
// either has a Config it can trust completely or an error naming exactly what is missing.
func LoadConfig() (Config, error) {
	var cfg Config
	var err error

	if cfg.APNSKeyID, err = requireEnv("APNS_KEY_ID"); err != nil {
		return Config{}, err
	}
	if cfg.APNSTeamID, err = requireEnv("APNS_TEAM_ID"); err != nil {
		return Config{}, err
	}
	if cfg.APNSTopic, err = requireEnv("APNS_TOPIC"); err != nil {
		return Config{}, err
	}
	if cfg.APNSAuthKeyPath, err = requireEnv("APNS_AUTH_KEY_PATH"); err != nil {
		return Config{}, err
	}
	if _, statErr := os.Stat(cfg.APNSAuthKeyPath); statErr != nil {
		return Config{}, fmt.Errorf("APNS_AUTH_KEY_PATH %q is not readable: %w", cfg.APNSAuthKeyPath, statErr)
	}
	if cfg.RegistrationSharedSecret, err = requireEnv("REGISTRATION_SHARED_SECRET"); err != nil {
		return Config{}, err
	}

	intervalStr := envOrDefault("PUSH_INTERVAL_MINUTES", "20")
	cfg.PushIntervalMinutes, err = strconv.Atoi(intervalStr)
	if err != nil || cfg.PushIntervalMinutes <= 0 {
		return Config{}, fmt.Errorf("PUSH_INTERVAL_MINUTES must be a positive integer, got %q", intervalStr)
	}

	cfg.DataDir = envOrDefault("DATA_DIR", "/data")
	cfg.ListenAddr = envOrDefault("LISTEN_ADDR", ":8080")

	return cfg, nil
}
