package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awscfg "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/lambda"
	lambdatypes "github.com/aws/aws-sdk-go-v2/service/lambda/types"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/joho/godotenv"
)

const (
	alertHRHigh   = 100.0
	alertSpO2Low  = 94.0
	alertTempHigh = 38.0
	windowSize    = 5
)

type VitalReading struct {
	PseudoID    string  `json:"pseudo_id"`
	Timestamp   string  `json:"timestamp"`
	HeartRate   float64 `json:"heart_rate"`
	SpO2        float64 `json:"spo2"`
	Temperature float64 `json:"temperature"`
	EdgeRecvTs  float64 `json:"edge_recv_ts"`
}

type Alert struct {
	PseudoID     string  `json:"pseudo_id"`
	AlertType    string  `json:"alert_type"`
	Value        float64 `json:"value"`
	Threshold    float64 `json:"threshold"`
	Timestamp    string  `json:"timestamp"`
	LatencyMs    float64 `json:"latency_ms"`
	Severity     string  `json:"severity"`
	TriggeredBy  string  `json:"triggered_by"`
	ReadingAtFog string  `json:"reading_at_fog"`
}

type LogEvent struct {
	Kind        string  `json:"kind"`
	Timestamp   string  `json:"timestamp"`
	PseudoID    string  `json:"pseudo_id"`
	Message     string  `json:"message"`
	AlertType   string  `json:"alert_type,omitempty"`
	HeartRate   float64 `json:"heart_rate,omitempty"`
	SpO2        float64 `json:"spo2,omitempty"`
	Temperature float64 `json:"temperature,omitempty"`
	LatencyMs   float64 `json:"latency_ms,omitempty"`
}

type AppConfig struct {
	HTTPPort               string
	AWSRegion              string
	S3BucketName           string
	EnableS3Logging        bool
	LambdaFunctionName     string
	EnableLambdaNotify     bool
	EnableAudioAlerts      bool
	RefreshIntervalSeconds int
	MaxAlerts              int
	MaxReadings            int
	MaxLogEvents           int
}

type AWSClients struct {
	s3Client     *s3.Client
	lambdaClient *lambda.Client
}

var (
	mu            sync.Mutex
	alerts        []Alert
	readings      []VitalReading
	logEvents     []LogEvent
	windows       = make(map[string][]VitalReading)
	firstAlertAt  *time.Time
	startTime     = time.Now()
	totalReceived int

	cfg        AppConfig
	awsClients AWSClients
)

func main() {
	_ = godotenv.Load()

	cfg = loadConfig()
	awsClients = initAWSClients(cfg)

	mux := http.NewServeMux()
	mux.HandleFunc("/data", withCORS(dataHandler))
	mux.HandleFunc("/alerts", withCORS(alertsHandler))
	mux.HandleFunc("/readings", withCORS(readingsHandler))
	mux.HandleFunc("/logs", withCORS(logsHandler))
	mux.HandleFunc("/stats", withCORS(statsHandler))
	mux.HandleFunc("/config", withCORS(configHandler))
	mux.HandleFunc("/health", withCORS(healthHandler))
	mux.HandleFunc("/", withCORS(rootHandler))

	log.Printf("Fog HTTP server listening on port %s", cfg.HTTPPort)
	log.Printf("S3 logging=%t bucket=%s", cfg.EnableS3Logging, cfg.S3BucketName)
	log.Printf("Lambda notifications=%t function=%s", cfg.EnableLambdaNotify, cfg.LambdaFunctionName)
	log.Printf("Audio alerts=%t", cfg.EnableAudioAlerts)

	server := &http.Server{
		Addr:    ":" + cfg.HTTPPort,
		Handler: mux,
	}
	log.Fatal(server.ListenAndServe())
}

func loadConfig() AppConfig {
	return AppConfig{
		HTTPPort:               getEnv("HTTP_PORT", getEnv("PORT", "8080")),
		AWSRegion:              getEnv("AWS_REGION", "ap-southeast-1"),
		S3BucketName:           getEnv("S3_BUCKET_NAME", ""),
		EnableS3Logging:        getEnvBool("ENABLE_S3_LOGGING", false),
		LambdaFunctionName:     getEnv("LAMBDA_FUNCTION_NAME", ""),
		EnableLambdaNotify:     getEnvBool("ENABLE_LAMBDA_NOTIFICATIONS", false),
		EnableAudioAlerts:      getEnvBool("ENABLE_AUDIO_ALERTS", true),
		RefreshIntervalSeconds: getEnvInt("REFRESH_INTERVAL_SECONDS", 30),
		MaxAlerts:              getEnvInt("MAX_ALERTS", 2000),
		MaxReadings:            getEnvInt("MAX_READINGS", 5000),
		MaxLogEvents:           getEnvInt("MAX_LOG_EVENTS", 10000),
	}
}

func initAWSClients(c AppConfig) AWSClients {
	clients := AWSClients{}
	if !c.EnableS3Logging && !c.EnableLambdaNotify {
		return clients
	}

	awsCfg, err := awscfg.LoadDefaultConfig(context.Background(), awscfg.WithRegion(c.AWSRegion))
	if err != nil {
		log.Printf("[WARN] AWS SDK init failed, disabling cloud integrations: %v", err)
		return clients
	}

	if c.EnableS3Logging {
		if c.S3BucketName == "" {
			log.Printf("[WARN] ENABLE_S3_LOGGING=true but S3_BUCKET_NAME is empty")
		} else {
			clients.s3Client = s3.NewFromConfig(awsCfg)
		}
	}

	if c.EnableLambdaNotify {
		if c.LambdaFunctionName == "" {
			log.Printf("[WARN] ENABLE_LAMBDA_NOTIFICATIONS=true but LAMBDA_FUNCTION_NAME is empty")
		} else {
			clients.lambdaClient = lambda.NewFromConfig(awsCfg)
		}
	}

	return clients
}

func dataHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}

	var reading VitalReading
	if err := json.NewDecoder(r.Body).Decode(&reading); err != nil {
		http.Error(w, "bad JSON", http.StatusBadRequest)
		return
	}
	if reading.PseudoID == "" {
		http.Error(w, "pseudo_id required", http.StatusBadRequest)
		return
	}

	fogNow := time.Now().UTC()
	newAlerts := detectAlerts(reading, fogNow)

	mu.Lock()
	totalReceived++
	pushWindow(reading.PseudoID, reading)
	readings = appendWithLimit(readings, reading, cfg.MaxReadings)

	readingEvent := LogEvent{
		Kind:        "reading",
		Timestamp:   fogNow.Format(time.RFC3339),
		PseudoID:    reading.PseudoID,
		Message:     "Reading received at fog",
		HeartRate:   reading.HeartRate,
		SpO2:        reading.SpO2,
		Temperature: reading.Temperature,
	}
	logEvents = appendWithLimit(logEvents, readingEvent, cfg.MaxLogEvents)

	if firstAlertAt == nil && len(newAlerts) > 0 {
		t := fogNow
		firstAlertAt = &t
		log.Printf("[TTFA] Time-to-First-Alert: %dms", fogNow.Sub(startTime).Milliseconds())
	}

	for _, a := range newAlerts {
		alerts = appendWithLimit(alerts, a, cfg.MaxAlerts)
		logEvents = appendWithLimit(logEvents, LogEvent{
			Kind:        "alert",
			Timestamp:   a.Timestamp,
			PseudoID:    a.PseudoID,
			Message:     fmt.Sprintf("%s triggered", a.AlertType),
			AlertType:   a.AlertType,
			HeartRate:   reading.HeartRate,
			SpO2:        reading.SpO2,
			Temperature: reading.Temperature,
			LatencyMs:   a.LatencyMs,
		}, cfg.MaxLogEvents)
	}
	mu.Unlock()

	log.Printf("[DATA] pseudo_id=%s hr=%.1f spo2=%.1f temp=%.1f", reading.PseudoID, reading.HeartRate, reading.SpO2, reading.Temperature)

	if cfg.EnableS3Logging {
		go putJSONToS3("readings", reading)
		go putJSONToS3("logs", readingEvent)
	}
	for _, a := range newAlerts {
		log.Printf("[ALERT] %s | pseudo_id=%s value=%.1f threshold=%.1f latency=%.1fms", a.AlertType, a.PseudoID, a.Value, a.Threshold, a.LatencyMs)
		handleAlertActions(a)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":      "received",
		"alert_count": len(newAlerts),
	})
}

func detectAlerts(r VitalReading, now time.Time) []Alert {
	latencyMs := 0.0
	if r.EdgeRecvTs > 0 {
		edgeTs := time.Unix(0, int64(r.EdgeRecvTs*float64(time.Second)))
		latencyMs = math.Max(0, float64(now.Sub(edgeTs).Milliseconds()))
	}

	mkAlert := func(alertType string, value, threshold float64, triggeredBy string) Alert {
		severity := "MEDIUM"
		if alertType == "HIGH_HEART_RATE" && value >= 130 {
			severity = "HIGH"
		}
		if alertType == "LOW_SPO2" && value <= 90 {
			severity = "HIGH"
		}
		if alertType == "HIGH_TEMPERATURE" && value >= 39 {
			severity = "HIGH"
		}
		return Alert{
			PseudoID:     r.PseudoID,
			AlertType:    alertType,
			Value:        value,
			Threshold:    threshold,
			Timestamp:    now.Format(time.RFC3339),
			LatencyMs:    latencyMs,
			Severity:     severity,
			TriggeredBy:  triggeredBy,
			ReadingAtFog: now.Format(time.RFC3339),
		}
	}

	out := make([]Alert, 0, 3)
	if r.HeartRate > alertHRHigh {
		out = append(out, mkAlert("HIGH_HEART_RATE", r.HeartRate, alertHRHigh, "heart_rate"))
	}
	if r.SpO2 < alertSpO2Low {
		out = append(out, mkAlert("LOW_SPO2", r.SpO2, alertSpO2Low, "spo2"))
	}
	if r.Temperature > alertTempHigh {
		out = append(out, mkAlert("HIGH_TEMPERATURE", r.Temperature, alertTempHigh, "temperature"))
	}
	return out
}

func handleAlertActions(alert Alert) {
	if cfg.EnableAudioAlerts {
		go playLocalBuzz()
	}
	if cfg.EnableS3Logging {
		go putJSONToS3("alerts", alert)
		go putJSONToS3("logs", LogEvent{
			Kind:      "alert",
			Timestamp: alert.Timestamp,
			PseudoID:  alert.PseudoID,
			Message:   fmt.Sprintf("%s raised", alert.AlertType),
			AlertType: alert.AlertType,
			LatencyMs: alert.LatencyMs,
		})
	}
	if cfg.EnableLambdaNotify {
		go invokeAlertLambda(alert)
	}
}

func playLocalBuzz() {
	commands := []string{
		"command -v afplay >/dev/null && afplay /System/Library/Sounds/Funk.aiff",
		"command -v paplay >/dev/null && paplay /usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga",
	}

	for i := 0; i < 10; i++ {
		fmt.Print("\a")
		played := false
		for _, c := range commands {
			if err := exec.Command("sh", "-c", c).Run(); err == nil {
				played = true
				break
			}
		}

		if !played {
			time.Sleep(150 * time.Millisecond)
		}
	}
}

func invokeAlertLambda(alert Alert) {
	if awsClients.lambdaClient == nil || cfg.LambdaFunctionName == "" {
		return
	}
	payload, err := json.Marshal(map[string]interface{}{
		"source": "fog-service",
		"alert":  alert,
	})
	if err != nil {
		log.Printf("[WARN] lambda payload marshal error: %v", err)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err = awsClients.lambdaClient.Invoke(ctx, &lambda.InvokeInput{
		FunctionName:   aws.String(cfg.LambdaFunctionName),
		InvocationType: lambdatypes.InvocationTypeEvent,
		Payload:        payload,
	})
	if err != nil {
		log.Printf("[WARN] lambda invoke failed: %v", err)
	}
}

func putJSONToS3(prefix string, v interface{}) {
	if awsClients.s3Client == nil || cfg.S3BucketName == "" {
		return
	}
	body, err := json.Marshal(v)
	if err != nil {
		log.Printf("[WARN] s3 marshal failed: %v", err)
		return
	}

	key := fmt.Sprintf("%s/%s-%d.json", strings.Trim(prefix, "/"), time.Now().UTC().Format("2006/01/02/150405"), time.Now().UnixNano())
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()

	_, err = awsClients.s3Client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(cfg.S3BucketName),
		Key:         aws.String(key),
		Body:        bytes.NewReader(body),
		ContentType: aws.String("application/json"),
	})
	if err != nil {
		log.Printf("[WARN] s3 put failed for key=%s: %v", key, err)
	}
}

func alertsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	alertType := strings.TrimSpace(r.URL.Query().Get("type"))
	pseudoID := strings.TrimSpace(r.URL.Query().Get("pseudo_id"))
	severity := strings.TrimSpace(r.URL.Query().Get("severity"))
	limit := queryInt(r, "limit", 200)

	mu.Lock()
	localAlerts := append([]Alert(nil), alerts...)
	localTotal := totalReceived
	localUptime := int(time.Since(startTime).Seconds())
	mu.Unlock()

	filtered := make([]Alert, 0, len(localAlerts))
	for i := len(localAlerts) - 1; i >= 0; i-- {
		a := localAlerts[i]
		if alertType != "" && a.AlertType != alertType {
			continue
		}
		if pseudoID != "" && a.PseudoID != pseudoID {
			continue
		}
		if severity != "" && a.Severity != severity {
			continue
		}
		filtered = append(filtered, a)
		if limit > 0 && len(filtered) >= limit {
			break
		}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"total_alerts":   len(localAlerts),
		"total_received": localTotal,
		"uptime_seconds": localUptime,
		"count":          len(filtered),
		"alerts":         filtered,
	})
}

func readingsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	pseudoID := strings.TrimSpace(r.URL.Query().Get("pseudo_id"))
	limit := queryInt(r, "limit", 300)

	mu.Lock()
	localReadings := append([]VitalReading(nil), readings...)
	mu.Unlock()

	filtered := make([]VitalReading, 0, len(localReadings))
	for i := len(localReadings) - 1; i >= 0; i-- {
		rd := localReadings[i]
		if pseudoID != "" && rd.PseudoID != pseudoID {
			continue
		}
		filtered = append(filtered, rd)
		if limit > 0 && len(filtered) >= limit {
			break
		}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"count":    len(filtered),
		"readings": filtered,
	})
}

func logsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	kind := strings.TrimSpace(r.URL.Query().Get("kind"))
	pseudoID := strings.TrimSpace(r.URL.Query().Get("pseudo_id"))
	alertType := strings.TrimSpace(r.URL.Query().Get("type"))
	limit := queryInt(r, "limit", 500)

	mu.Lock()
	localEvents := append([]LogEvent(nil), logEvents...)
	mu.Unlock()

	filtered := make([]LogEvent, 0, len(localEvents))
	for i := len(localEvents) - 1; i >= 0; i-- {
		e := localEvents[i]
		if kind != "" && e.Kind != kind {
			continue
		}
		if pseudoID != "" && e.PseudoID != pseudoID {
			continue
		}
		if alertType != "" && e.AlertType != alertType {
			continue
		}
		filtered = append(filtered, e)
		if limit > 0 && len(filtered) >= limit {
			break
		}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"count": len(filtered),
		"logs":  filtered,
	})
}

func statsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	mu.Lock()
	localAlerts := len(alerts)
	localReadings := len(readings)
	localEvents := len(logEvents)
	localTotal := totalReceived
	uptime := int(time.Since(startTime).Seconds())
	mu.Unlock()

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"total_received":     localTotal,
		"in_memory_alerts":   localAlerts,
		"in_memory_readings": localReadings,
		"in_memory_logs":     localEvents,
		"uptime_seconds":     uptime,
		"s3_logging":         cfg.EnableS3Logging,
		"lambda_notify":      cfg.EnableLambdaNotify,
		"audio_alerts":       cfg.EnableAudioAlerts,
	})
}

func configHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"refresh_interval_seconds": cfg.RefreshIntervalSeconds,
	})
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func rootHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"service": "fec-fog-api",
		"message": "Run the Vite dashboard app separately and connect to this API via CORS.",
	})
}

func pushWindow(id string, r VitalReading) {
	windows[id] = append(windows[id], r)
	if len(windows[id]) > windowSize {
		windows[id] = windows[id][1:]
	}
}

func withCORS(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		next(w, r)
	}
}

func writeJSON(w http.ResponseWriter, status int, payload interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("[WARN] response encode error: %v", err)
	}
}

func queryInt(r *http.Request, key string, def int) int {
	raw := strings.TrimSpace(r.URL.Query().Get(key))
	if raw == "" {
		return def
	}
	v, err := strconv.Atoi(raw)
	if err != nil || v <= 0 {
		return def
	}
	return v
}

func appendWithLimit[T any](items []T, item T, limit int) []T {
	items = append(items, item)
	if limit > 0 && len(items) > limit {
		return items[len(items)-limit:]
	}
	return items
}

func getEnv(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func getEnvInt(key string, def int) int {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		parsed, err := strconv.Atoi(v)
		if err == nil {
			return parsed
		}
	}
	return def
}

func getEnvBool(key string, def bool) bool {
	v := strings.TrimSpace(strings.ToLower(os.Getenv(key)))
	if v == "" {
		return def
	}
	return v == "1" || v == "true" || v == "yes" || v == "on"
}
