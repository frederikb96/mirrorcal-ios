package main

import (
	"testing"
	"time"
)

func TestStoreUpsertNewToken(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	now := time.Now().Truncate(time.Second)
	device, err := store.Upsert("aabbcc", now)
	if err != nil {
		t.Fatalf("Upsert: %v", err)
	}
	if device.Token != "aabbcc" || !device.LastSeenAt.Equal(now) {
		t.Fatalf("unexpected device: %+v", device)
	}

	devices, err := store.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(devices) != 1 {
		t.Fatalf("expected 1 device, got %d", len(devices))
	}
}

func TestStoreUpsertExistingTokenBumpsLastSeenWithoutGrowing(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	first := time.Now().Add(-time.Hour).Truncate(time.Second)
	second := time.Now().Truncate(time.Second)

	if _, err := store.Upsert("aabbcc", first); err != nil {
		t.Fatalf("first Upsert: %v", err)
	}
	if _, err := store.Upsert("aabbcc", second); err != nil {
		t.Fatalf("second Upsert: %v", err)
	}

	devices, err := store.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(devices) != 1 {
		t.Fatalf("re-registering the same token must not grow the store, got %d rows", len(devices))
	}
	if !devices[0].LastSeenAt.Equal(second) {
		t.Fatalf("expected last_seen_at bumped to %v, got %v", second, devices[0].LastSeenAt)
	}
}

func TestStoreDeleteManyDropsOnlyNamedTokens(t *testing.T) {
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

	// A token not present must be silently ignored, not an error — by the time a tick
	// runs, a device may already have re-registered under a different token.
	if err := store.DeleteMany([]string{"bbbb", "does-not-exist"}); err != nil {
		t.Fatalf("DeleteMany: %v", err)
	}

	devices, err := store.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(devices) != 2 {
		t.Fatalf("expected 2 remaining devices, got %d", len(devices))
	}
	for _, d := range devices {
		if d.Token == "bbbb" {
			t.Fatalf("bbbb should have been deleted")
		}
	}
}

func TestStorePersistsAcrossReload(t *testing.T) {
	dir := t.TempDir()
	store1, err := NewStore(dir)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	now := time.Now().Truncate(time.Second)
	if _, err := store1.Upsert("deadbeef", now); err != nil {
		t.Fatalf("Upsert: %v", err)
	}

	store2, err := NewStore(dir)
	if err != nil {
		t.Fatalf("NewStore (reload): %v", err)
	}
	devices, err := store2.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(devices) != 1 || devices[0].Token != "deadbeef" {
		t.Fatalf("state did not survive reload: %+v", devices)
	}
}

func TestStoreCountMatchesList(t *testing.T) {
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
	count, err := store.Count()
	if err != nil {
		t.Fatalf("Count: %v", err)
	}
	if count != 2 {
		t.Fatalf("expected count 2, got %d", count)
	}
}
