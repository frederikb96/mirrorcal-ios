# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository scaffolding: hand-written Xcode project with a synchronized app-target folder, the
  `MirrorCalKit` Swift package, free Linux CI and metered macOS CI, Swift 6 pre-flight lint
  tooling, and a debug bridge skeleton (`/health`) behind `#if DEBUG`.
- `push-sidecar/`: an optional Go service that holds a device-registration HTTP endpoint and an
  internal ticker, sending a scheduled silent APNs push to every registered device so the app
  gets a background wake-up on a cadence iOS itself gives no guarantee of.
- `charts/mirrorcal-push/`: the Helm chart for the sidecar above — installable by anyone with a
  Kubernetes cluster and their own Apple developer account, published independently of the app
  itself via its own tag prefix and CI workflows.
