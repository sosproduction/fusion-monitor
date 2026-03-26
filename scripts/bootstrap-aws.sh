#!/usr/bin/env bash
# =============================================================================
# scripts/bootstrap-aws.sh
# Run ONCE before first terraform apply.
# Creates S3 state bucket, DynamoDB lock table, ECR repos, and SSM secrets.
# =============================================================================
set -euo pipefail

# ── Config — edit these ───────────────────────────────────────────────────────
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PROJECT="fusion-monitor"
DOMAIN="fusion-monitor.yourdomain.com"   # ← change to your domain

echo "▶ Bootstrapping Fusion Monitor AWS infrastructure"
echo "  Account:  $AWS_ACCOUNT_ID"
echo "  Region:   $AWS_REGION"
echo "  Project:  $PROJECT"
echo ""

# ── 1. Terraform remote state S3 bucket ──────────────────────────────────────
echo "▶ Creating Terraform state S3 bucket..."
aws s3api create-bucket \
    --bucket "${PROJECT}-tfstate" \
    --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" \
    2>/dev/null || echo "  (bucket already exists)"

aws s3api put-bucket-versioning \
    --bucket "${PROJECT}-tfstate" \
    --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
    --bucket "${PROJECT}-tfstate" \
    --server-side-encryption-configuration '{
      "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
    }'

echo "  ✅ S3 state bucket: ${PROJECT}-tfstate"

# ── 2. DynamoDB lock table ────────────────────────────────────────────────────
echo "▶ Creating DynamoDB state lock table..."
aws dynamodb create-table \
    --table-name "${PROJECT}-tflock" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION" \
    2>/dev/null || echo "  (table already exists)"

echo "  ✅ DynamoDB lock table: ${PROJECT}-tflock"

# ── 3. ECR Repositories (one per custom image) ────────────────────────────────
echo "▶ Creating ECR repositories..."
for repo in fusion-producer prometheus-bridge timescale-writer fusion-ui; do
    aws ecr create-repository \
        --repository-name "$repo" \
        --region "$AWS_REGION" \
        --image-scanning-configuration scanOnPush=true \
        2>/dev/null || echo "  (repo $repo already exists)"
    echo "  ✅ ECR: $repo"
done

# ── 4. SSM Parameter Store secrets ───────────────────────────────────────────
echo ""
echo "▶ Storing secrets in SSM Parameter Store..."

read -rsp "Enter TimescaleDB password: " DB_PASS; echo
read -rsp "Enter Grafana admin password: " GRAFANA_PASS; echo

aws ssm put-parameter \
    --name "/${PROJECT}/DB_PASSWORD" \
    --value "$DB_PASS" \
    --type SecureString \
    --overwrite \
    --region "$AWS_REGION"

aws ssm put-parameter \
    --name "/${PROJECT}/GRAFANA_PASSWORD" \
    --value "$GRAFANA_PASS" \
    --type SecureString \
    --overwrite \
    --region "$AWS_REGION"

echo "  ✅ Secrets stored in SSM"

# ── 5. Create terraform.tfvars ────────────────────────────────────────────────
cat > infrastructure/terraform.tfvars << EOF
aws_region  = "$AWS_REGION"
project     = "$PROJECT"
environment = "production"
domain      = "$DOMAIN"
account_id  = "$AWS_ACCOUNT_ID"
db_password = "$DB_PASS"
EOF

echo ""
echo "  ✅ infrastructure/terraform.tfvars written"
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Bootstrap complete. Run terraform next:"
echo ""
echo "    cd infrastructure"
echo "    terraform init"
echo "    terraform plan"
echo "    terraform apply"
echo "═══════════════════════════════════════════════════════"