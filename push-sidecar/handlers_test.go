package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer(t *testing.T) *Server {
	t.Helper()
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	return NewServer(store, "correct-horse-battery-staple", NewMetrics(), silentLogger())
}

const validToken = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"

func doRegister(t *testing.T, srv *Server, auth string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encoding request body: %v", err)
		}
	}
	req := httptest.NewRequest(http.MethodPost, "/api/register", &buf)
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	return rec
}

func TestRegisterSucceedsWithValidTokenAndSecret(t *testing.T) {
	srv := newTestServer(t)
	rec := doRegister(t, srv, "Bearer correct-horse-battery-staple", registerRequest{DeviceToken: validToken})

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var resp registerResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decoding response: %v", err)
	}
	if !resp.Registered || resp.Token != validToken {
		t.Fatalf("unexpected response: %+v", resp)
	}
}

func TestRegisterNormalizesCaseAndWhitespace(t *testing.T) {
	srv := newTestServer(t)
	messy := "  " + strings.ToUpper(validToken) + "  "
	rec := doRegister(t, srv, "Bearer correct-horse-battery-staple", registerRequest{DeviceToken: messy})

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var resp registerResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decoding response: %v", err)
	}
	if resp.Token != validToken {
		t.Fatalf("expected normalized token %q, got %q", validToken, resp.Token)
	}
}

func TestRegisterRejectsMissingAuthHeader(t *testing.T) {
	srv := newTestServer(t)
	rec := doRegister(t, srv, "", registerRequest{DeviceToken: validToken})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestRegisterRejectsWrongSecret(t *testing.T) {
	srv := newTestServer(t)
	rec := doRegister(t, srv, "Bearer wrong-secret", registerRequest{DeviceToken: validToken})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestRegisterRejectsMalformedAuthHeader(t *testing.T) {
	srv := newTestServer(t)
	// Missing the "Bearer " scheme prefix entirely.
	rec := doRegister(t, srv, "correct-horse-battery-staple", registerRequest{DeviceToken: validToken})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestRegisterRejectsEmptyToken(t *testing.T) {
	srv := newTestServer(t)
	rec := doRegister(t, srv, "Bearer correct-horse-battery-staple", registerRequest{DeviceToken: ""})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestRegisterRejectsNonHexToken(t *testing.T) {
	srv := newTestServer(t)
	rec := doRegister(t, srv, "Bearer correct-horse-battery-staple",
		registerRequest{DeviceToken: "not-a-hex-token-at-all-zzzzzzzzzzzzzzzz"})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestRegisterRejectsOversizedToken(t *testing.T) {
	srv := newTestServer(t)
	huge := strings.Repeat("a", 500)
	rec := doRegister(t, srv, "Bearer correct-horse-battery-staple", registerRequest{DeviceToken: huge})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestRegisterRejectsMalformedBody(t *testing.T) {
	srv := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/register", strings.NewReader("{not json"))
	req.Header.Set("Authorization", "Bearer correct-horse-battery-staple")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestRegisterIsIdempotentForTheSameToken(t *testing.T) {
	srv := newTestServer(t)
	doRegister(t, srv, "Bearer correct-horse-battery-staple", registerRequest{DeviceToken: validToken})
	doRegister(t, srv, "Bearer correct-horse-battery-staple", registerRequest{DeviceToken: validToken})

	count, err := srv.store.Count()
	if err != nil {
		t.Fatalf("Count: %v", err)
	}
	if count != 1 {
		t.Fatalf("re-registering the same token must not grow the store, got count=%d", count)
	}
}

func TestHealthzReportsOK(t *testing.T) {
	srv := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestMetricsEndpointServesPrometheusFormat(t *testing.T) {
	srv := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "mirrorcal_registered_devices") {
		t.Fatalf("expected metrics output to name mirrorcal_registered_devices, got: %s", rec.Body.String())
	}
}
