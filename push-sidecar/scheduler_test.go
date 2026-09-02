package main

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

// fakePusher is the whole reason apns.go defines Pusher as an interface: the scheduler's
// tick logic — fan out, drop gone tokens, count successes/failures — is exercised with no
// network at all, deterministically, by handing back a fixed outcome per token.
type fakePusher struct {
	outcomes map[string]Outcome
	calls    [][]string
}

func (f *fakePusher) SendSilent(_ context.Context, tokens []string) []PushResult {
	f.calls = append(f.calls, tokens)
	results := make([]PushResult, len(tokens))
	for i, tok := range tokens {
		outcome, ok := f.outcomes[tok]
		if !ok {
			outcome = OutcomeSuccess
		}
		results[i] = PushResult{Token: tok, Outcome: outcome}
	}
	return results
}

func silentLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func TestTickDropsGoneTokensFromStore(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	now := time.Now()
	for _, tok := range []string{"aaaa", "bbbb"} {
		if _, err := store.Upsert(tok, now); err != nil {
			t.Fatalf("Upsert(%s): %v", tok, err)
		}
	}

	pusher := &fakePusher{outcomes: map[string]Outcome{"bbbb": OutcomeGone}}
	sched := NewScheduler(store, pusher, NewMetrics(), time.Minute, silentLogger())
	sched.tick(context.Background())

	devices, err := store.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(devices) != 1 || devices[0].Token != "aaaa" {
		t.Fatalf("expected only aaaa to remain, got %+v", devices)
	}
}

func TestTickWithNoDevicesSendsNothing(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	pusher := &fakePusher{}
	sched := NewScheduler(store, pusher, NewMetrics(), time.Minute, silentLogger())
	sched.tick(context.Background())

	if len(pusher.calls) != 0 {
		t.Fatalf("expected no SendSilent call with an empty store, got %d calls", len(pusher.calls))
	}
}

func TestTickSetsLastSuccessOnlyWhenSomethingSucceeded(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	if _, err := store.Upsert("aaaa", time.Now()); err != nil {
		t.Fatalf("Upsert: %v", err)
	}

	metrics := NewMetrics()
	pusher := &fakePusher{outcomes: map[string]Outcome{"aaaa": OutcomeFailure}}
	sched := NewScheduler(store, pusher, metrics, time.Minute, silentLogger())
	sched.now = func() time.Time { return time.Unix(1000, 0) }
	sched.tick(context.Background())

	if got := testutil.ToFloat64(metrics.PushLastSuccessSeconds); got != 0 {
		t.Fatalf("expected last-success gauge untouched (0) after an all-failure tick, got %v", got)
	}

	// Now let it succeed and confirm the gauge follows the injected clock.
	pusher.outcomes["aaaa"] = OutcomeSuccess
	sched.tick(context.Background())
	if got := testutil.ToFloat64(metrics.PushLastSuccessSeconds); got != 1000 {
		t.Fatalf("expected last-success gauge = 1000, got %v", got)
	}
}

func TestTickFansOutToEveryRegisteredToken(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	now := time.Now()
	for _, tok := range []string{"aaaa", "bbbb", "cccc"} {
		if _, err := store.Upsert(tok, now); err != nil {
			t.Fatalf("Upsert(%s): %v", tok, err)
		}
	}
	pusher := &fakePusher{}
	sched := NewScheduler(store, pusher, NewMetrics(), time.Minute, silentLogger())
	sched.tick(context.Background())

	if len(pusher.calls) != 1 || len(pusher.calls[0]) != 3 {
		t.Fatalf("expected one fan-out call to all 3 tokens, got %+v", pusher.calls)
	}
}
