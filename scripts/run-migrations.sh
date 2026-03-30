#!/usr/bin/env bash
# =============================================================================
# scripts/run-migrations.sh
# Uploads init.sql to S3, then runs it via ECS exec inside the
# TimescaleDB container — avoids the 8192 char override limit
# =============================================================================
set -euo pipefail

AWS_REGION="us-east-1"
PROJECT="fusion-monitor"
CLUSTER="${PROJECT}-cluster"
BUCKET="${PROJECT}-migrations-$(aws sts get-caller-identity --query Account --output text --region $AWS_REGION)"

echo "▶ Running database migrations..."

# ── 1. Create S3 bucket for SQL file (idempotent) ────────────────────────────
echo "  Creating S3 bucket: $BUCKET"
# us-east-1 must NOT use LocationConstraint -- all other regions must
if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket         --bucket "$BUCKET"         --region "$AWS_REGION" 2>/dev/null || true
else
    aws s3api create-bucket         --bucket "$BUCKET"         --region "$AWS_REGION"         --create-bucket-configuration LocationConstraint="$AWS_REGION"         2>/dev/null || true
fi

aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
    2>/dev/null || true

# ── 2. Upload init.sql ────────────────────────────────────────────────────────
echo "  Uploading sql/init.sql to s3://${BUCKET}/init.sql"
aws s3 cp sql/init.sql "s3://${BUCKET}/init.sql" --region "$AWS_REGION"

# ── 3. Grant ECS task execution role access to the bucket ────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region $AWS_REGION)
EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${PROJECT}-ecs-execution-role"

aws s3api put-bucket-policy --bucket "$BUCKET" --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": { \"AWS\": \"${EXEC_ROLE_ARN}\" },
    \"Action\": [\"s3:GetObject\"],
    \"Resource\": \"arn:aws:s3:::${BUCKET}/*\"
  }]
}" 2>/dev/null || true

# ── 4. Get runtime values ─────────────────────────────────────────────────────
DB_PASSWORD=$(aws ssm get-parameter \
    --name "/${PROJECT}/DB_PASSWORD" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region "$AWS_REGION")

# Get subnet from VPC
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=*${PROJECT}*" \
    --query "Vpcs[0].VpcId" \
    --output text \
    --region "$AWS_REGION")

SUBNET=$(aws ec2 describe-subnets \
    --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=state,Values=available" \
    --query "Subnets[0].SubnetId" \
    --output text \
    --region "$AWS_REGION")

SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${PROJECT}-ecs-sg" \
    --query "SecurityGroups[0].GroupId" \
    --output text \
    --region "$AWS_REGION")

echo "  Subnet: $SUBNET"
echo "  SG:     $SG"

# ── 5. Run migration task ─────────────────────────────────────────────────────
# The command downloads init.sql from S3 then runs psql against localhost
CMD="aws s3 cp s3://${BUCKET}/init.sql /tmp/init.sql --region ${AWS_REGION} && PGPASSWORD=${DB_PASSWORD} psql -h localhost -U fusion -d fusiondb -f /tmp/init.sql && echo MIGRATION_COMPLETE"

echo "  Starting one-shot migration task..."
TASK_ARN=$(aws ecs run-task \
    --cluster "$CLUSTER" \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET}],securityGroups=[${SG}],assignPublicIp=DISABLED}" \
    --overrides "{\"containerOverrides\":[{\"name\":\"timescaledb\",\"command\":[\"bash\",\"-c\",\"${CMD}\"]}]}" \
    --task-definition timescaledb \
    --query "tasks[0].taskArn" \
    --output text \
    --region "$AWS_REGION")

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" = "None" ]; then
    echo "  ❌ Failed to start migration task"
    exit 1
fi

echo "  Task: $TASK_ARN"
echo "  Waiting for completion (up to 5 minutes)..."

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

# ── 6. Cleanup S3 ─────────────────────────────────────────────────────────────
aws s3 rm "s3://${BUCKET}/init.sql" --region "$AWS_REGION" 2>/dev/null || true

if [ "$EXIT_CODE" = "0" ]; then
    echo "  ✅ Migrations complete"
else
    echo "  ❌ Migration failed — exit code: $EXIT_CODE"
    echo ""
    echo "  View logs:"
    echo "  aws logs tail /ecs/${PROJECT}/timescaledb --region ${AWS_REGION} --since 10m"
    exit 1
fi