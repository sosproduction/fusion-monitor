#!/usr/bin/env python3
"""
fusion_producer.py
==================
Replaces fusion_exporter.py.

Instead of exposing a Prometheus /metrics endpoint directly, this script:
  1. Simulates all 50+ fusion reactor sensor values (same physics as before)
  2. Publishes every value to the Kafka topic  metrics.fusion-reactor
  3. Each Kafka message is a JSON envelope tagged with origin metadata

Downstream consumers decide what to do with the data:
  • kafka-prometheus-bridge  → pushes to Pushgateway → Prometheus scrapes it
  • kafka-timescale-writer   → inserts rows into TimescaleDB hypertable

Environment variables (set in docker-compose):
  KAFKA_BOOTSTRAP   broker list, e.g.  kafka:9092
  KAFKA_TOPIC       default: metrics.fusion-reactor
  PUBLISH_INTERVAL  seconds between batches, default: 5
"""

import os
import json
import math
import random
import time
import logging
from datetime import datetime, timezone

from confluent_kafka import Producer
from confluent_kafka.admin import AdminClient, NewTopic

# ── Config ────────────────────────────────────────────────────────────────────
KAFKA_BOOTSTRAP  = os.getenv("KAFKA_BOOTSTRAP",  "kafka:9092")
KAFKA_TOPIC      = os.getenv("KAFKA_TOPIC",      "metrics.fusion-reactor")
PUBLISH_INTERVAL = float(os.getenv("PUBLISH_INTERVAL", "5"))

ORIGIN_TAG = "fusion-reactor"
REACTOR_META = {
    "reactor_id":  "FRP-001",
    "facility":    "National Fusion Research Center",
    "reactor_type": "Tokamak",
    "location":    "Building-4, Bay-2",
}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("fusion-producer")

# ── Kafka helpers ─────────────────────────────────────────────────────────────

def make_producer() -> Producer:
    return Producer({
        "bootstrap.servers":        KAFKA_BOOTSTRAP,
        "client.id":                "fusion-reactor-producer",
        "acks":                     "all",
        "retries":                  5,
        "retry.backoff.ms":         500,
        "linger.ms":                50,          # micro-batch for throughput
        "compression.type":         "lz4",
        "message.max.bytes":        1_048_576,
    })


def ensure_topic(bootstrap: str, topic: str, partitions: int = 3, replication: int = 1):
    """Create topic if it doesn't exist yet."""
    admin = AdminClient({"bootstrap.servers": bootstrap})
    meta  = admin.list_topics(timeout=10)
    if topic not in meta.topics:
        fs = admin.create_topics([NewTopic(topic, num_partitions=partitions,
                                           replication_factor=replication)])
        for t, f in fs.items():
            try:
                f.result()
                log.info("Created Kafka topic: %s", t)
            except Exception as e:
                log.warning("Topic creation: %s", e)


def delivery_report(err, msg):
    if err:
        log.error("Delivery failed: %s", err)


def publish(producer: Producer, topic: str, metric_name: str,
            value: float, unit: str, subsystem: str,
            extra_tags: dict | None = None):
    """Build the standard envelope and send to Kafka."""
    envelope = {
        "origin":      ORIGIN_TAG,
        "subsystem":   subsystem,
        "metric":      metric_name,
        "value":       value,
        "unit":        unit,
        "timestamp":   datetime.now(timezone.utc).isoformat(),
        "tags": {
            **REACTOR_META,
            **(extra_tags or {}),
        },
    }
    producer.produce(
        topic,
        key=metric_name.encode(),
        value=json.dumps(envelope).encode(),
        callback=delivery_report,
    )

# ── Physics simulation (identical to fusion_exporter.py) ──────────────────────

def jitter(base: float, pct: float = 0.02) -> float:
    return base * (1 + random.uniform(-pct, pct))

def wave(base: float, amplitude: float, period_s: float, t: float) -> float:
    return base + amplitude * math.sin(2 * math.pi * t / period_s)


def generate_metrics(t: float) -> list[dict]:
    """
    Returns a flat list of dicts:
        { name, value, unit, subsystem, extra_tags? }
    Mirrors every metric from the original fusion_exporter.py.
    """
    temp = wave(15.4, 0.6, 300, t)
    fp   = wave(420.5, 15, 300, t)
    hp   = jitter(50.0, 0.01)
    q    = round(fp / hp, 3)

    metrics = [
        # ── Plasma ──────────────────────────────────────────────────────────
        {"name": "fusion_plasma_temperature_keV",    "value": round(jitter(temp, 0.01), 3), "unit": "keV",      "subsystem": "plasma"},
        {"name": "fusion_plasma_temperature_kelvin", "value": round(temp * 11_604_525.0, 0),"unit": "K",        "subsystem": "plasma"},
        {"name": "fusion_plasma_density_per_m3",     "value": jitter(1.2e20, 0.03),         "unit": "m^-3",     "subsystem": "plasma"},
        {"name": "fusion_plasma_pressure_pascals",   "value": jitter(3.1e5,  0.02),         "unit": "Pa",       "subsystem": "plasma"},
        {"name": "fusion_plasma_confinement_time_s", "value": jitter(1.2,    0.02),         "unit": "s",        "subsystem": "plasma"},
        {"name": "fusion_plasma_beta_value",         "value": jitter(0.047,  0.03),         "unit": "",         "subsystem": "plasma"},
        {"name": "fusion_plasma_q_factor",           "value": round(jitter(q, 0.01), 3),   "unit": "",         "subsystem": "plasma"},
        {"name": "fusion_plasma_fusion_power_MW",    "value": round(jitter(fp, 0.01), 2),  "unit": "MW",       "subsystem": "plasma"},
        {"name": "fusion_plasma_heating_power_MW",   "value": round(hp, 2),                "unit": "MW",       "subsystem": "plasma"},
        {"name": "fusion_plasma_gain_Q",             "value": q,                            "unit": "",         "subsystem": "plasma"},
        {"name": "fusion_fuel_deuterium_percent",    "value": jitter(50.0, 0.005),          "unit": "%",        "subsystem": "plasma"},
        {"name": "fusion_fuel_tritium_percent",      "value": jitter(50.0, 0.005),          "unit": "%",        "subsystem": "plasma"},
        {"name": "fusion_impurity_carbon_ppm",       "value": jitter(0.4,  0.05),           "unit": "ppm",      "subsystem": "plasma"},
        {"name": "fusion_impurity_oxygen_ppm",       "value": jitter(0.2,  0.05),           "unit": "ppm",      "subsystem": "plasma"},
        {"name": "fusion_impurity_tungsten_ppm",     "value": jitter(0.01, 0.05),           "unit": "ppm",      "subsystem": "plasma"},
        {"name": "fusion_impurity_helium_ash_percent","value": jitter(2.1, 0.04),           "unit": "%",        "subsystem": "plasma"},

        # ── Magnetic ─────────────────────────────────────────────────────────
        {"name": "fusion_mag_toroidal_field_tesla",  "value": jitter(5.3,  0.005),          "unit": "T",        "subsystem": "magnetic"},
        {"name": "fusion_mag_poloidal_field_tesla",  "value": jitter(0.8,  0.01),           "unit": "T",        "subsystem": "magnetic"},
        {"name": "fusion_mag_plasma_current_MA",     "value": jitter(15.0, 0.005),          "unit": "MA",       "subsystem": "magnetic"},
        {"name": "fusion_mag_disruption_risk_percent","value": max(0, wave(3.2, 2.0, 600, t) + random.gauss(0, 0.3)), "unit": "%", "subsystem": "magnetic"},
        {"name": "fusion_mag_ELM_frequency_Hz",      "value": max(0, jitter(12.5, 0.1)),    "unit": "Hz",       "subsystem": "magnetic"},

        # ── Heating ──────────────────────────────────────────────────────────
        {"name": "fusion_heat_nbi_power_MW",         "value": jitter(20.0, 0.02),           "unit": "MW",       "subsystem": "heating"},
        {"name": "fusion_heat_nbi_efficiency_percent","value": jitter(82.3, 0.01),          "unit": "%",        "subsystem": "heating"},
        {"name": "fusion_heat_ecrh_power_MW",        "value": jitter(20.0, 0.02),           "unit": "MW",       "subsystem": "heating"},
        {"name": "fusion_heat_ecrh_efficiency_percent","value": jitter(90.1, 0.005),        "unit": "%",        "subsystem": "heating"},

        # ── Vacuum ───────────────────────────────────────────────────────────
        {"name": "fusion_vacuum_vessel_pressure_Pa", "value": jitter(1.5e-6, 0.05),         "unit": "Pa",       "subsystem": "vacuum"},
        {"name": "fusion_vacuum_leak_rate_Pa_m3_per_s","value": jitter(2.1e-9, 0.05),      "unit": "Pa·m³/s",  "subsystem": "vacuum"},

        # ── Divertor / First Wall ─────────────────────────────────────────────
        {"name": "fusion_divertor_heatflux_inner_MW_m2","value": jitter(8.4,  0.03),       "unit": "MW/m²",    "subsystem": "divertor"},
        {"name": "fusion_divertor_heatflux_outer_MW_m2","value": jitter(11.2, 0.03),       "unit": "MW/m²",    "subsystem": "divertor"},
        {"name": "fusion_divertor_heatflux_wall_MW_m2", "value": jitter(1.8,  0.03),       "unit": "MW/m²",    "subsystem": "divertor"},
        {"name": "fusion_divertor_temp_inner_C",     "value": jitter(842,  0.02),           "unit": "°C",       "subsystem": "divertor"},
        {"name": "fusion_divertor_temp_outer_C",     "value": jitter(1104, 0.02),           "unit": "°C",       "subsystem": "divertor"},
        {"name": "fusion_divertor_temp_wall_C",      "value": jitter(320,  0.02),           "unit": "°C",       "subsystem": "divertor"},
        {"name": "fusion_divertor_erosion_nm_per_s", "value": jitter(0.003, 0.05),          "unit": "nm/s",     "subsystem": "divertor"},

        # ── Cooling ──────────────────────────────────────────────────────────
        {"name": "fusion_cooling_inlet_temp_C",      "value": jitter(70,   0.01),           "unit": "°C",       "subsystem": "cooling"},
        {"name": "fusion_cooling_outlet_temp_C",     "value": jitter(150,  0.01),           "unit": "°C",       "subsystem": "cooling"},
        {"name": "fusion_cooling_flow_kg_per_s",     "value": jitter(1200, 0.02),           "unit": "kg/s",     "subsystem": "cooling"},
        {"name": "fusion_cooling_pressure_MPa",      "value": jitter(1.5,  0.01),           "unit": "MPa",      "subsystem": "cooling"},
        {"name": "fusion_cryo_helium_temp_K",        "value": jitter(4.5,  0.02),           "unit": "K",        "subsystem": "cooling"},

        # ── Tritium ──────────────────────────────────────────────────────────
        {"name": "fusion_tritium_inventory_grams",   "value": jitter(410.5, 0.005),         "unit": "g",        "subsystem": "tritium"},
        {"name": "fusion_tritium_burn_rate_mg_per_s","value": jitter(0.056, 0.03),          "unit": "mg/s",     "subsystem": "tritium"},
        {"name": "fusion_tritium_breeding_ratio",    "value": jitter(1.12,  0.02),          "unit": "",         "subsystem": "tritium"},
        {"name": "fusion_tritium_airborne_Bq_per_m3","value": jitter(12.5,  0.1),           "unit": "Bq/m³",    "subsystem": "tritium"},

        # ── Power ─────────────────────────────────────────────────────────────
        {"name": "fusion_power_gross_thermal_MW",    "value": round(jitter(420.5, 0.02), 2),"unit": "MW",       "subsystem": "power"},
        {"name": "fusion_power_net_electrical_MW",   "value": round(jitter(168.2, 0.02), 2),"unit": "MW",       "subsystem": "power"},
        {"name": "fusion_power_recirculating_MW",    "value": jitter(85.0,  0.02),          "unit": "MW",       "subsystem": "power"},
        {"name": "fusion_power_plant_efficiency_percent","value": jitter(33.2, 0.01),       "unit": "%",        "subsystem": "power"},

        # ── Radiation ─────────────────────────────────────────────────────────
        {"name": "fusion_rad_neutron_flux_per_cm2_s","value": jitter(3.6e14, 0.02),         "unit": "/cm²s",    "subsystem": "radiation"},
        {"name": "fusion_rad_neutron_wall_loading_MW_m2","value": jitter(0.78, 0.02),       "unit": "MW/m²",    "subsystem": "radiation"},
        {"name": "fusion_rad_gamma_control_room_mSv_hr","value": jitter(0.001, 0.05),       "unit": "mSv/hr",   "subsystem": "radiation"},
        {"name": "fusion_rad_gamma_hall_mSv_hr",     "value": jitter(0.04,  0.05),          "unit": "mSv/hr",   "subsystem": "radiation"},

        # ── Diagnostics ───────────────────────────────────────────────────────
        {"name": "fusion_diag_total_radiated_power_MW","value": jitter(38.6, 0.03),         "unit": "MW",       "subsystem": "diagnostics"},
        {"name": "fusion_diag_ion_temperature_keV",  "value": jitter(14.9,  0.02),          "unit": "keV",      "subsystem": "diagnostics"},
        {"name": "fusion_diag_measured_fusion_rate_per_s","value": jitter(1.49e20, 0.02),   "unit": "/s",       "subsystem": "diagnostics"},

        # ── Performance / Alarms ──────────────────────────────────────────────
        {"name": "fusion_perf_availability_30d_percent","value": 91.4,                      "unit": "%",        "subsystem": "performance"},
        {"name": "fusion_perf_MTBD_hours",           "value": jitter(128.4, 0.005),         "unit": "hr",       "subsystem": "performance"},
        {"name": "fusion_alarms_active_total",       "value": 0,                            "unit": "",         "subsystem": "alarms"},
        {"name": "fusion_alarms_warnings_24h",       "value": 1,                            "unit": "",         "subsystem": "alarms"},
    ]
    return metrics


# ── Main loop ──────────────────────────────────────────────────────────────────

def wait_for_kafka(bootstrap: str, retries: int = 20, delay: float = 3.0):
    """Block until Kafka is reachable."""
    import socket
    # MSK returns multiple brokers e.g. "b-1.xxx:9092,b-2.xxx:9092"
    first_broker = bootstrap.split(",")[0]
    host, port = first_broker.rsplit(":", 1)
    for i in range(retries):
        try:
            with socket.create_connection((host, int(port)), timeout=3):
                log.info("Kafka is reachable at %s", bootstrap)
                return
        except OSError:
            log.info("Waiting for Kafka… (%d/%d)", i + 1, retries)
            time.sleep(delay)
    raise RuntimeError(f"Kafka not reachable at {bootstrap} after {retries} attempts")


def main():
    log.info("=== Fusion Kafka Producer starting ===")
    log.info("Bootstrap: %s  Topic: %s  Interval: %ss",
             KAFKA_BOOTSTRAP, KAFKA_TOPIC, PUBLISH_INTERVAL)

    wait_for_kafka(KAFKA_BOOTSTRAP)
    ensure_topic(KAFKA_BOOTSTRAP, KAFKA_TOPIC, partitions=3)

    producer = make_producer()
    batch_no  = 0

    while True:
        t         = time.time()
        metrics   = generate_metrics(t)
        batch_no += 1

        for m in metrics:
            publish(
                producer,
                KAFKA_TOPIC,
                metric_name  = m["name"],
                value        = m["value"],
                unit         = m["unit"],
                subsystem    = m["subsystem"],
                extra_tags   = m.get("extra_tags"),
            )

        producer.flush()   # wait for all in-flight messages to be acked
        log.info("Batch #%d — published %d metrics to %s",
                 batch_no, len(metrics), KAFKA_TOPIC)

        time.sleep(PUBLISH_INTERVAL)


if __name__ == "__main__":
    main()