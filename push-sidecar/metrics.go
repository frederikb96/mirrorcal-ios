package main

import (
	"github.com/prometheus/client_golang/prometheus"
)

// Metrics is the whole observability surface, deliberately three values: "did the last
// tick's push go out", "when did one last succeed", and "how many devices are we even
// trying to reach" answer nearly every question this service could break in. Registered
// against a private registry rather than the global default, so tests can create a fresh
// Metrics per test without a "duplicate metrics collector registration" panic.
type Metrics struct {
	registry *prometheus.Registry

	PushAttemptsTotal      *prometheus.CounterVec
	PushLastSuccessSeconds prometheus.Gauge
	RegisteredDevices      prometheus.Gauge
}

func NewMetrics() *Metrics {
	m := &Metrics{registry: prometheus.NewRegistry()}

	m.PushAttemptsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mirrorcal_push_attempts_total",
		Help: "Silent push attempts, by result: success, failure, or gone (token deleted).",
	}, []string{"result"})

	m.PushLastSuccessSeconds = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "mirrorcal_push_last_success_timestamp_seconds",
		Help: "Unix time of the most recent tick with at least one successful push. Age of this is the first thing to check when the app stops syncing.",
	})

	m.RegisteredDevices = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "mirrorcal_registered_devices",
		Help: "Devices currently holding a registered token.",
	})

	m.registry.MustRegister(m.PushAttemptsTotal, m.PushLastSuccessSeconds, m.RegisteredDevices)
	return m
}
