#!/usr/bin/env python3
"""
timescale_writer.py
===================
Kafka consumer that reads ALL metrics.* topics and bulk-inserts rows
into the TimescaleDB hypertable  tsdb.metrics.

Uses COPY (via psycopg2 execute_values) for high-throughput inserts.
Batches are flushed either when BATCH_SIZE messages accumulate or
every FLUSH_INTERVAL_S seconds — whichever comes first.

Environment variables:
    KAFKA_BOOTSTRAP     e.g. kafka:9092
    KAFKA_TOPICS        comma-separated topic list
    KAFKA_GROUP_ID      consumer group, default: timescale-writer
    PG_DSN              PostgreSQL DSN
                        e.g. postgresql://fusion:fusion2026@timescaledb:5432/fusiondb
    BATCH_SIZE          rows per insert, default: 200
    FLUSH_INTERVAL_S    max seconds between flushes, default: 5
"""

import os
import json
import time
import logging
from datetime import datetime, timezone, timedelta

import psycopg2
import psycopg2.extras
from confluent_kafka import Consumer, KafkaError

# ── Config ────────────────────────────────────────────────────────────────────
KAFKA_BOOTSTRAP  = os.getenv("KAFKA_BOOTSTRAP",  "kafka:9092")
KAFKA_TOPICS     = os.getenv("KAFKA_TOPICS",
                              "metrics.fusion-reactor").split(",")
KAFKA_GROUP_ID   = os.getenv("KAFKA_GROUP_ID",   "timescale-writer")
PG_DSN           = os.getenv("PG_DSN",
                              "postgresql://fusion:fusion2026@timescaledb:5432/fusiondb")
BATCH_SIZE       = int(os.getenv("BATCH_SIZE",       "200"))
FLUSH_INTERVAL_S = float(os.getenv("FLUSH_INTERVAL_S", "5"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("timescale-writer")

# ── SQL ───────────────────────────────────────────────────────────────────────
INSERT_SQL = """
    INSERT INTO tsdb.metrics
        (time, origin, subsystem, metric_name, value, unit, tags)
    VALUES %s
    ON CONFLICT DO NOTHING
"""

# ── DB helpers ─────────────────────────────────────────────────────────────────

def connect_db(dsn: str, retries: int = 20, delay: float = 3.0):
    for i in range(retries):
        try:
            conn = psycopg2.connect(dsn)
            conn.autocommit = False
            log.info("Connected to TimescaleDB")
            return conn
        except psycopg2.OperationalError as e:
            log.info("Waiting for TimescaleDB… (%d/%d) %s", i + 1, retries, e)
            time.sleep(delay)
    raise RuntimeError("Could not connect to TimescaleDB")


def flush_batch(conn, batch: list[dict]) -> int:
    """
    Insert a batch of envelopes into tsdb.metrics.
    Returns number of rows inserted.
    Reconnects automatically on connection failure.
    """
    if not batch:
        return 0

    rows = []
    for env in batch:
        try:
            ts = datetime.fromisoformat(
                env["timestamp"].replace("Z", "+00:00")
            )
        except (KeyError, ValueError):
            ts = datetime.now(timezone.utc)

        rows.append((
            ts,
            env.get("origin",    "unknown"),
            env.get("subsystem", "unknown"),
            env.get("metric",    "unknown"),
            float(env.get("value", 0)),
            env.get("unit", ""),
            json.dumps(env.get("tags", {})),   # stored as JSONB
        ))

    try:
        with conn.cursor() as cur:
            psycopg2.extras.execute_values(cur, INSERT_SQL, rows, page_size=200)
        conn.commit()
        return len(rows)
    except psycopg2.Error as e:
        conn.rollback()
        log.error("DB insert error: %s", e)
        return 0


# ── Kafka helpers ─────────────────────────────────────────────────────────────

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


# ── Main consumer loop ────────────────────────────────────────────────────────

def main():
    log.info("=== TimescaleDB Writer starting ===")
    log.info("Kafka: %s  Topics: %s", KAFKA_BOOTSTRAP, KAFKA_TOPICS)
    log.info("PG DSN: %s  Batch: %d  Flush every: %ss",
             PG_DSN, BATCH_SIZE, FLUSH_INTERVAL_S)

    wait_for_kafka(KAFKA_BOOTSTRAP)
    conn = connect_db(PG_DSN)

    consumer = Consumer({
        "bootstrap.servers":  KAFKA_BOOTSTRAP,
        "group.id":           KAFKA_GROUP_ID,
        "auto.offset.reset":  "earliest",   # catch up on any missed history
        "enable.auto.commit": False,        # we commit manually after DB flush
    })
    consumer.subscribe(KAFKA_TOPICS)
    log.info("Subscribed to topics: %s", KAFKA_TOPICS)

    batch: list[dict] = []
    last_flush = time.monotonic()
    total_inserted = 0

    try:
        while True:
            msg = consumer.poll(timeout=1.0)

            if msg is not None:
                if msg.error():
                    if msg.error().code() != KafkaError._PARTITION_EOF:
                        log.error("Kafka error: %s", msg.error())
                else:
                    try:
                        envelope = json.loads(msg.value().decode("utf-8"))
                        batch.append(envelope)
                    except (json.JSONDecodeError, UnicodeDecodeError) as e:
                        log.warning("Bad message skipped: %s", e)

            # Flush when batch is full OR timer expired
            elapsed = time.monotonic() - last_flush
            if len(batch) >= BATCH_SIZE or (batch and elapsed >= FLUSH_INTERVAL_S):
                n = flush_batch(conn, batch)
                total_inserted += n
                if n:
                    consumer.commit(asynchronous=False)
                    log.info("Flushed %d rows | total=%d | batch_time=%.1fs",
                             n, total_inserted, elapsed)
                batch = []
                last_flush = time.monotonic()

            # Reconnect if DB connection dropped
            if conn.closed:
                log.warning("DB connection lost — reconnecting…")
                conn = connect_db(PG_DSN)

    except KeyboardInterrupt:
        log.info("Shutting down…")
    finally:
        if batch:
            flush_batch(conn, batch)
        consumer.close()
        conn.close()
        log.info("Done. Total rows inserted: %d", total_inserted)


if __name__ == "__main__":
    main()