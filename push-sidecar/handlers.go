package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	minTokenLen = 32
	maxTokenLen = 200
)

// registerRequest is the whole contract the app side of this must implement: POST a hex
// device token, bearer-authenticated with the shared secret configured on both ends. See
// the README's "App-side contract" section — this struct and its response are that
// contract, not merely this service's own internal shape.
type registerRequest struct {
	DeviceToken string `json:"device_token"`
}

type registerResponse struct {
	Token      string `json:"token"`
	Registered bool   `json:"registered"`
	LastSeenAt string `json:"last_seen_at"`
}

// Server holds everything an HTTP handler needs and nothing a handler shouldn't reach
// directly — the store and the shared secret, not the pusher or the scheduler, since
// registration never triggers a push itself.
type Server struct {
	store        *Store
	sharedSecret [32]byte // sha256 of the configured secret, compared in constant time below
	metrics      *Metrics
	log          *slog.Logger
	now          func() time.Time
}

func NewServer(store *Store, sharedSecret string, metrics *Metrics, log *slog.Logger) *Server {
	return &Server{
		store:        store,
		sharedSecret: sha256.Sum256([]byte(sharedSecret)),
		metrics:      metrics,
		log:          log,
		now:          time.Now,
	}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/register", s.handleRegister)
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.Handle("GET /metrics", promhttp.HandlerFor(s.metrics.registry, promhttp.HandlerOpts{}))
	return mux
}

// authorized checks the bearer token against the configured shared secret without
// revealing anything about *why* a request was rejected — a wrong secret and a missing
// header both simply fail. Both sides are hashed to a fixed 32 bytes first so the
// comparison itself never depends on the length of what the caller sent, and
// subtle.ConstantTimeCompare keeps the byte-by-byte comparison itself constant-time.
func (s *Server) authorized(r *http.Request) bool {
	auth := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if !strings.HasPrefix(auth, prefix) {
		return false
	}
	given := sha256.Sum256([]byte(strings.TrimPrefix(auth, prefix)))
	return subtle.ConstantTimeCompare(given[:], s.sharedSecret[:]) == 1
}

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		// No body, no detail: whether the header was missing, malformed, or simply
		// wrong all look identical from outside — nothing here narrows the search
		// for anyone probing this endpoint.
		w.WriteHeader(http.StatusUnauthorized)
		return
	}

	var req registerRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "malformed request body", http.StatusBadRequest)
		return
	}

	token := strings.ToLower(strings.TrimSpace(req.DeviceToken))
	if !isValidToken(token) {
		http.Error(w, "device_token is required and must be a hex string", http.StatusBadRequest)
		return
	}

	now := s.now()
	device, err := s.store.Upsert(token, now)
	if err != nil {
		s.log.Error("register: could not persist token", "error", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	if count, err := s.store.Count(); err == nil {
		s.metrics.RegisteredDevices.Set(float64(count))
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(registerResponse{
		Token:      device.Token,
		Registered: true,
		LastSeenAt: device.LastSeenAt.UTC().Format(time.RFC3339),
	})
}

// isValidToken accepts what an APNs device token actually looks like — a hex string,
// bounded in length — rather than the empty "non-empty string" check a gated backend can
// get away with. This endpoint has no OIDC in front of it, so the validation here is the
// only thing standing between it and arbitrary junk in the store.
func isValidToken(token string) bool {
	if len(token) < minTokenLen || len(token) > maxTokenLen {
		return false
	}
	for _, c := range token {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}
