#!/usr/bin/env python3
"""
prometheus_bridge.py
====================
Kafka consumer that reads ALL metrics.* topics and pushes each metric
to the Prometheus Pushgateway using the text exposition format.

Prometheus then scrapes the Pushgateway at :9091 on its normal schedule.

This means Prometheus needs zero knowledge of Kafka — it just sees
the Pushgateway as another scrape target, exactly like before.

Message envelope expected (from any producer):
{
    "origin":    "fusion-reactor",   # used as job label in Pushgateway
    "subsystem": "plasma",           # used as grouping key
    "metric":    "fusion_plasma_temperature_keV",
    "value":     15.4,
    "unit":      "keV",
    "timestamp": "2026-03-09T05:00:00Z",
    "tags": { ... }                  # forwarded as Prometheus labels
}

Environment variables:
    KAFKA_BOOTSTRAP     e.g. kafka:9092
    KAFKA_TOPICS        comma-separated, e.g. metrics.fusion-reactor,metrics.kubernetes
    KAFKA_GROUP_ID      consumer group, default: prometheus-bridge
    PUSHGATEWAY_URL     e.g. http://pushgateway:9091
    PUSH_INTERVAL_S     how often to flush to Pushgateway, default: 5
"""

import os
import json
import time
import logging
import threading
from collections import defaultdict
from datetime import datetime, timezone

import requests
from confluent_kafka import Consumer, KafkaError

# ── Config ────────────────────────────────────────────────────────────────────
KAFKA_BOOTSTRAP   = os.getenv("KAFKA_BOOTSTRAP",  "kafka:9092")
KAFKA_TOPICS      = os.getenv("KAFKA_TOPICS",     "metrics.fusion-reactor").split(",")
KAFKA_GROUP_ID    = os.getenv("KAFKA_GROUP_ID",   "prometheus-bridge")
PUSHGATEWAY_URL   = os.getenv("PUSHGATEWAY_URL",  "http://pushgateway:9091")
PUSH_INTERVAL_S   = float(os.getenv("PUSH_INTERVAL_S", "5"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("prometheus-bridge")

# ── In-memory metric store ────────────────────────────────────────────────────
# Keyed by (origin, metric_name) → latest envelope
_store: dict[tuple, dict] = {}
_store_lock = threading.Lock()


def sanitize_label_value(v: str) -> str:
    """Prometheus label values must not contain unescaped quotes or newlines."""
    return str(v).replace('"', '\\"').replace("\n", "")


def envelope_to_prom_text(env: dict) -> str:
    """
    Convert one message envelope to Prometheus text format lines.

    Example output:
        # HELP fusion_plasma_temperature_keV Plasma temperature in keV
        # TYPE fusion_plasma_temperature_keV gauge
        fusion_plasma_temperature_keV{origin="fusion-reactor",subsystem="plasma"} 15.4
    """
    name      = env["metric"].replace("-", "_").replace(".", "_")
    value     = env["value"]
    origin    = env.get("origin", "unknown")
    subsystem = env.get("subsystem", "unknown")
    unit      = env.get("unit", "")

    # Base labels
    labels = {
        "origin":    origin,
        "subsystem": subsystem,
    }
    # Add scalar string tags as labels (skip nested objects)
    for k, v in env.get("tags", {}).items():
        if isinstance(v, (str, int, float, bool)):
            labels[k] = str(v)

    label_str = ",".join(
        f'{k}="{sanitize_label_value(v)}"'
        for k, v in sorted(labels.items())
    )

    help_str = f"{name} ({unit})" if unit else name
    lines = [
        f"# HELP {name} {help_str}",
        f"# TYPE {name} gauge",
        f"{name}{{{label_str}}} {value}",
    ]
    return "\n".join(lines)


def push_to_gateway(origin: str, metrics_text: str):
    """
    POST text-format metrics to Pushgateway grouped by origin.
    URL format: /metrics/job/<job>/instance/<instance>
    """
    url = f"{PUSHGATEWAY_URL}/metrics/job/{origin}"
    try:
        resp = requests.post(
            url,
            data=metrics_text.encode("utf-8"),
            headers={"Content-Type": "text/plain; version=0.0.4"},
            timeout=5,
        )
        if resp.status_code not in (200, 202):
            log.warning("Pushgateway returned %d for origin=%s", resp.status_code, origin)
    except requests.RequestException as e:
        log.error("Pushgateway push failed: %s", e)


def flush_loop():
    """
    Background thread: every PUSH_INTERVAL_S seconds, group the current
    in-memory store by origin and push each group to the Pushgateway.
    """
    while True:
        time.sleep(PUSH_INTERVAL_S)
        with _store_lock:
            snapshot = dict(_store)

        if not snapshot:
            continue

        # Group by origin
        by_origin: dict[str, list[str]] = defaultdict(list)
        for env in snapshot.values():
            try:
                text = envelope_to_prom_text(env)
                by_origin[env.get("origin", "unknown")].append(text)
            except Exception as e:
                log.warning("Failed to format metric: %s", e)

        for origin, lines in by_origin.items():
            push_to_gateway(origin, "\n".join(lines) + "\n")
            log.info("Pushed %d metrics for origin=%s", len(lines), origin)


def consume_loop():
    """Main Kafka consumer loop — stores latest value per metric."""
    consumer = Consumer({
        "bootstrap.servers":  KAFKA_BOOTSTRAP,
        "group.id":           KAFKA_GROUP_ID,
        "auto.offset.reset":  "latest",
        "enable.auto.commit": True,
    })
    consumer.subscribe(KAFKA_TOPICS)
    log.info("Subscribed to topics: %s", KAFKA_TOPICS)

    msg_count = 0
    try:
        while True:
            msg = consumer.poll(timeout=1.0)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    continue
                log.error("Kafka error: %s", msg.error())
                continue
            try:
                envelope = json.loads(msg.value().decode("utf-8"))
                key = (envelope.get("origin", "unknown"), envelope.get("metric", "unknown"))
                with _store_lock:
                    _store[key] = envelope
                msg_count += 1
                if msg_count % 100 == 0:
                    log.info("Consumed %d messages, store size=%d", msg_count, len(_store))
            except (json.JSONDecodeError, KeyError) as e:
                log.warning("Bad message: %s", e)
    finally:
        consumer.close()


def wait_for_kafka(bootstrap: str, retries: int = 20, delay: float = 3.0):
    import socket
    host, port = bootstrap.split(":")
    for i in range(retries):
        try:
            with socket.create_connection((host, int(port)), timeout=3):
                log.info("Kafka reachable at %s", bootstrap)
                return
        except OSError:
            log.info("Waiting for Kafka… (%d/%d)", i + 1, retries)
            time.sleep(delay)
    raise RuntimeError(f"Kafka not reachable at {bootstrap}")


def wait_for_pushgateway(url: str, retries: int = 15, delay: float = 3.0):
    for i in range(retries):
        try:
            r = requests.get(url, timeout=3)
            if r.status_code < 500:
                log.info("Pushgateway reachable at %s", url)
                return
        except requests.RequestException:
            pass
        log.info("Waiting for Pushgateway… (%d/%d)", i + 1, retries)
        time.sleep(delay)
    raise RuntimeError(f"Pushgateway not reachable at {url}")


def main():
    log.info("=== Prometheus Bridge starting ===")
    log.info("Kafka: %s  Topics: %s  Gateway: %s",
             KAFKA_BOOTSTRAP, KAFKA_TOPICS, PUSHGATEWAY_URL)

    wait_for_kafka(KAFKA_BOOTSTRAP)
    wait_for_pushgateway(PUSHGATEWAY_URL)

    # Start background flush thread
    t = threading.Thread(target=flush_loop, daemon=True)
    t.start()

    # Run consumer in main thread
    consume_loop()


if __name__ == "__main__":
    main()