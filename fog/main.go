package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
)

// ── Thresholds ────────────────────────────────────────────────────────────────
const (
	ALERT_HR_HIGH   = 100.0
	ALERT_SPO2_LOW  = 94.0
	ALERT_TEMP_HIGH = 38.0
	WINDOW_SIZE     = 5
)

// ── Data structures ───────────────────────────────────────────────────────────
type VitalReading struct {
	PseudoID    string  `json:"pseudo_id"`
	Timestamp   string  `json:"timestamp"`
	HeartRate   float64 `json:"heart_rate"`
	SpO2        float64 `json:"spo2"`
	Temperature float64 `json:"temperature"`
	EdgeRecvTs  float64 `json:"edge_recv_ts"`
}

type Alert struct {
	PseudoID  string  `json:"pseudo_id"`
	AlertType string  `json:"alert_type"`
	Value     float64 `json:"value"`
	Threshold float64 `json:"threshold"`
	Timestamp string  `json:"timestamp"`
	LatencyMs float64 `json:"latency_ms"`
}

// ── Global state ──────────────────────────────────────────────────────────────
var (
	mu            sync.Mutex
	alerts        []Alert
	windows       = make(map[string][]VitalReading)
	firstAlertAt  *time.Time
	startTime     = time.Now()
	totalReceived int
)

// ── Sliding window ────────────────────────────────────────────────────────────
func pushWindow(id string, r VitalReading) {
	windows[id] = append(windows[id], r)
	if len(windows[id]) > WINDOW_SIZE {
		windows[id] = windows[id][1:]
	}
}

// ── Alert detection ───────────────────────────────────────────────────────────
func detectAlerts(r VitalReading) {
	now := time.Now()
	recvEpoch := time.Unix(int64(r.EdgeRecvTs), 0)
	latencyMs := float64(now.Sub(recvEpoch).Milliseconds())

	check := func(alertType string, value, threshold float64, isHigh bool) {
		if (isHigh && value > threshold) || (!isHigh && value < threshold) {
			a := Alert{
				PseudoID:  r.PseudoID,
				AlertType: alertType,
				Value:     value,
				Threshold: threshold,
				Timestamp: now.UTC().Format(time.RFC3339),
				LatencyMs: latencyMs,
			}
			alerts = append(alerts, a)
			if firstAlertAt == nil {
				t := now
				firstAlertAt = &t
				log.Printf("[TTFA] Time-to-First-Alert: %dms", now.Sub(startTime).Milliseconds())
			}
			log.Printf("[ALERT] %s | value=%.1f threshold=%.1f latency=%.1fms",
				alertType, value, threshold, latencyMs)
		}
	}

	check("HIGH_HEART_RATE", r.HeartRate, ALERT_HR_HIGH, true)
	check("LOW_SPO2", r.SpO2, ALERT_SPO2_LOW, false)
	check("HIGH_TEMPERATURE", r.Temperature, ALERT_TEMP_HIGH, true)
}

// ── mTLS handler: POST /data ──────────────────────────────────────────────────
func dataHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var reading VitalReading
	if err := json.NewDecoder(r.Body).Decode(&reading); err != nil {
		http.Error(w, "bad JSON", http.StatusBadRequest)
		return
	}
	mu.Lock()
	totalReceived++
	pushWindow(reading.PseudoID, reading)
	detectAlerts(reading)
	mu.Unlock()

	log.Printf("[DATA] pseudo_id=%s hr=%.1f spo2=%.1f temp=%.1f",
		reading.PseudoID, reading.HeartRate, reading.SpO2, reading.Temperature)
	w.WriteHeader(http.StatusOK)
	fmt.Fprintln(w, `{"status":"received"}`)
}

// ── Plain HTTP handlers: /alerts and /health ──────────────────────────────────
func alertsHandler(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"total_alerts":   len(alerts),
		"total_received": totalReceived,
		"uptime_seconds": int(time.Since(startTime).Seconds()),
		"alerts":         alerts,
	})
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, `{"status":"ok"}`)
}

// ── Entry point ───────────────────────────────────────────────────────────────
func main() {
	caCertPath := getEnv("CA_CERT", "/certs/ca/ca.crt")
	serverCert := getEnv("SERVER_CERT", "/certs/fog/fog.crt")
	serverKey := getEnv("SERVER_KEY", "/certs/fog/fog.key")
	mtlsPort := getEnv("MTLS_PORT", "8444")
	httpPort := getEnv("HTTP_PORT", "8445")

	caCert, err := os.ReadFile(caCertPath)
	if err != nil {
		log.Fatalf("CA cert read error: %v", err)
	}
	caPool := x509.NewCertPool()
	caPool.AppendCertsFromPEM(caCert)

	// ── mTLS server (port 8444): receives data from edges ────────────────────
	mtlsMux := http.NewServeMux()
	mtlsMux.HandleFunc("/data", dataHandler)

	mtlsSrv := &http.Server{
		Addr:    ":" + mtlsPort,
		Handler: mtlsMux,
		TLSConfig: &tls.Config{
			ClientCAs:  caPool,
			ClientAuth: tls.RequireAndVerifyClientCert,
			MinVersion: tls.VersionTLS13,
		},
	}

	// ── Plain HTTP server (port 8445): alerts + health ────────────────────────
	httpMux := http.NewServeMux()
	httpMux.HandleFunc("/alerts", alertsHandler)
	httpMux.HandleFunc("/health", healthHandler)

	httpSrv := &http.Server{
		Addr:    ":" + httpPort,
		Handler: httpMux,
	}

	go func() {
		log.Printf("Fog plain HTTP listening on port %s (/alerts, /health)", httpPort)
		if err := httpSrv.ListenAndServe(); err != nil {
			log.Fatalf("HTTP server error: %v", err)
		}
	}()

	log.Printf("Fog mTLS server listening on port %s (/data)", mtlsPort)
	log.Fatal(mtlsSrv.ListenAndServeTLS(serverCert, serverKey))
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
