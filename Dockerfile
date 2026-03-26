
FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir prometheus-client

COPY fusion_exporter.py .

EXPOSE 8000

CMD python3 -u /app/fusion_exporter.py