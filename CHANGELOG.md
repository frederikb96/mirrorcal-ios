# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- MirrorCal: a one-way calendar mirror for iPhone. Point it at a source calendar (an Exchange
  work account, say) and a destination calendar (a private CalDAV one), and it copies events from
  the first into the second — never the other way; the source is read-only from the app's
  perspective, structurally, not just by convention. The point is a phone whose personal calendar
  shows work commitments without either calendar account needing to know the other exists.
- Per-field control over what gets copied: title, description and location each have their own
  policy — copy verbatim, drop, or replace with a fixed placeholder ("Busy") — with titles copied
  and everything else dropped by default. Specific titles can be excluded outright. A sync window
  (months back and forward) bounds what it looks at, and reconciliation is idempotent: running it
  twice over unchanged input creates nothing the second time.
  Deleted or moved source events are mirrored as deletions and moves, not left behind as orphans,
  and a duplicate that somehow ends up on the destination calendar is collapsed back to one rather
  than piling up.
  Two independent installs can point at the same shared destination calendar without either one
  deleting the other's events.
- Runs on its own: reacts to the calendar changing while the app is open, to being brought to the
  foreground, and to background refresh and processing tasks iOS schedules on its own cadence —
  plus an optional silent push (see `push-sidecar/` below) for a more reliable background wake-up
  than iOS alone guarantees. A Shortcuts action triggers a sync on demand. Swiping the app away in
  the App Switcher stops background syncing until it's reopened again — real iOS behaviour, stated
  plainly on the Status screen rather than left to be discovered as a mystery.
- Three screens: Status (last sync's outcome and a manual "Sync Now"), Configuration (calendars,
  window, field policies, exclusions, push sidecar), and Log — a share-able record of what the app
  has done, which matters because a TestFlight build has no debugger attached.
- `push-sidecar/`: an optional, self-hosted Go service plus Helm chart (`charts/mirrorcal-push/`)
  that sends the app a scheduled silent push, giving it a background wake-up on a cadence iOS
  itself does not guarantee. Independent of the app and versioned/released separately — anyone
  with a Kubernetes cluster and their own Apple developer account can run their own copy.

### Fixed

- The installation identifier now lives in the keychain rather than `UserDefaults`, so deleting
  and reinstalling the app no longer mints a new one — which used to make every previously
  mirrored event invisible to the app and get recreated, doubling the destination calendar with
  no way to clean it up.
- Push registration now runs on every foreground activation, not only the moment sync is first
  enabled — previously the deployed sidecar could go unregistered indefinitely, and filling in the
  sidecar host or secret after enabling never triggered a retry.
- Added a "Reset Mirror" control on the Status screen, with a confirmation that states how many
  events it will remove before removing them. `SyncEngine`'s reset mechanism existed and was
  tested but had no way to be invoked from the app.
- A sync that would create a number of events comparable to how many this installation already
  has in the destination is now refused rather than applied — the guard against an unbounded
  create-storm if a mirrored event's identity stamp does not survive a round trip to the
  destination and back. A first sync into an empty (or foreign-only) calendar is unaffected.
- The destination calendar is now scanned over a wider window than the source when syncing, so a
  mirrored event that has aged out of the source window — continuously, or because the window was
  just narrowed — is still reachable by the delete pass instead of being stranded.
- The destination-candidate check now refuses a calendar it could not read, instead of treating an
  unresolvable calendar or a failed read as clean.
- An update or delete now re-confirms the resolved event belongs to the destination calendar
  before touching it, rather than trusting an identifier resolved store-wide.
