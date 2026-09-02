# mirrorcal-push

A Helm chart for the sidecar that wakes a [MirrorCal](https://github.com/frederikb96/mirrorcal-ios)
install with scheduled silent APNs pushes — see `../../push-sidecar/README.md` for what the
service itself does and why it exists. This chart is generic: it makes no assumption about
whose cluster it runs on, whose bundle id it serves, or which ingress controller fronts it.

## Before you install

You need:

1. **An Apple Developer account** with a registered app (your own fork/build of MirrorCal, or
   the upstream one under your own bundle id) and an **APNs Auth Key** (`.p8`) — App Store
   Connect → Certificates, Identifiers & Profiles → Keys. Note the key id and your team id.
2. **A Kubernetes cluster** with an ingress controller and, if you want automatic TLS,
   cert-manager. Neither is bundled — this chart only creates the resources that point at them.
3. **A hostname** this service will be reachable at, with DNS you can point at your cluster's
   ingress. Create the DNS record and let it resolve *before* installing if you're using
   cert-manager's HTTP-01 challenge — a certificate request against a hostname that doesn't
   resolve yet fails, and DNS caching can make that failure stick around longer than the actual
   propagation delay.
4. **A shared secret**, generated yourself (anything long and random) — you'll put the same
   value in this chart's `registration.sharedSecret` and in the app's own settings screen.

## For whoever cuts the first release

A freshly-pushed GHCR package defaults to **private** even though the repository is public —
one manual step, once, before anyone can pull it without a token: GitHub → the repo → Packages →
`mirrorcal-push` → Package settings → Change visibility → Public. Every later release to the
same package stays public; nothing in CI needs to repeat this.

## Installing

Add the repository and install with your own values:

```
helm repo add mirrorcal-push https://frederikb96.github.io/mirrorcal-ios/
helm repo update
helm install mirrorcal-push mirrorcal-push/mirrorcal-push \
  --namespace mirrorcal-push --create-namespace \
  -f my-values.yaml
```

Minimal `my-values.yaml`:

```yaml
apns:
  keyId: "YOUR_KEY_ID"
  teamId: "YOUR_TEAM_ID"
  bundleId: "com.yourname.mirrorcal"
  authKey:
    value: |
      -----BEGIN PRIVATE KEY-----
      ...your .p8 key content...
      -----END PRIVATE KEY-----

registration:
  sharedSecret:
    value: "generate-something-long-and-random-here"

ingress:
  className: "nginx"          # or whatever your cluster's ingress controller is called
  host: "mirrorcal-push.yourdomain.com"
  tls:
    secretName: "mirrorcal-push-tls"
    certManager:
      enabled: true
      issuerName: "letsencrypt"   # your ClusterIssuer's name
```

The chart validates the values that have no reasonable default (`apns.keyId`, `apns.teamId`,
`apns.bundleId`, `ingress.host`, either half of `apns.authKey`/`registration.sharedSecret`,
`ingress.tls.secretName` when TLS is on) and refuses to render without them — you'll get a clear
error naming exactly what's missing rather than a chart that installs and then fails quietly.

## Secrets: `existingSecret` vs inline `value`

Both `apns.authKey` and `registration.sharedSecret` accept either:

- `existingSecret` (+ `existingSecretKey`) — point at a Secret you already created and manage
  however you prefer (SOPS, sealed-secrets, Vault, or a plain `kubectl create secret generic`).
  The chart never touches it.
- `value` — hand the value to Helm directly, and the chart creates the Secret for you. Simplest
  for a first install; **do not commit a values file with a real key or secret in it to git**.

`existingSecret` wins if both are set.

## Everything the chart never assumes

No hardcoded hostname, bundle id, ingress class, or storage class — `ingress.host`,
`apns.bundleId`, `ingress.className` and `persistence.storageClassName` are all empty by default
and either required or fall back to your cluster's own default. The container image is public
(`ghcr.io/frederikb96/mirrorcal-push`, no auth needed to pull), so the chart needs zero
`imagePullSecrets` — the only secrets an install genuinely can't avoid are the two named above.

## Observability

`serviceMonitor.enabled: true` (plus whatever label your Prometheus Operator's own Prometheus CR
selects `ServiceMonitor`s by — `serviceMonitor.labels`) wires `/metrics` up for scraping.
`alerts.enabled: true` additionally ships a `PrometheusRule` that fires if
`mirrorcal_push_last_success_timestamp_seconds` hasn't advanced in `alerts.noSuccessHours` hours
while at least one device is registered — both opt-in, since a generic chart can't assume a
Prometheus Operator is even installed. See `../../push-sidecar/README.md`'s Observability
section for what each metric means.

## Values reference

See `values.yaml` — every value is commented there; this README doesn't repeat them.
