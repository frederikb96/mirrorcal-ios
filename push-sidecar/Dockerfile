# Two stages: build a static binary with the Go toolchain, then ship nothing else. There is
# no runtime dependency (no interpreter, no shared libs to pin) — the whole point of choosing
# Go for a small always-on sidecar a stranger's cluster pulls sight-unseen.
FROM docker.io/library/golang:1.27-bookworm AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# CGO_ENABLED=0 is what makes the binary static — cross-building this on an arm64 CI runner
# for an amd64 node (or the reverse) must never silently link against the build host's libc.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/push-sidecar .

# distroless/static, not scratch: this binary makes outbound TLS calls to APNs and needs the
# CA bundle static-debian12 already carries — scratch would need one copied in by hand, one
# more thing to keep in sync with the build image's own certs.
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/push-sidecar /push-sidecar

# distroless/static's nonroot image already runs as uid 65532 (see the chart's own
# securityContext, which pins the same value explicitly rather than trusting the image
# default silently) — no USER directive needed here.
ENTRYPOINT ["/push-sidecar"]
