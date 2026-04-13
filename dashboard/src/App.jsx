import React, { useEffect, useMemo, useState } from "react";

const API_BASE = (import.meta.env.VITE_API_BASE_URL || "http://localhost:3000").replace(/\/$/, "");

function endpoint(path) {
  return `${API_BASE}${path}`;
}

function withLimit(queryString, limit) {
  const q = new URLSearchParams(queryString);
  q.set("limit", String(limit));
  return q.toString();
}

function asLocalTime(ts) {
  if (!ts) return "-";
  const d = new Date(ts);
  if (Number.isNaN(d.getTime())) return ts;
  return d.toLocaleString();
}

function defaultFilters() {
  return {
    pseudoId: "",
    alertType: "",
    severity: "",
    kind: "",
    limit: "100",
  };
}

export default function App() {
  const [filters, setFilters] = useState(defaultFilters);
  const [stats, setStats] = useState(null);
  const [alerts, setAlerts] = useState([]);
  const [logs, setLogs] = useState([]);
  const [alertRowsLabel, setAlertRowsLabel] = useState("0 rows");
  const [logRowsLabel, setLogRowsLabel] = useState("0 rows");
  const [apiStatus, setApiStatus] = useState("DOWN");
  const [refreshSec, setRefreshSec] = useState(30);
  const [errorBanner, setErrorBanner] = useState("");

  const alertsQuery = useMemo(() => {
    const q = new URLSearchParams();
    if (filters.pseudoId.trim()) q.set("pseudo_id", filters.pseudoId.trim());
    if (filters.alertType) q.set("type", filters.alertType);
    if (filters.severity) q.set("severity", filters.severity);
    q.set("limit", filters.limit || "100");
    return q.toString();
  }, [filters]);

  const logsQuery = useMemo(() => {
    const q = new URLSearchParams();
    if (filters.pseudoId.trim()) q.set("pseudo_id", filters.pseudoId.trim());
    if (filters.kind) q.set("kind", filters.kind);
    if (filters.alertType) q.set("type", filters.alertType);
    q.set("limit", filters.limit || "100");
    return q.toString();
  }, [filters]);

  async function fetchJson(url) {
    const res = await fetch(url, { cache: "no-store" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json();
  }

  async function refresh(options = {}) {
    if (window.location.protocol === "file:") {
      setErrorBanner("Dashboard must run via HTTP (Vite dev server). Do not open index.html as a local file.");
      setApiStatus("DOWN");
      return;
    }

    let logsQueryToUse = logsQuery;
    if (options.loadAllExistingLogs) {
      try {
        const snapshot = await fetchJson(endpoint("/stats"));
        const existingLogCount = Number(snapshot?.in_memory_logs || 0);
        if (existingLogCount > 0) {
          logsQueryToUse = withLimit(logsQuery, existingLogCount);
        }
      } catch {
        // Fall back to current UI limit if stats snapshot cannot be read.
      }
    }

    const [statsRes, alertsRes, logsRes] = await Promise.allSettled([
      fetchJson(endpoint("/stats")),
      fetchJson(endpoint(`/alerts?${alertsQuery}`)),
      fetchJson(endpoint(`/logs?${logsQueryToUse}`)),
    ]);

    let failures = 0;

    if (statsRes.status === "fulfilled") {
      setStats(statsRes.value);
    } else {
      failures += 1;
      setStats(null);
    }

    if (alertsRes.status === "fulfilled") {
      const items = alertsRes.value.alerts || [];
      setAlerts(items);
      setAlertRowsLabel(`${items.length} rows`);
    } else {
      failures += 1;
      setAlerts([]);
      setAlertRowsLabel("error");
    }

    if (logsRes.status === "fulfilled") {
      const items = logsRes.value.logs || [];
      setLogs(items);
      setLogRowsLabel(`${items.length} rows`);
    } else {
      failures += 1;
      setLogs([]);
      setLogRowsLabel("error");
    }

    if (failures === 0) {
      setApiStatus("UP");
      setErrorBanner("");
    } else if (failures < 3) {
      setApiStatus("DEGRADED");
      setErrorBanner("Some API endpoints failed. Check Fog logs and network path.");
    } else {
      setApiStatus("DOWN");
      setErrorBanner(`Cannot reach Fog API at ${API_BASE}. Ensure Fog is running and CORS is enabled.`);
    }
  }

  useEffect(() => {
    let timer;

    async function bootstrap() {
      try {
        const cfg = await fetchJson(endpoint("/config"));
        const sec = Math.max(5, Number(cfg.refresh_interval_seconds || 30));
        setRefreshSec(sec);
      } catch {
        setRefreshSec(30);
      }
      await refresh({ loadAllExistingLogs: true });
      timer = setInterval(() => {
        refresh().catch(() => {
          setApiStatus("DOWN");
        });
      }, refreshSec * 1000);
    }

    bootstrap().catch(() => {
      setApiStatus("DOWN");
      setErrorBanner(`Cannot reach Fog API at ${API_BASE}. Ensure Fog is running and CORS is enabled.`);
    });

    return () => {
      if (timer) clearInterval(timer);
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [alertsQuery, logsQuery, refreshSec]);

  const totalReceived = stats?.total_received ?? "-";
  const totalAlerts = stats?.in_memory_alerts ?? stats?.total_alerts ?? "-";
  const uptime = stats?.uptime_seconds ?? "-";

  return (
    <div className="wrap">
      <section className="hero">
        <h1 className="title">Fog Alert and Log Dashboard</h1>
        <p className="subtitle">Vite + React dashboard consuming Fog API over CORS.</p>
        <div className="stats-grid">
          <article className="card">
            <h4>Total Received</h4>
            <div className="big">{totalReceived}</div>
          </article>
          <article className="card">
            <h4>Total Alerts</h4>
            <div className="big">{totalAlerts}</div>
          </article>
          <article className="card">
            <h4>Uptime (s)</h4>
            <div className="big">{uptime}</div>
          </article>
          <article className="card">
            <h4>API Status</h4>
            <div className={`big ${apiStatus === "UP" ? "ok" : apiStatus === "DEGRADED" ? "warn" : "down"}`}>{apiStatus}</div>
          </article>
        </div>
      </section>

      <section className="panel panel-pad">
        <div className="filters">
          <div>
            <label>Pseudo ID</label>
            <input
              value={filters.pseudoId}
              onChange={(e) => setFilters((f) => ({ ...f, pseudoId: e.target.value }))}
              placeholder="optional"
            />
          </div>
          <div>
            <label>Alert Type</label>
            <select
              value={filters.alertType}
              onChange={(e) => setFilters((f) => ({ ...f, alertType: e.target.value }))}
            >
              <option value="">All</option>
              <option value="HIGH_HEART_RATE">HIGH_HEART_RATE</option>
              <option value="LOW_SPO2">LOW_SPO2</option>
              <option value="HIGH_TEMPERATURE">HIGH_TEMPERATURE</option>
            </select>
          </div>
          <div>
            <label>Severity</label>
            <select
              value={filters.severity}
              onChange={(e) => setFilters((f) => ({ ...f, severity: e.target.value }))}
            >
              <option value="">All</option>
              <option value="HIGH">HIGH</option>
              <option value="MEDIUM">MEDIUM</option>
            </select>
          </div>
          <div>
            <label>Log Kind</label>
            <select
              value={filters.kind}
              onChange={(e) => setFilters((f) => ({ ...f, kind: e.target.value }))}
            >
              <option value="">All</option>
              <option value="reading">reading</option>
              <option value="alert">alert</option>
            </select>
          </div>
          <div>
            <label>Rows</label>
            <select
              value={filters.limit}
              onChange={(e) => setFilters((f) => ({ ...f, limit: e.target.value }))}
            >
              <option value="50">50</option>
              <option value="100">100</option>
              <option value="200">200</option>
              <option value="500">500</option>
            </select>
          </div>
          <div className="btn-col">
            <button type="button" onClick={() => refresh()}>Apply Filters</button>
            <button className="secondary" type="button" onClick={() => setFilters(defaultFilters())}>Reset</button>
          </div>
        </div>
      </section>

      {errorBanner ? <div className="banner-error">{errorBanner}</div> : null}

      <section className="grid">
        <article className="panel">
          <header>
            <span>Alerts</span>
            <small>{alertRowsLabel}</small>
          </header>
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Pseudo ID</th>
                  <th>Type</th>
                  <th>Severity</th>
                  <th>Value</th>
                  <th>Latency</th>
                </tr>
              </thead>
              <tbody>
                {alerts.length === 0 ? (
                  <tr><td colSpan="6">No matching alerts</td></tr>
                ) : alerts.map((a, idx) => (
                  <tr key={`${a.timestamp}-${a.pseudo_id}-${idx}`}>
                    <td>{asLocalTime(a.timestamp)}</td>
                    <td>{a.pseudo_id || "-"}</td>
                    <td>{a.alert_type || "-"}</td>
                    <td><span className={`badge ${a.severity === "HIGH" ? "sev-high" : "sev-medium"}`}>{a.severity || "MEDIUM"}</span></td>
                    <td>{typeof a.value === "number" ? a.value.toFixed(1) : "-"}</td>
                    <td>{typeof a.latency_ms === "number" ? `${Math.round(a.latency_ms)}ms` : "-"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </article>

        <article className="panel">
          <header>
            <span>Logs</span>
            <small>{logRowsLabel}</small>
          </header>
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Kind</th>
                  <th>Pseudo ID</th>
                  <th>Message</th>
                  <th>Type</th>
                </tr>
              </thead>
              <tbody>
                {logs.length === 0 ? (
                  <tr><td colSpan="5">No matching logs</td></tr>
                ) : logs.map((l, idx) => (
                  <tr key={`${l.timestamp}-${l.kind}-${idx}`}>
                    <td>{asLocalTime(l.timestamp)}</td>
                    <td>{l.kind || "-"}</td>
                    <td>{l.pseudo_id || "-"}</td>
                    <td>{l.message || "-"}</td>
                    <td>{l.alert_type || "-"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </article>
      </section>

      <p className="footer">API base: {API_BASE} · Refresh interval: {refreshSec}s</p>
    </div>
  );
}
