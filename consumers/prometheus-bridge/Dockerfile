FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc librdkafka-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY prometheus_bridge.py .

CMD python3 -u /app/prometheus_bridge.py