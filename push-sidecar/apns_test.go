package main

import "testing"

// These test only classify — the pure function apns.go isolates specifically so the
// gone-vs-failure decision is provable without a real APNs connection, which nothing in
// this environment can make (see README.md's testing note). Everything past classify
// (the HTTP/2 call itself) is sideshow/apns2's own tested code.
func TestClassifySuccessOn200(t *testing.T) {
	if got := classify(200, ""); got != OutcomeSuccess {
		t.Fatalf("expected OutcomeSuccess, got %v", got)
	}
}

func TestClassifyGoneOn410StatusRegardlessOfReason(t *testing.T) {
	if got := classify(410, "SomeUnexpectedReason"); got != OutcomeGone {
		t.Fatalf("expected OutcomeGone for status 410, got %v", got)
	}
}

func TestClassifyGoneOnPermanentReasons(t *testing.T) {
	for _, reason := range []string{"BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"} {
		if got := classify(400, reason); got != OutcomeGone {
			t.Fatalf("expected OutcomeGone for reason %q, got %v", reason, got)
		}
	}
}

func TestClassifyFailureForEverythingElse(t *testing.T) {
	for _, tc := range []struct {
		status int
		reason string
	}{
		{500, "InternalServerError"},
		{400, "PayloadTooLarge"},
		{403, "InvalidProviderToken"},
	} {
		if got := classify(tc.status, tc.reason); got != OutcomeFailure {
			t.Fatalf("expected OutcomeFailure for (%d, %q), got %v", tc.status, tc.reason, got)
		}
	}
}
