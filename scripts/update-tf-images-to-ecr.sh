#!/usr/bin/env bash
# =============================================================================
# scripts/update-tf-images-to-ecr.sh
# Rewrites all third-party Docker Hub image refs in .tf files to ECR
# =============================================================================
set -euo pipefail

ECR="245013469638.dkr.ecr.us-east-1.amazonaws.com"

echo "▶ Updating Terraform image references to ECR..."

python3 - << PYEOF
import os, glob

ECR = "${ECR}"

# Map of Docker Hub image → ECR image
replacements = {
    '"timescale/timescaledb:latest-pg16"':  f'"{ECR}/timescaledb:latest-pg16"',
    '"prom/prometheus:v2.51.0"':            f'"{ECR}/prometheus:v2.51.0"',
    '"prom/pushgateway:v1.8.0"':            f'"{ECR}/pushgateway:v1.8.0"',
    '"grafana/grafana:10.4.0"':             f'"{ECR}/grafana:10.4.0"',
    '"provectuslabs/kafka-ui:latest"':      f'"{ECR}/kafka-ui:latest"',
}

tf_files = glob.glob('infrastructure/*.tf')
for filepath in tf_files:
    with open(filepath, 'r') as f:
        content = f.read()

    original = content
    for old, new in replacements.items():
        content = content.replace(old, new)

    if content != original:
        with open(filepath, 'w') as f:
            f.write(content)
        print(f"  Updated: {filepath}")

print("Done")
PYEOF

echo ""
echo "✅ Terraform files updated"
echo ""
echo "Verify changes:"
echo "  grep -r 'ecr.amazonaws.com' infrastructure/*.tf"
echo ""
echo "Then apply:"
echo "  cd infrastructure && terraform apply"