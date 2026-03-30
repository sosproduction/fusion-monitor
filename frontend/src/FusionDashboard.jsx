import { useState, useEffect, useRef, useCallback } from "react";

// ── Google Fonts ──────────────────────────────────────────────────────────────
if (typeof document !== "undefined") {
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = "https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Orbitron:wght@400;700;900&display=swap";
  document.head.appendChild(link);
}

// ── Prometheus API ────────────────────────────────────────────────────────────
// In production (served by nginx) calls go to /prometheus/api/v1/query
// which nginx proxies to http://prometheus:9090/api/v1/query
const PROM_BASE = "/prometheus/api/v1/query";

async function promQuery(metric) {
  const url = `${PROM_BASE}?query=${encodeURIComponent(metric)}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Prometheus ${res.status}: ${metric}`);
  const json = await res.json();
  const result = json?.data?.result?.[0];
  if (!result) return null;
  return parseFloat(result.value[1]);
}

async function promQueryAll(metrics) {
  const entries = await Promise.allSettled(
    metrics.map(async ([key, expr]) => {
      const val = await promQuery(expr);
      return [key, val];
    })
  );
  const out = {};
  for (const e of entries) {
    if (e.status === "fulfilled" && e.value[1] !== null) {
      out[e.value[0]] = e.value[1];
    }
  }
  return out;
}

// All metrics to fetch — [stateKey, prometheusExpression]
const METRIC_MAP = [
  ["plasma_temp_kev",     "fusion_plasma_temperature_keV"],
  ["ion_temp_kev",        "fusion_diag_ion_temperature_keV"],
  ["plasma_density",      "fusion_plasma_density_per_m3"],
  ["q_factor",            "fusion_plasma_gain_Q"],
  ["fusion_power",        "fusion_plasma_fusion_power_MW"],
  ["heating_power",       "fusion_plasma_heating_power_MW"],
  ["net_electrical",      "fusion_power_net_electrical_MW"],
  ["disruption_risk",     "fusion_mag_disruption_risk_percent"],
  ["toroidal_field",      "fusion_mag_toroidal_field_tesla"],
  ["poloidal_field",      "fusion_mag_poloidal_field_tesla"],
  ["plasma_current",      "fusion_mag_plasma_current_MA"],
  ["elm_freq",            "fusion_mag_ELM_frequency_Hz"],
  ["plasma_beta",         "fusion_plasma_beta_value"],
  ["temp_inner_div",      "fusion_divertor_temp_inner_C"],
  ["temp_outer_div",      "fusion_divertor_temp_outer_C"],
  ["temp_wall",           "fusion_divertor_temp_wall_C"],
  ["coolant_outlet",      "fusion_cooling_outlet_temp_C"],
  ["coolant_inlet",       "fusion_cooling_inlet_temp_C"],
  ["coolant_flow",        "fusion_cooling_flow_kg_per_s"],
  ["cryo_he",             "fusion_cryo_helium_temp_K"],
  ["tritium_inventory",   "fusion_tritium_inventory_grams"],
  ["tritium_tbr",         "fusion_tritium_breeding_ratio"],
  ["tritium_airborne",    "fusion_tritium_airborne_Bq_per_m3"],
  ["tritium_burn_rate",   "fusion_tritium_burn_rate_mg_per_s"],
  ["neutron_flux",        "fusion_rad_neutron_flux_per_cm2_s"],
  ["neutron_wall_load",   "fusion_rad_neutron_wall_loading_MW_m2"],
  ["gamma_cr",            "fusion_rad_gamma_control_room_mSv_hr"],
  ["gamma_hall",          "fusion_rad_gamma_hall_mSv_hr"],
  ["gross_thermal",       "fusion_power_gross_thermal_MW"],
  ["recirculating",       "fusion_power_recirculating_MW"],
  ["plant_efficiency",    "fusion_power_plant_efficiency_percent"],
  ["nbi_power",           "fusion_heat_nbi_power_MW"],
  ["nbi_eff",             "fusion_heat_nbi_efficiency_percent"],
  ["ecrh_power",          "fusion_heat_ecrh_power_MW"],
  ["ecrh_eff",            "fusion_heat_ecrh_efficiency_percent"],
  ["vessel_pressure",     "fusion_vacuum_vessel_pressure_Pa"],
  ["radiated_power",      "fusion_diag_total_radiated_power_MW"],
  ["fusion_rate",         "fusion_diag_measured_fusion_rate_per_s"],
  ["availability_30d",    "fusion_perf_availability_30d_percent"],
  ["mtbd",                "fusion_perf_MTBD_hours"],
  ["active_alarms",       "fusion_alarms_active_total"],
  ["warnings_24h",        "fusion_alarms_warnings_24h"],
];

function usePrometheusMetrics(intervalMs = 5000) {
  const [metrics, setMetrics]     = useState(null);
  const [error, setError]         = useState(null);
  const [lastFetch, setLastFetch] = useState(null);
  const [fetchCount, setFetchCount] = useState(0);

  const fetch_ = useCallback(async () => {
    try {
      const data = await promQueryAll(METRIC_MAP);
      if (Object.keys(data).length === 0) throw new Error("No metrics returned — is Prometheus reachable?");
      setMetrics(data);
      setLastFetch(new Date());
      setFetchCount(c => c + 1);
      setError(null);
    } catch (e) {
      setError(e.message);
    }
  }, []);

  useEffect(() => {
    fetch_();
    const id = setInterval(fetch_, intervalMs);
    return () => clearInterval(id);
  }, [fetch_, intervalMs]);

  return { metrics, error, lastFetch, fetchCount };
}

// ── History hook ──────────────────────────────────────────────────────────────
function useHistory(value, maxLen = 60) {
  const [hist, setHist] = useState([]);
  useEffect(() => {
    if (value != null) setHist(h => [...h.slice(-(maxLen - 1)), value]);
  }, [value]);
  return hist;
}

// ── Analog Gauge (Canvas) ─────────────────────────────────────────────────────
function AnalogGauge({ value, min, max, label, unit = "", zones, size = 160 }) {
  const canvasRef = useRef();
  const pct   = Math.max(0, Math.min(1, (value - min) / (max - min)));
  const angle = -225 + pct * 270;

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    const cx = size / 2, cy = size / 2, r = size * 0.42;
    ctx.clearRect(0, 0, size, size);

    // Outer glow ring
    ctx.beginPath();
    ctx.arc(cx, cy, r + 8, 0, Math.PI * 2);
    const bgGrad = ctx.createRadialGradient(cx, cy, r * 0.2, cx, cy, r + 8);
    bgGrad.addColorStop(0, "#131d2e");
    bgGrad.addColorStop(1, "#080e1a");
    ctx.fillStyle = bgGrad;
    ctx.fill();
    ctx.strokeStyle = "#1e3a5f";
    ctx.lineWidth = 1.5;
    ctx.stroke();

    // Zone arcs
    const toRad = d => (d * Math.PI) / 180;
    if (zones) {
      zones.forEach(({ from, to, color }) => {
        const a1 = toRad(-225 + ((from - min) / (max - min)) * 270);
        const a2 = toRad(-225 + ((to   - min) / (max - min)) * 270);
        ctx.beginPath();
        ctx.arc(cx, cy, r - 2, a1, a2);
        ctx.strokeStyle = color + "99";
        ctx.lineWidth = 10;
        ctx.stroke();
      });
    }

    // Major / minor ticks
    for (let i = 0; i <= 20; i++) {
      const a     = toRad(-225 + (i / 20) * 270);
      const major = i % 4 === 0;
      const inner = major ? r - 20 : r - 11;
      ctx.beginPath();
      ctx.moveTo(cx + Math.cos(a) * inner, cy + Math.sin(a) * inner);
      ctx.lineTo(cx + Math.cos(a) * (r - 3), cy + Math.sin(a) * (r - 3));
      ctx.strokeStyle = major ? "#7eeedd88" : "#2a5a7a55";
      ctx.lineWidth   = major ? 2 : 1;
      ctx.stroke();
    }

    // Needle shadow
    const na = toRad(angle);
    const nl = r - 16;
    ctx.save();
    ctx.translate(cx + 2, cy + 2);
    ctx.rotate(na);
    ctx.beginPath();
    ctx.moveTo(-2, 12); ctx.lineTo(2, 12);
    ctx.lineTo(0.8, -nl); ctx.lineTo(-0.8, -nl);
    ctx.closePath();
    ctx.fillStyle = "rgba(0,0,0,0.4)";
    ctx.fill();
    ctx.restore();

    // Needle
    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate(na);
    const ng = ctx.createLinearGradient(0, -nl, 0, 14);
    ng.addColorStop(0, "#ff3322");
    ng.addColorStop(0.6, "#ff7755");
    ng.addColorStop(1,   "#441111");
    ctx.beginPath();
    ctx.moveTo(-2.5, 13); ctx.lineTo(2.5, 13);
    ctx.lineTo(1, -nl); ctx.lineTo(-1, -nl);
    ctx.closePath();
    ctx.fillStyle = ng;
    ctx.fill();
    ctx.restore();

    // Center cap
    const cap = ctx.createRadialGradient(cx - 2, cy - 2, 0, cx, cy, 9);
    cap.addColorStop(0, "#c0d8ff");
    cap.addColorStop(1, "#1a3060");
    ctx.beginPath();
    ctx.arc(cx, cy, 9, 0, Math.PI * 2);
    ctx.fillStyle = cap;
    ctx.fill();
    ctx.strokeStyle = "#0a1830";
    ctx.lineWidth = 1;
    ctx.stroke();

    // Value readout
    const display = value == null ? "--"
      : Math.abs(value) >= 1e13 ? value.toExponential(2)
      : value.toFixed(value < 10 ? 2 : 0);
    ctx.font = `bold ${size * 0.105}px 'Share Tech Mono', monospace`;
    ctx.fillStyle = "#7eeedd";
    ctx.textAlign = "center";
    ctx.fillText(display + (unit ? ` ${unit}` : ""), cx, cy + r * 0.56);
  }, [value, size, min, max]);

  return (
    <div style={{ textAlign: "center" }}>
      <canvas ref={canvasRef} width={size} height={size} />
      <div style={{ marginTop: -8, fontSize: 10, color: "#4a7a9a",
        fontFamily: "'Share Tech Mono', monospace", letterSpacing: 1.5, textTransform: "uppercase" }}>
        {label}
      </div>
    </div>
  );
}

// ── Horizontal Bar Gauge ──────────────────────────────────────────────────────
function BarGauge({ value, min, max, label, unit = "", zones, width = 240 }) {
  const pct = Math.max(0, Math.min(1, (value - min) / (max - min))) * 100;
  let color = "#22cc88";
  if (zones) {
    for (const z of [...zones].reverse()) {
      if (value >= z.from) { color = z.color; break; }
    }
  }
  const display = value == null ? "--"
    : Math.abs(value) >= 1e13 ? value.toExponential(2)
    : value.toFixed(value < 10 ? 3 : 1);
  return (
    <div style={{ width, fontFamily: "'Share Tech Mono', monospace" }}>
      <div style={{ fontSize: 10, color: "#4a7a9a", marginBottom: 3, letterSpacing: 1.5 }}>{label}</div>
      <div style={{ background: "#060e1e", border: "1px solid #152540", borderRadius: 3, height: 16, overflow: "hidden", position: "relative" }}>
        <div style={{
          width: `${pct}%`, height: "100%",
          background: `linear-gradient(90deg, ${color}44, ${color}dd)`,
          transition: "width 0.6s ease",
          boxShadow: `0 0 10px ${color}66`,
        }} />
      </div>
      <div style={{ display: "flex", justifyContent: "space-between", fontSize: 9, color: "#2a5070", marginTop: 2 }}>
        <span>{min}</span>
        <span style={{ color, fontWeight: "bold", fontSize: 11 }}>{display}{unit && ` ${unit}`}</span>
        <span>{max}</span>
      </div>
    </div>
  );
}

// ── Stat Card ─────────────────────────────────────────────────────────────────
function StatCard({ label, value, unit = "", color = "#7eeedd", sub, wide }) {
  const display = value == null ? "--"
    : Math.abs(value) >= 1e18 ? value.toExponential(3)
    : Math.abs(value) >= 1e13 ? (value / 1e14).toFixed(2) + "×10¹⁴"
    : value.toFixed(value < 10 ? 3 : 1);
  return (
    <div style={{
      background: "linear-gradient(135deg, #080f20 0%, #0c1a30 100%)",
      border: `1px solid ${color}28`, borderRadius: 8,
      padding: "10px 16px", minWidth: wide ? 200 : 140,
      boxShadow: `0 0 16px ${color}0a, inset 0 1px 0 ${color}18`,
      fontFamily: "'Share Tech Mono', monospace",
    }}>
      <div style={{ fontSize: 9, color: "#3a6a8a", letterSpacing: 2, marginBottom: 4, textTransform: "uppercase" }}>{label}</div>
      <div style={{ fontSize: 24, fontWeight: 900, color, fontFamily: "'Orbitron', monospace", lineHeight: 1 }}>
        {display}
        <span style={{ fontSize: 11, marginLeft: 4, color: color + "88", fontFamily: "'Share Tech Mono', monospace" }}>{unit}</span>
      </div>
      {sub && <div style={{ fontSize: 9, color: "#2a5070", marginTop: 5 }}>{sub}</div>}
    </div>
  );
}

// ── Sparkline ─────────────────────────────────────────────────────────────────
function Sparkline({ history, color = "#7eeedd", height = 50, width = 220, label }) {
  const canvasRef = useRef();
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || history.length < 2) return;
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, width, height);
    const mn = Math.min(...history), mx = Math.max(...history);
    const range = mx - mn || 1;
    const pts = history.map((v, i) => [
      (i / (history.length - 1)) * width,
      height - 4 - ((v - mn) / range) * (height - 10),
    ]);
    const grad = ctx.createLinearGradient(0, 0, 0, height);
    grad.addColorStop(0, color + "44"); grad.addColorStop(1, color + "04");
    ctx.beginPath();
    pts.forEach(([x, y], i) => i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y));
    ctx.lineTo(width, height); ctx.lineTo(0, height); ctx.closePath();
    ctx.fillStyle = grad; ctx.fill();
    ctx.beginPath();
    pts.forEach(([x, y], i) => i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y));
    ctx.strokeStyle = color; ctx.lineWidth = 1.5; ctx.stroke();
    // Latest value dot
    const [lx, ly] = pts[pts.length - 1];
    ctx.beginPath(); ctx.arc(lx, ly, 3, 0, Math.PI * 2);
    ctx.fillStyle = color; ctx.fill();
  }, [history, color, width, height]);

  return (
    <div>
      {label && <div style={{ fontFamily: "'Share Tech Mono', monospace", fontSize: 9, color: "#3a6a80", letterSpacing: 2, marginBottom: 3, textTransform: "uppercase" }}>{label}</div>}
      <canvas ref={canvasRef} width={width} height={height} style={{ display: "block" }} />
    </div>
  );
}

// ── Section Header ─────────────────────────────────────────────────────────────
function SectionHeader({ icon, title }) {
  return (
    <div style={{
      fontFamily: "'Orbitron', monospace", fontSize: 11, letterSpacing: 3,
      color: "#2a6a9a", textTransform: "uppercase", paddingBottom: 8,
      borderBottom: "1px solid #0e2540", marginBottom: 16,
      display: "flex", alignItems: "center", gap: 8
    }}>
      <span style={{ fontSize: 15 }}>{icon}</span>{title}
    </div>
  );
}

// ── Connection Banner ──────────────────────────────────────────────────────────
function ConnectionBanner({ error, fetchCount, lastFetch }) {
  if (error) return (
    <div style={{
      background: "#2a0a0a", border: "1px solid #ff4444", borderRadius: 6,
      padding: "8px 16px", marginBottom: 16, fontFamily: "'Share Tech Mono', monospace",
      fontSize: 11, color: "#ff6666", display: "flex", alignItems: "center", gap: 10,
    }}>
      <span style={{ fontSize: 16 }}>⚠️</span>
      <div>
        <strong>PROMETHEUS CONNECTION ERROR</strong> — {error}
        <div style={{ color: "#884444", marginTop: 2 }}>
          Ensure prometheus is running on port 9090 and nginx proxy is active.
        </div>
      </div>
    </div>
  );
  if (fetchCount === 0) return (
    <div style={{
      background: "#0a1a2a", border: "1px solid #2a5a8a", borderRadius: 6,
      padding: "8px 16px", marginBottom: 16, fontFamily: "'Share Tech Mono', monospace",
      fontSize: 11, color: "#4a8aaa",
    }}>
      ⏳ CONNECTING TO PROMETHEUS…
    </div>
  );
  return null;
}

// ── Main Dashboard ─────────────────────────────────────────────────────────────
export default function FusionDashboard() {
  const { metrics: m, error, lastFetch, fetchCount } = usePrometheusMetrics(5000);

  // Sparkline histories
  const histTemp  = useHistory(m?.plasma_temp_kev);
  const histQ     = useHistory(m?.q_factor);
  const histFP    = useHistory(m?.fusion_power);
  const histDrisk = useHistory(m?.disruption_risk);
  const histElec  = useHistory(m?.net_electrical);
  const histNFlux = useHistory(m?.neutron_flux);

  const [now, setNow] = useState(new Date());
  useEffect(() => { const id = setInterval(() => setNow(new Date()), 1000); return () => clearInterval(id); }, []);

  const alarmColor  = !m || m.active_alarms > 0 ? "#ff4444" : "#22cc88";
  const plasmaColor = error ? "#ff4444" : fetchCount === 0 ? "#ffaa00" : "#00ff99";
  const plasmaLabel = error ? "OFFLINE" : fetchCount === 0 ? "CONNECTING" : "PLASMA SUSTAINED";

  const css = `
    @keyframes pulse { 0%,100%{opacity:1;box-shadow:0 0 6px currentColor} 50%{opacity:0.5;box-shadow:0 0 18px currentColor} }
    @keyframes scanline { from{transform:translateY(-4px)} to{transform:translateY(100vh)} }
    .pulse { animation: pulse 2s infinite; }
    ::-webkit-scrollbar { width: 5px; background: #040a14; }
    ::-webkit-scrollbar-thumb { background: #0e2540; border-radius: 3px; }
  `;

  return (
    <div style={{ background: "#050c1a", minHeight: "100vh", color: "#b0cce0", overflowX: "hidden", position: "relative" }}>
      <style>{css}</style>

      {/* CRT scanline overlay */}
      <div style={{
        position: "fixed", inset: 0, pointerEvents: "none", zIndex: 999,
        background: "repeating-linear-gradient(0deg,transparent,transparent 2px,rgba(0,10,30,0.07) 2px,rgba(0,10,30,0.07) 4px)"
      }} />

      {/* ── Header ─────────────────────────────────────────────────────────── */}
      <header style={{
        background: "linear-gradient(90deg,#030810 0%,#07152a 50%,#030810 100%)",
        borderBottom: "1px solid #0e2a4a",
        padding: "10px 24px",
        display: "flex", justifyContent: "space-between", alignItems: "center",
        boxShadow: "0 2px 30px #001833bb",
        position: "sticky", top: 0, zIndex: 100,
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: 20 }}>
          <span style={{ fontFamily: "'Orbitron',monospace", fontSize: 19, fontWeight: 900, color: "#7eeedd", letterSpacing: 5 }}>
            ⚛ FUSION MONITOR
          </span>
          <span style={{ fontFamily: "'Share Tech Mono',monospace", fontSize: 11, color: "#2a5a7a" }}>
            POLARIS · HELION ENERGY SYSTEMS
          </span>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 22 }}>
          {/* Data source badge */}
          <div style={{ fontFamily: "'Share Tech Mono',monospace", fontSize: 10, color: "#2a6a5a",
            background: "#021a10", border: "1px solid #0a3a20", borderRadius: 4, padding: "3px 10px" }}>
            DATA: PROMETHEUS :9090 · {fetchCount > 0 ? `POLL #${fetchCount}` : "PENDING"}
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
            <div className="pulse" style={{ width: 8, height: 8, borderRadius: "50%", background: plasmaColor, color: plasmaColor }} />
            <span style={{ fontFamily: "'Share Tech Mono',monospace", fontSize: 10, color: plasmaColor, letterSpacing: 2 }}>
              {plasmaLabel}
            </span>
          </div>
          <span style={{ fontFamily: "'Share Tech Mono',monospace", fontSize: 10, color: "#2a5070" }}>
            {now.toISOString().replace("T"," ").slice(0,19)} UTC
          </span>
          <div style={{
            background: alarmColor + "18", border: `1px solid ${alarmColor}44`, borderRadius: 4,
            padding: "3px 10px", fontFamily: "'Share Tech Mono',monospace", fontSize: 10, color: alarmColor,
          }}>
            ALARMS: {m?.active_alarms ?? "--"}
          </div>
        </div>
      </header>

      <div style={{ padding: "18px 22px", display: "flex", flexDirection: "column", gap: 22 }}>

        <ConnectionBanner error={error} fetchCount={fetchCount} lastFetch={lastFetch} />

        {/* ── PLASMA CORE ─────────────────────────────────────────────────── */}
        <section>
          <SectionHeader icon="🔥" title="Plasma Core" />
          <div style={{ display: "flex", gap: 14, flexWrap: "wrap", alignItems: "flex-end" }}>
            <AnalogGauge value={m?.plasma_temp_kev} min={0} max={25} label="Electron Temp" unit="keV" size={165}
              zones={[{from:0,to:10,color:"#4488ff"},{from:10,to:18,color:"#22cc88"},{from:18,to:22,color:"#ffaa00"},{from:22,to:25,color:"#ff4444"}]} />
            <AnalogGauge value={m?.ion_temp_kev} min={0} max={25} label="Ion Temp" unit="keV" size={165}
              zones={[{from:0,to:10,color:"#4488ff"},{from:10,to:18,color:"#22cc88"},{from:18,to:22,color:"#ffaa00"},{from:22,to:25,color:"#ff4444"}]} />
            <AnalogGauge value={m?.q_factor} min={0} max={15} label="Gain Factor Q" size={165}
              zones={[{from:0,to:1,color:"#ff4444"},{from:1,to:5,color:"#ffaa00"},{from:5,to:10,color:"#22cc88"},{from:10,to:15,color:"#00ffcc"}]} />
            <AnalogGauge value={m?.fusion_power} min={0} max={600} label="Fusion Power" unit="MW" size={165}
              zones={[{from:0,to:200,color:"#4488ff"},{from:200,to:400,color:"#22cc88"},{from:400,to:500,color:"#ffaa00"},{from:500,to:600,color:"#ff4444"}]} />
            <AnalogGauge value={m?.disruption_risk} min={0} max={100} label="Disruption Risk" unit="%" size={165}
              zones={[{from:0,to:15,color:"#22cc88"},{from:15,to:40,color:"#ffaa00"},{from:40,to:70,color:"#ff8800"},{from:70,to:100,color:"#ff4444"}]} />
            <AnalogGauge value={m?.plasma_beta} min={0} max={0.15} label="Plasma Beta β" size={165}
              zones={[{from:0,to:0.02,color:"#4488ff"},{from:0.02,to:0.08,color:"#22cc88"},{from:0.08,to:0.12,color:"#ffaa00"},{from:0.12,to:0.15,color:"#ff4444"}]} />
          </div>
          {/* Sparklines */}
          <div style={{ display: "flex", gap: 24, marginTop: 14, flexWrap: "wrap" }}>
            <Sparkline history={histTemp}  color="#7eeedd" width={230} height={46} label="Electron Temp (keV)" />
            <Sparkline history={histQ}     color="#00ffcc" width={230} height={46} label="Q Factor" />
            <Sparkline history={histFP}    color="#ffaa44" width={230} height={46} label="Fusion Power (MW)" />
            <Sparkline history={histDrisk} color="#ff6644" width={230} height={46} label="Disruption Risk %" />
          </div>
        </section>

        {/* ── MAGNETIC + THERMAL ────────────────────────────────────────────── */}
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 22 }}>

          <section>
            <SectionHeader icon="🧲" title="Magnetic Systems" />
            <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>
              <AnalogGauge value={m?.toroidal_field} min={0} max={8} label="Toroidal Field" unit="T" size={140}
                zones={[{from:0,to:4,color:"#4488ff"},{from:4,to:6.5,color:"#22cc88"},{from:6.5,to:7.5,color:"#ffaa00"},{from:7.5,to:8,color:"#ff4444"}]} />
              <AnalogGauge value={m?.plasma_current} min={0} max={20} label="Plasma Current" unit="MA" size={140}
                zones={[{from:0,to:8,color:"#4488ff"},{from:8,to:17,color:"#22cc88"},{from:17,to:19,color:"#ffaa00"},{from:19,to:20,color:"#ff4444"}]} />
              <AnalogGauge value={m?.elm_freq} min={0} max={50} label="ELM Freq" unit="Hz" size={140}
                zones={[{from:0,to:30,color:"#22cc88"},{from:30,to:45,color:"#ffaa00"},{from:45,to:50,color:"#ff4444"}]} />
            </div>
          </section>

          <section>
            <SectionHeader icon="🌡️" title="Thermal Systems" />
            <div style={{ display: "flex", flexDirection: "column", gap: 9, paddingTop: 2 }}>
              <BarGauge value={m?.temp_inner_div} min={0} max={2000} label="Inner Divertor" unit="°C" width={290}
                zones={[{from:0,color:"#4488ff"},{from:400,color:"#22cc88"},{from:1000,color:"#ffaa00"},{from:1500,color:"#ff4444"}]} />
              <BarGauge value={m?.temp_outer_div} min={0} max={2000} label="Outer Divertor" unit="°C" width={290}
                zones={[{from:0,color:"#4488ff"},{from:400,color:"#22cc88"},{from:1100,color:"#ff8800"},{from:1600,color:"#ff4444"}]} />
              <BarGauge value={m?.temp_wall}     min={0} max={800}  label="First Wall"     unit="°C" width={290}
                zones={[{from:0,color:"#4488ff"},{from:150,color:"#22cc88"},{from:450,color:"#ffaa00"},{from:650,color:"#ff4444"}]} />
              <BarGauge value={m?.coolant_outlet} min={0} max={250} label="Coolant Outlet"  unit="°C" width={290}
                zones={[{from:0,color:"#4488ff"},{from:80,color:"#22cc88"},{from:175,color:"#ffaa00"},{from:220,color:"#ff4444"}]} />
              <BarGauge value={m?.cryo_he}        min={0} max={20}  label="Cryo Helium"     unit="K"  width={290}
                zones={[{from:0,color:"#8888ff"},{from:4,color:"#22cc88"},{from:7,color:"#ffaa00"},{from:12,color:"#ff4444"}]} />
            </div>
          </section>
        </div>

        {/* ── POWER + TRITIUM/RAD ───────────────────────────────────────────── */}
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 22 }}>

          <section>
            <SectionHeader icon="⚡" title="Power Systems" />
            <div style={{ display: "flex", gap: 12, flexWrap: "wrap", marginBottom: 14 }}>
              <AnalogGauge value={m?.gross_thermal}   min={0} max={600} label="Gross Thermal"   unit="MW" size={140}
                zones={[{from:0,to:200,color:"#4488ff"},{from:200,to:450,color:"#22cc88"},{from:450,to:550,color:"#ffaa00"},{from:550,to:600,color:"#ff4444"}]} />
              <AnalogGauge value={m?.net_electrical}  min={0} max={300} label="Net Electrical"  unit="MW" size={140}
                zones={[{from:0,to:100,color:"#ff4444"},{from:100,to:150,color:"#ffaa00"},{from:150,to:300,color:"#22cc88"}]} />
              <AnalogGauge value={m?.plant_efficiency} min={0} max={60} label="Efficiency"      unit="%"  size={140}
                zones={[{from:0,to:25,color:"#ff4444"},{from:25,to:32,color:"#ffaa00"},{from:32,to:60,color:"#22cc88"}]} />
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 9 }}>
              <BarGauge value={m?.nbi_eff}  min={0} max={100} label="NBI Efficiency"  unit="%" width={290}
                zones={[{from:0,color:"#ff4444"},{from:70,color:"#ffaa00"},{from:85,color:"#22cc88"}]} />
              <BarGauge value={m?.ecrh_eff} min={0} max={100} label="ECRH Efficiency" unit="%" width={290}
                zones={[{from:0,color:"#ff4444"},{from:70,color:"#ffaa00"},{from:85,color:"#22cc88"}]} />
            </div>
            <Sparkline history={histElec} color="#aaddff" width={290} height={40} label="Net Electrical MW" />
          </section>

          <section>
            <SectionHeader icon="☢️" title="Tritium & Radiation" />
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10, marginBottom: 14 }}>
              <StatCard label="T Inventory" value={m?.tritium_inventory} unit="g"  color="#aaddff" sub="Target: >350g" />
              <StatCard label="T Breeding Ratio" value={m?.tritium_tbr}  color={m?.tritium_tbr >= 1.05 ? "#22cc88" : "#ffaa00"} sub="Must be >1.05" />
              <StatCard label="T Burn Rate" value={m?.tritium_burn_rate} unit="mg/s" color="#88ccff" />
              <StatCard label="T Airborne"  value={m?.tritium_airborne}  unit="Bq/m³" color={m?.tritium_airborne > 40 ? "#ffaa00" : "#22cc88"} />
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 9 }}>
              <BarGauge value={m?.neutron_wall_load} min={0} max={2}   label="Neutron Wall Load" unit="MW/m²" width={290}
                zones={[{from:0,color:"#22cc88"},{from:1,color:"#ffaa00"},{from:1.8,color:"#ff4444"}]} />
              <BarGauge value={m?.gamma_cr}          min={0} max={0.02} label="Gamma — Ctrl Room" unit="mSv/hr" width={290}
                zones={[{from:0,color:"#22cc88"},{from:0.005,color:"#ffaa00"},{from:0.01,color:"#ff4444"}]} />
              <BarGauge value={m?.gamma_hall}        min={0} max={0.2}  label="Gamma — Hall"      unit="mSv/hr" width={290}
                zones={[{from:0,color:"#22cc88"},{from:0.08,color:"#ffaa00"},{from:0.15,color:"#ff4444"}]} />
            </div>
            <Sparkline history={histNFlux} color="#ffdd88" width={290} height={40} label="Neutron Flux (/cm²s)" />
          </section>
        </div>

        {/* ── KPI STRIP ────────────────────────────────────────────────────── */}
        <section>
          <SectionHeader icon="📊" title="Performance KPIs" />
          <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>
            <StatCard label="30-Day Availability" value={m?.availability_30d} unit="%"  color="#7eeedd"  sub="Target: >90%"   wide />
            <StatCard label="MTBD"                value={m?.mtbd}             unit="hr" color="#aaddff"  sub="Mean time between disruptions" wide />
            <StatCard label="Fusion Rate"         value={m?.fusion_rate}                color="#ffdd88"  sub="/s"             wide />
            <StatCard label="Radiated Power"      value={m?.radiated_power}   unit="MW" color="#cc88ff"  sub="Bolometry"      />
            <StatCard label="Active Alarms"       value={m?.active_alarms}              color={m?.active_alarms > 0 ? "#ff4444" : "#22cc88"} />
            <StatCard label="Warnings 24h"        value={m?.warnings_24h}               color={m?.warnings_24h  > 3 ? "#ffaa00" : "#7eeedd"} />
            <StatCard label="Vessel Pressure"     value={m?.vessel_pressure}  unit="Pa" color="#88aacc"  sub="Target: <1e-5"  />
            <StatCard label="Recirculating"       value={m?.recirculating}    unit="MW" color="#cc88ff"  />
          </div>
        </section>

      </div>

      {/* ── Footer ─────────────────────────────────────────────────────────── */}
      <footer style={{
        borderTop: "1px solid #0a2035", padding: "8px 22px", marginTop: 8,
        fontFamily: "'Share Tech Mono',monospace", fontSize: 9, color: "#1a4060",
        display: "flex", justifyContent: "space-between",
      }}>
        <span>DATA SOURCE: PROMETHEUS API · SCRAPE: 5s · RETENTION: 30d · SESSION: SESSION-20260306-A</span>
        <span>LAST FETCH: {lastFetch ? lastFetch.toISOString().replace("T"," ").slice(0,19) + " UTC" : "—"}</span>
      </footer>
    </div>
  );
}