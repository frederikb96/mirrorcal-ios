package main

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/payload"
	"github.com/sideshow/apns2/token"
)

// sendTimeout bounds one whole tick's fan-out, mirroring pai-cloud's own
// asyncio.wait_for(..., timeout=APNS_SEND_TIMEOUT_S) around its fan-out — a hung HTTP/2
// stream to APNs must not wedge the scheduler's next tick forever.
const sendTimeout = 30 * time.Second

// Outcome is what happened to one device's push, coarsened to the three things a caller
// ever needs to act on differently.
type Outcome int

const (
	// OutcomeSuccess: APNs accepted the push. Not proof of delivery — see the design
	// note in README.md — only proof it reached Apple.
	OutcomeSuccess Outcome = iota
	// OutcomeGone: APNs will never accept another push to this token. The store drops
	// it; this is the only deletion path this service has, deliberately — see store.go.
	OutcomeGone
	// OutcomeFailure: neither of the above — a transient error, a misconfiguration, or
	// a network failure. Left in the store; retried on the next tick for free.
	OutcomeFailure
)

// PushResult is one token's outcome from one fan-out call.
type PushResult struct {
	Token   string
	Outcome Outcome
	// Reason is APNs' own reason string ("BadDeviceToken", "Unregistered", ...) or a
	// local error's message when the request never reached APNs at all. Logged, never
	// returned to any caller outside this process.
	Reason string
}

// Pusher sends one silent (content-available) push to every token given, fanned out
// concurrently, and reports what happened to each. An interface so the scheduler and its
// tests never need a real APNs connection — see fakePusher in scheduler_test.go.
type Pusher interface {
	SendSilent(ctx context.Context, tokens []string) []PushResult
}

// APNSPusher is the real Pusher, a thin wrapper around sideshow/apns2's token-based
// client. One client for the process lifetime — APNs expects a long-lived HTTP/2
// connection reused across pushes, not one connection per send.
type APNSPusher struct {
	client *apns2.Client
	topic  string
}

// NewAPNSPusher loads the .p8 key from keyPath and builds a production APNs client.
// TestFlight and App Store builds both only ever talk to APNs production — see
// config.go's doc comment on APNSTopic — so there is no sandbox client to choose between.
func NewAPNSPusher(keyPath, keyID, teamID, topic string) (*APNSPusher, error) {
	authKey, err := token.AuthKeyFromFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("loading APNs auth key from %q: %w", keyPath, err)
	}
	tok := &token.Token{AuthKey: authKey, KeyID: keyID, TeamID: teamID}
	client := apns2.NewTokenClient(tok).Production()
	return &APNSPusher{client: client, topic: topic}, nil
}

func (p *APNSPusher) SendSilent(ctx context.Context, tokens []string) []PushResult {
	ctx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()

	results := make([]PushResult, len(tokens))
	var wg sync.WaitGroup
	for i, deviceToken := range tokens {
		wg.Add(1)
		go func(i int, deviceToken string) {
			defer wg.Done()
			results[i] = p.sendOne(ctx, deviceToken)
		}(i, deviceToken)
	}
	wg.Wait()
	return results
}

func (p *APNSPusher) sendOne(ctx context.Context, deviceToken string) PushResult {
	n := &apns2.Notification{
		DeviceToken: deviceToken,
		Topic:       p.topic,
		// content-available and nothing else — Apple's own contract for a background
		// push forbids anything that would "trigger user interactions" riding along,
		// badge included. This wakes the app; the app reads its own state once it runs.
		Payload: payload.NewPayload().ContentAvailable(),
		// PushTypeBackground requires Topic == the app's bundle id (true here — the
		// bundle id IS the topic) and, per Apple, priority must be low (5); using 10
		// with this push type is a rejected combination, not merely a suggestion.
		PushType: apns2.PushTypeBackground,
		Priority: apns2.PriorityLow,
		// Apple already discards a held background notification in favour of a newer
		// one for the same app; naming a fixed collapse id makes that explicit rather
		// than relying on the low-priority queue's own implicit coalescing.
		CollapseID: "mirrorcal-sync",
	}

	res, err := p.client.PushWithContext(ctx, n)
	if err != nil {
		return PushResult{Token: deviceToken, Outcome: OutcomeFailure, Reason: err.Error()}
	}
	return PushResult{Token: deviceToken, Outcome: classify(res.StatusCode, res.Reason), Reason: res.Reason}
}

// classify turns one APNs response into an Outcome — pure and separate from sendOne so it
// is tested without a network call. Mirrors pai-cloud's own _GONE_STATUS /
// _PERMANENTLY_BAD_REASONS: a 410, or one of the three reasons Apple documents as "this
// token will never work again", means delete; anything else that was not a plain 200 is a
// failure left for the next tick to retry.
func classify(statusCode int, reason string) Outcome {
	if statusCode == 200 {
		return OutcomeSuccess
	}
	if statusCode == 410 {
		return OutcomeGone
	}
	switch reason {
	case "BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic":
		return OutcomeGone
	default:
		return OutcomeFailure
	}
}
