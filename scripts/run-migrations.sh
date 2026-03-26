#!/usr/bin/env bash
# =============================================================================
# scripts/run-migrations.sh
# Run ONCE after terraform apply to initialise the TimescaleDB schema.
# Uses an ECS one-shot task so it runs inside the VPC with RDS access.
# =============================================================================
set -euo pipefail

AWS_REGION="us-east-1"
PROJECT="fusion-monitor"
CLUSTER="${PROJECT}-cluster"

echo "▶ Running database migrations via ECS one-shot task..."

# Get RDS endpoint from SSM
DB_HOST=$(aws ssm get-parameter \
    --name "/${PROJECT}/DB_HOST" \
    --query "Parameter.Value" \
    --output text \
    --region "$AWS_REGION")

DB_PASSWORD=$(aws ssm get-parameter \
    --name "/${PROJECT}/DB_PASSWORD" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region "$AWS_REGION")

# Get VPC/subnet info from terraform output
SUBNET=$(cd infrastructure && terraform output -json | jq -r '.vpc_private_subnets.value[0]')
SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${PROJECT}-ecs-sg" \
    --query "SecurityGroups[0].GroupId" \
    --output text \
    --region "$AWS_REGION")

echo "  DB Host: $DB_HOST"
echo "  Subnet:  $SUBNET"
echo "  SG:      $SG"

# Encode the SQL file as base64 to pass as an env var
SQL_B64=$(base64 -i sql/init.sql)

# Run a one-shot ECS Fargate task using the postgres image
TASK_ARN=$(aws ecs run-task \
    --cluster "$CLUSTER" \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=DISABLED}" \
    --overrides "{
      \"containerOverrides\": [{
        \"name\": \"migrate\",
        \"command\": [\"bash\", \"-c\",
          \"echo $SQL_B64 | base64 -d > /tmp/init.sql && PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U fusion -d fusiondb -f /tmp/init.sql\"
        ]
      }]
    }" \
    --task-definition "arn:aws:ecs:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):task-definition/timescale-writer" \
    --query "tasks[0].taskArn" \
    --output text \
    --region "$AWS_REGION")

echo "  Task started: $TASK_ARN"
echo "  Waiting for migration to complete..."

aws ecs wait tasks-stopped \
    --cluster "$CLUSTER" \
    --tasks "$TASK_ARN" \
    --region "$AWS_REGION"

EXIT_CODE=$(aws ecs describe-tasks \
    --cluster "$CLUSTER" \
    --tasks "$TASK_ARN" \
    --query "tasks[0].containers[0].exitCode" \
    --output text \
    --region "$AWS_REGION")

if [ "$EXIT_CODE" = "0" ]; then
    echo "  ✅ Migrations complete"
else
    echo "  ❌ Migration failed with exit code $EXIT_CODE"
    exit 1
fi