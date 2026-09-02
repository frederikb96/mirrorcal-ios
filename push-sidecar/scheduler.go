package main

import (
	"context"
	"log/slog"
	"time"
)

// Scheduler is the internal ticker: the other half of the one process this service runs
// as, alongside the registration HTTP endpoint. There is no CronJob here on purpose — a
// CronJob's pods are ephemeral and cannot hold the registration listener between runs, so
// a CronJob design would still need a second always-on Deployment for that; one Deployment
// with an internal ticker is strictly simpler for the same result.
type Scheduler struct {
	store    *Store
	pusher   Pusher
	metrics  *Metrics
	interval time.Duration
	log      *slog.Logger
	// now is swappable in tests so a tick's timestamp is deterministic.
	now func() time.Time
}

func NewScheduler(store *Store, pusher Pusher, metrics *Metrics, interval time.Duration, log *slog.Logger) *Scheduler {
	return &Scheduler{store: store, pusher: pusher, metrics: metrics, interval: interval, log: log, now: time.Now}
}

// Run ticks every interval until ctx is cancelled, sending a silent push to every
// registered device on each tick. Blocking — callers run it in its own goroutine.
func (s *Scheduler) Run(ctx context.Context) {
	ticker := time.NewTicker(s.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.tick(ctx)
		}
	}
}

// tick is Run's body pulled out so a test can call it directly, once, without waiting on
// a real ticker.
func (s *Scheduler) tick(ctx context.Context) {
	devices, err := s.store.List()
	if err != nil {
		s.log.Error("tick: could not read token store", "error", err)
		return
	}
	s.metrics.RegisteredDevices.Set(float64(len(devices)))
	if len(devices) == 0 {
		s.log.Info("tick: no registered devices, nothing to send")
		return
	}

	tokens := make([]string, len(devices))
	for i, d := range devices {
		tokens[i] = d.Token
	}
	results := s.pusher.SendSilent(ctx, tokens)

	var succeeded, failed int
	var gone []string
	for _, r := range results {
		switch r.Outcome {
		case OutcomeSuccess:
			succeeded++
			s.metrics.PushAttemptsTotal.WithLabelValues("success").Inc()
		case OutcomeGone:
			gone = append(gone, r.Token)
			s.metrics.PushAttemptsTotal.WithLabelValues("gone").Inc()
		case OutcomeFailure:
			failed++
			s.metrics.PushAttemptsTotal.WithLabelValues("failure").Inc()
			s.log.Warn("tick: push failed for a device", "reason", r.Reason)
		}
	}

	if len(gone) > 0 {
		if err := s.store.DeleteMany(gone); err != nil {
			s.log.Error("tick: could not drop tokens APNs reported gone", "error", err)
		}
		s.metrics.RegisteredDevices.Set(float64(len(devices) - len(gone)))
	}

	if succeeded > 0 {
		s.metrics.PushLastSuccessSeconds.Set(float64(s.now().Unix()))
	}

	// A wholesale misconfiguration — wrong key, wrong team id, wrong topic — fails
	// every device the same way, which is exactly the signal worth its own log level:
	// distinct from "one stale phone", which the gone-token cleanup above already
	// handles on its own without anyone needing to look.
	if failed > 0 && failed == len(devices) && len(gone) == 0 {
		s.log.Error("tick: every registered device failed — check APNs key id, team id and topic",
			"devices", len(devices))
	}

	s.log.Info("tick complete",
		"devices", len(devices), "succeeded", succeeded, "failed", failed, "gone", len(gone))
}
