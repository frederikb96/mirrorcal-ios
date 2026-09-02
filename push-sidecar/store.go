package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Device is one registered APNs device token. Keyed on the token itself, not a generated
// device id, the same shape pai-cloud's DeviceToken uses and for the same reason: a device
// re-registering after a reinstall is a new token on the same phone, which is simply a new
// row, and the token APNs eventually reports gone is deleted the ordinary way — nothing
// here needs to correlate a token back to a physical device across a reinstall.
type Device struct {
	Token      string    `json:"token"`
	LastSeenAt time.Time `json:"last_seen_at"`
}

// Store is a small file-backed set of device tokens — deliberately not a database. The
// entire dataset for a personal install is a handful of rows (one or two phones), the
// access pattern is upsert-on-register, list-on-tick, delete-on-APNs-410, and none of that
// earns SQLite's own complexity, let alone a real database service. State is self-healing:
// the app re-registers on every foreground launch, so losing this file costs one push
// cycle and nothing else — which is also why there is no backup entry for it anywhere.
type Store struct {
	path string
	mu   sync.Mutex
}

// NewStore points a Store at a JSON file under dir, creating the directory and an empty
// file if neither exists yet — the state a fresh PVC starts in.
func NewStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, fmt.Errorf("creating data directory %q: %w", dir, err)
	}
	s := &Store{path: filepath.Join(dir, "tokens.json")}
	if _, err := os.Stat(s.path); os.IsNotExist(err) {
		if err := s.writeLocked(nil); err != nil {
			return nil, err
		}
	} else if err != nil {
		return nil, fmt.Errorf("checking %q: %w", s.path, err)
	}
	return s, nil
}

func (s *Store) readLocked() ([]Device, error) {
	raw, err := os.ReadFile(s.path)
	if err != nil {
		return nil, fmt.Errorf("reading %q: %w", s.path, err)
	}
	if len(raw) == 0 {
		return nil, nil
	}
	var devices []Device
	if err := json.Unmarshal(raw, &devices); err != nil {
		return nil, fmt.Errorf("parsing %q: %w", s.path, err)
	}
	return devices, nil
}

// writeLocked replaces the file's whole contents via a temp-file-plus-rename, so a crash
// mid-write leaves either the old file or the new one, never a half-written one a later
// read would fail to parse.
func (s *Store) writeLocked(devices []Device) error {
	if devices == nil {
		devices = []Device{}
	}
	raw, err := json.MarshalIndent(devices, "", "  ")
	if err != nil {
		return fmt.Errorf("encoding token store: %w", err)
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o640); err != nil {
		return fmt.Errorf("writing %q: %w", tmp, err)
	}
	if err := os.Rename(tmp, s.path); err != nil {
		return fmt.Errorf("renaming %q to %q: %w", tmp, s.path, err)
	}
	return nil
}

// Upsert records a device as seen now. Registering the same token again — which happens on
// every app launch that already has permission — only bumps LastSeenAt; it never grows the
// store, the same upsert-on-token-value shape pai-cloud's own device table uses.
func (s *Store) Upsert(token string, now time.Time) (Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	devices, err := s.readLocked()
	if err != nil {
		return Device{}, err
	}
	updated := Device{Token: token, LastSeenAt: now}
	for i, d := range devices {
		if d.Token == token {
			devices[i] = updated
			if err := s.writeLocked(devices); err != nil {
				return Device{}, err
			}
			return updated, nil
		}
	}
	devices = append(devices, updated)
	if err := s.writeLocked(devices); err != nil {
		return Device{}, err
	}
	return updated, nil
}

// List returns every registered device, ordered by token so callers and tests see a
// stable order rather than whatever order the file happened to hold them in.
func (s *Store) List() ([]Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	devices, err := s.readLocked()
	if err != nil {
		return nil, err
	}
	sort.Slice(devices, func(i, j int) bool { return devices[i].Token < devices[j].Token })
	return devices, nil
}

// DeleteMany removes every token in gone — the tick loop's own cleanup after APNs reports
// a token permanently dead. Tokens not present are ignored rather than treated as an
// error: by the time a tick runs, a device may already have re-registered under a new
// token, which naturally leaves the old one absent.
func (s *Store) DeleteMany(gone []string) error {
	if len(gone) == 0 {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	toDrop := make(map[string]struct{}, len(gone))
	for _, t := range gone {
		toDrop[t] = struct{}{}
	}
	devices, err := s.readLocked()
	if err != nil {
		return err
	}
	kept := devices[:0]
	for _, d := range devices {
		if _, drop := toDrop[d.Token]; !drop {
			kept = append(kept, d)
		}
	}
	return s.writeLocked(kept)
}

// Count is List without allocating Device copies past what List itself does — used by the
// mirrorcal_registered_devices gauge, which asks nothing else about each device.
func (s *Store) Count() (int, error) {
	devices, err := s.List()
	if err != nil {
		return 0, err
	}
	return len(devices), nil
}
