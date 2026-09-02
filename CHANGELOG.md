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
