FROM python:3.12-slim

# confluent-kafka needs librdkafka C library
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc librdkafka-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY fusion_producer.py .

CMD python3 -u /app/fusion_producer.py