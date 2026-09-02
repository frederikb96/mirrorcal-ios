# push-sidecar

The server-side half of keeping MirrorCal fresh in the background. iOS gives an app no way to
be woken when a calendar changes — the strongest lever available is a **silent push**, which
wakes a suspended app for about thirty seconds to run its sync. This is the process that sends
those pushes, on a schedule, to whichever devices have registered with it.

It ships as an optional Helm chart in `../charts/mirrorcal-push/` — installable by anyone with a
Kubernetes cluster and their own Apple developer account, not only against Freddy's own copy of
the app. See that chart's own README for installing it.

## Shape

One process, one Go binary, no database:

- an internal ticker that, every `PUSH_INTERVAL_MINUTES` (default 20 — inside Apple's own
  throttle for background pushes, roughly 2-3/hour, with headroom), reads every registered
  device and sends each one a silent (`content-available`) push
- an HTTP endpoint, `POST /api/register`, that a phone calls to register its APNs device token
- a flat JSON file on a small persistent volume holding the registered tokens — not a database,
  because the whole dataset for a personal install is a handful of rows and the access pattern
  (upsert on register, list on tick, delete on APNs reporting a token gone) does not need one

A CronJob would in fact be *more* complex here: its pods are ephemeral and cannot hold open the
registration listener between runs, so a CronJob design would still need a second, always-on
Deployment just for registration. One process avoids that split.

**No backup.** State is self-healing — the app re-registers its token on every foreground
launch, so losing the volume costs one push cycle, nothing else.

## What a 200 from this service means, and does not mean

APNs accepts a push for a valid-looking token and reports success regardless of whether the
device ever actually receives it — a silent push is explicitly best-effort, and Apple may hold,
coalesce or drop it, including outright for an app the user has force-quit (there is no way
around this; see the app's own settings screen, which says so). So `mirrorcal_push_attempts_total{result="success"}`
means "APNs accepted it," not "the phone synced." The only way to confirm actual delivery is on
the phone itself, in the app's own sync log.

## Configuration

Every value is an environment variable — a ConfigMap for the ordinary ones, a Secret for the
two that are actually secret, which is what the chart wires up. Nothing here has a default that
silently masks a missing one: the process refuses to start rather than guess.

| Variable | Secret? | Default | Meaning |
|---|---|---|---|
| `APNS_KEY_ID` | no | — (required) | APNs auth key id |
| `APNS_TEAM_ID` | no | — (required) | Apple Developer team id |
| `APNS_TOPIC` | no | — (required) | The app's bundle id — also the APNs topic |
| `APNS_AUTH_KEY_PATH` | — | — (required) | Path to the mounted `.p8` key file |
| `REGISTRATION_SHARED_SECRET` | **yes** | — (required) | Bearer secret the app and this service both hold |
| `PUSH_INTERVAL_MINUTES` | no | `20` | Ticker interval |
| `DATA_DIR` | no | `/data` | Where `tokens.json` lives |
| `LISTEN_ADDR` | no | `:8080` | HTTP bind address |

There is no sandbox/production switch: TestFlight and App Store builds both only ever talk to
APNs production, so a `use_sandbox` flag would be a config value nothing would ever set
differently.

## The registration contract — what the app must implement

```
POST /api/register
Authorization: Bearer <shared secret, same value on both sides>
Content-Type: application/json

{"device_token": "<lowercase or uppercase hex, the token APNs handed the app>"}
```

Success (`200`):

```json
{"token": "<normalized, lowercased>", "registered": true, "last_seen_at": "<RFC3339>"}
```

- `401` for a missing, malformed, or wrong bearer token — the three cases are indistinguishable
  from outside, on purpose.
- `400` for a missing token or one that is not a bounded-length hex string.
- The call is idempotent: registering the same token again (which happens on every app launch
  that already has notification permission) only bumps `last_seen_at` — it never grows the
  store, and the app should call this on every launch without needing to track whether it
  already has.
- No unregister endpoint. The only deletion path is this service noticing APNs report a token
  permanently gone (`BadDeviceToken`, `Unregistered`, `DeviceTokenNotForTopic`, or HTTP 410) and
  dropping it on the next tick — a second, manual path to the same outcome was not worth adding.

## Observability

- `GET /healthz` — liveness/readiness.
- `GET /metrics` (Prometheus text format):
  - `mirrorcal_push_attempts_total{result="success|failure|gone"}`
  - `mirrorcal_push_last_success_timestamp_seconds` — the first thing to check when the app
    stops syncing: if this keeps advancing, the server side is working and the problem is
    downstream (the phone, or Apple's own best-effort delivery); if it stalls, it isn't.
  - `mirrorcal_registered_devices`
- A structured (JSON) log line after every tick: how many devices, how many succeeded, failed,
  or were dropped as permanently gone. A tick where *every* device failed for a reason other
  than "gone" logs at error level — that shape is a wholesale misconfiguration (wrong key, team
  id, or topic), not a single stale phone, and is worth distinguishing from the ordinary kind of
  gone-token cleanup that needs nobody's attention.

## Testing

`go test ./...` covers the token store (upsert/list/delete, idempotency, persistence across a
reload), the registration handler (auth in all its rejected forms, token validation, the happy
path), the scheduler's tick logic against a fake `Pusher` (fan-out, gone-token cleanup, the
last-success gauge), and the pure classification function that decides "gone" vs "retry" from an
APNs response. What is not, and cannot be, tested here: an actual push reaching APNs — the tests
stop at the boundary sideshow/apns2 owns, and nothing in this environment can complete a real
APNs handshake to check past it.

## Building

```
go build ./...
go vet ./...
go test ./...
podman build -t mirrorcal-push:local .
```

The image is `CGO_ENABLED=0`, built `FROM golang:...` and shipped on `distroless/static-debian12:nonroot`
— no shell, no package manager, nothing beyond the static binary and the CA bundle it needs to
reach APNs over TLS. It runs as the image's built-in non-root user; the chart pins that uid
explicitly (see the chart README's note on `fsGroup` — a PVC mounted into a non-root container
needs it, or the container cannot write its own token store).
