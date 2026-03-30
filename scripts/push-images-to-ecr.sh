#!/usr/bin/env bash
# =============================================================================
# scripts/push-images-to-ecr.sh
# Pulls all third-party Docker Hub images used by the stack
# and pushes them to ECR so ECS can pull them from within the VPC.
#
# Run this ONCE from your local machine (which has internet access).
# After this all ECS tasks pull from ECR instead of Docker Hub.
# =============================================================================
set -euo pipefail

AWS_REGION="us-east-1"
ACCOUNT_ID="245013469638"
ECR="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# All third-party images used by the stack
# Format: "source-image|ecr-repo-name|tag"
IMAGES=(
  "timescale/timescaledb:latest-pg16|timescaledb|latest-pg16"
  "prom/prometheus:v2.51.0|prometheus|v2.51.0"
  "prom/pushgateway:v1.8.0|pushgateway|v1.8.0"
  "grafana/grafana:10.4.0|grafana|10.4.0"
  "provectuslabs/kafka-ui:latest|kafka-ui|latest"
)

echo "▶ Logging in to ECR..."
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $ECR

echo ""

for entry in "${IMAGES[@]}"; do
  SOURCE=$(echo $entry | cut -d'|' -f1)
  REPO=$(echo $entry | cut -d'|' -f2)
  TAG=$(echo $entry | cut -d'|' -f3)
  ECR_IMAGE="${ECR}/${REPO}:${TAG}"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Source:  $SOURCE"
  echo "  Target:  $ECR_IMAGE"

  # Create ECR repo if it doesn't exist
  aws ecr create-repository \
    --repository-name "$REPO" \
    --region $AWS_REGION \
    --image-scanning-configuration scanOnPush=true \
    2>/dev/null && echo "  Created ECR repo: $REPO" \
    || echo "  ECR repo exists:  $REPO"

  # Pull from Docker Hub
  echo "  Pulling..."
  docker pull $SOURCE

  # Tag for ECR
  docker tag $SOURCE $ECR_IMAGE

  # Push to ECR
  echo "  Pushing to ECR..."
  docker push $ECR_IMAGE

  echo "  ✅ Done: $REPO:$TAG"
  echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ All images pushed to ECR"
echo ""
echo "Next: update terraform to use ECR images then apply"
echo "  cd infrastructure && terraform apply"