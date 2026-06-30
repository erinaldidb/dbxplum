#!/usr/bin/env bash
# deploy.sh — Full deployment script for Medplum FHIR Platform on Databricks
#
# This script:
#   1. Destroys existing resources (clean slate)
#   2. Deploys the DABs bundle (Lakebase project + app)
#   3. Waits for the Lakebase database to be ready
#   4. Grants schema permissions to the app's service principal
#   5. Deploys the app code and starts it
#
# Usage:
#   ./deploy.sh              # Full deploy (destroy + deploy + grant + start)
#   ./deploy.sh --no-destroy # Skip the destroy step (redeploy in place)
#
set -euo pipefail

# --- Configuration ---
BUNDLE_NAME="medplum-fhir-platform"
APP_NAME="medplum-server"
LAKEBASE_PROJECT="medplum"
LAKEBASE_BRANCH="production"
DB_NAME="databricks-postgres"
SCHEMA_NAME="public"  # Grant CREATE on public schema for Medplum migrations

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Parse arguments ---
SKIP_DESTROY=false
for arg in "$@"; do
  case "$arg" in
    --no-destroy) SKIP_DESTROY=true ;;
    --help|-h)
      echo "Usage: $0 [--no-destroy]"
      echo ""
      echo "  --no-destroy   Skip destroying existing resources"
      exit 0
      ;;
    *) error "Unknown argument: $arg" ;;
  esac
done

# --- Pre-flight checks ---
info "Running pre-flight checks..."
command -v databricks >/dev/null 2>&1 || error "databricks CLI not found. Install it first."
command -v jq >/dev/null 2>&1 || error "jq not found. Install it first."

# Verify bundle is valid
databricks bundle validate >/dev/null 2>&1 || error "Bundle validation failed. Run 'databricks bundle validate' to see errors."
ok "Pre-flight checks passed"

# --- Step 1: Destroy existing resources ---
if [ "$SKIP_DESTROY" = false ]; then
  info "Step 1: Destroying existing resources..."
  databricks bundle destroy --auto-approve 2>&1 | tail -5
  ok "Resources destroyed"

  # Wait for the app to be fully deleted from the platform
  info "Step 1b: Waiting for app '$APP_NAME' to be fully deleted..."
  MAX_DELETE_WAIT=180
  DELETE_WAITED=0
  while [ $DELETE_WAITED -lt $MAX_DELETE_WAIT ]; do
    APP_EXISTS=$(databricks apps get "$APP_NAME" 2>&1 || true)
    if echo "$APP_EXISTS" | grep -qi "does not exist\|not found\|RESOURCE_DOES_NOT_EXIST\|404"; then
      break
    fi
    # Check if app is in a deleting/deleted state
    APP_STATE=$(echo "$APP_EXISTS" | jq -r '.app_status.state // empty' 2>/dev/null || true)
    if [ "$APP_STATE" = "DELETED" ]; then
      break
    fi
    sleep 10
    DELETE_WAITED=$((DELETE_WAITED + 10))
    echo -n "."
  done
  echo ""
  if [ $DELETE_WAITED -ge $MAX_DELETE_WAIT ]; then
    warn "App deletion wait timed out after ${MAX_DELETE_WAIT}s — proceeding anyway (deploy may retry)"
  else
    ok "App fully deleted (waited ${DELETE_WAITED}s)"
  fi
else
  info "Step 1: Skipping destroy (--no-destroy flag)"
fi

# --- Step 2: Deploy the bundle ---
info "Step 2: Deploying DABs bundle (Lakebase project + app definition)..."
# Retry deploy up to 3 times in case the app deletion is still propagating
DEPLOY_ATTEMPTS=0
MAX_DEPLOY_ATTEMPTS=3
while [ $DEPLOY_ATTEMPTS -lt $MAX_DEPLOY_ATTEMPTS ]; do
  DEPLOY_OUTPUT=$(databricks bundle deploy 2>&1) && break
  DEPLOY_ATTEMPTS=$((DEPLOY_ATTEMPTS + 1))
  if echo "$DEPLOY_OUTPUT" | grep -qi "already exists"; then
    warn "App still exists on platform — waiting 30s before retry ($DEPLOY_ATTEMPTS/$MAX_DEPLOY_ATTEMPTS)..."
    sleep 30
  else
    echo "$DEPLOY_OUTPUT" | tail -10
    error "Bundle deploy failed with unexpected error"
  fi
done
if [ $DEPLOY_ATTEMPTS -ge $MAX_DEPLOY_ATTEMPTS ]; then
  echo "$DEPLOY_OUTPUT" | tail -10
  error "Bundle deploy failed after $MAX_DEPLOY_ATTEMPTS attempts — app may still be deleting. Try again in a minute."
fi
echo "$DEPLOY_OUTPUT" | tail -5
ok "Bundle deployed"

# --- Step 3: Wait for Lakebase database to be ready ---
info "Step 3: Waiting for Lakebase database to be ready..."

MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
  # Check if the branch exists and is ready
  BRANCH_STATUS=$(databricks lakebase branches get \
    "projects/${LAKEBASE_PROJECT}/branches/${LAKEBASE_BRANCH}" \
    --output json 2>/dev/null | jq -r '.state // "UNKNOWN"' 2>/dev/null || echo "NOT_FOUND")

  if [ "$BRANCH_STATUS" = "ACTIVE" ] || [ "$BRANCH_STATUS" = "ONLINE" ]; then
    ok "Lakebase branch is ready (state: ${BRANCH_STATUS})"
    break
  fi

  if [ $WAITED -eq 0 ]; then
    info "  Current state: ${BRANCH_STATUS} — waiting..."
  fi

  sleep 5
  WAITED=$((WAITED + 5))

  if [ $((WAITED % 30)) -eq 0 ]; then
    info "  Still waiting... (${WAITED}s elapsed, state: ${BRANCH_STATUS})"
  fi
done

if [ $WAITED -ge $MAX_WAIT ]; then
  warn "Timed out waiting for Lakebase branch (last state: ${BRANCH_STATUS})"
  warn "Proceeding anyway — the grant step may fail if the database isn't ready yet"
fi

# --- Step 4: Grant permissions to app service principal ---
info "Step 4: Granting schema permissions to app service principal..."

# Get the app's service principal client ID
APP_INFO=$(databricks apps get "$APP_NAME" --output json 2>/dev/null)
SP_CLIENT_ID=$(echo "$APP_INFO" | jq -r '.service_principal_client_id // empty')

if [ -z "$SP_CLIENT_ID" ]; then
  error "Could not find service principal client ID for app '${APP_NAME}'"
fi

info "  App SP client ID: ${SP_CLIENT_ID}"

# Get the SP's display name (needed for GRANT)
SP_INFO=$(databricks service-principals list --output json 2>/dev/null | \
  jq -r ".[] | select(.application_id == \"${SP_CLIENT_ID}\") | .display_name" 2>/dev/null || echo "")

if [ -z "$SP_INFO" ]; then
  # Try getting it from the service-principals API with the application_id filter
  SP_INFO=$(databricks service-principals list --output json 2>/dev/null | \
    jq -r ".[].display_name" 2>/dev/null | head -1 || echo "")
fi

# Use the SP client ID to run the GRANT via Lakebase SQL
# The format for granting is: GRANT CREATE ON SCHEMA <schema> TO `<sp_client_id>`
info "  Granting CREATE on schema '${SCHEMA_NAME}' to SP..."

# Execute the GRANT via lakebase SQL
GRANT_SQL="GRANT CREATE ON SCHEMA ${SCHEMA_NAME} TO \`${SP_CLIENT_ID}\`; GRANT USAGE ON SCHEMA ${SCHEMA_NAME} TO \`${SP_CLIENT_ID}\`;"

GRANT_RESULT=$(databricks lakebase execute-statement \
  "projects/${LAKEBASE_PROJECT}/branches/${LAKEBASE_BRANCH}/databases/${DB_NAME}" \
  --statement "${GRANT_SQL}" \
  --output json 2>&1) || true

if echo "$GRANT_RESULT" | grep -qi "error\|failed\|denied"; then
  warn "GRANT via lakebase execute-statement may have failed: ${GRANT_RESULT}"
  info "  Trying alternative approach via statement execution API..."

  # Alternative: use the Databricks SQL statement execution if lakebase CLI doesn't support it
  # Get the connection details and run via psql-style approach
  CONN_INFO=$(databricks lakebase branches get \
    "projects/${LAKEBASE_PROJECT}/branches/${LAKEBASE_BRANCH}" \
    --output json 2>/dev/null || echo "{}")

  PG_HOST=$(echo "$CONN_INFO" | jq -r '.postgres_connection_info.host // empty' 2>/dev/null)
  PG_PORT=$(echo "$CONN_INFO" | jq -r '.postgres_connection_info.port // "5432"' 2>/dev/null)

  if [ -n "$PG_HOST" ]; then
    info "  Lakebase host: ${PG_HOST}:${PG_PORT}"
    info "  Attempting GRANT via psql..."

    # Get a token for authentication
    TOKEN=$(databricks auth token --output json 2>/dev/null | jq -r '.access_token // empty')

    if [ -n "$TOKEN" ] && command -v psql >/dev/null 2>&1; then
      PGPASSWORD="$TOKEN" psql \
        "host=${PG_HOST} port=${PG_PORT} dbname=${DB_NAME} user=databricks sslmode=require" \
        -c "GRANT CREATE ON SCHEMA ${SCHEMA_NAME} TO \"${SP_CLIENT_ID}\";" \
        -c "GRANT USAGE ON SCHEMA ${SCHEMA_NAME} TO \"${SP_CLIENT_ID}\";" \
        2>&1 && ok "Permissions granted via psql" || warn "psql GRANT attempt also failed"
    else
      warn "psql not available or no token. You may need to grant permissions manually:"
      warn "  GRANT CREATE ON SCHEMA ${SCHEMA_NAME} TO \"${SP_CLIENT_ID}\";"
    fi
  fi
else
  ok "Permissions granted via lakebase execute-statement"
fi

# --- Step 5: Deploy and start the app ---
info "Step 5: Deploying app code..."

# Trigger a fresh deployment
databricks apps deploy "$APP_NAME" --source-code-path "/Workspace/Users/$(databricks current-user me --output json | jq -r '.userName')/.bundle/${BUNDLE_NAME}/dev/files/apps/medplum-server" 2>&1 | tail -5
ok "App deployment triggered"

info "Step 6: Starting the app..."
databricks apps start "$APP_NAME" 2>&1 | tail -5 || true

# --- Step 7: Wait for app to be healthy ---
info "Step 7: Waiting for app to start..."
MAX_APP_WAIT=180
APP_WAITED=0

while [ $APP_WAITED -lt $MAX_APP_WAIT ]; do
  APP_STATUS=$(databricks apps get "$APP_NAME" --output json 2>/dev/null | jq -r '.compute_status.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
  DEPLOY_STATUS=$(databricks apps get "$APP_NAME" --output json 2>/dev/null | jq -r '.active_deployment.status.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

  if [ "$APP_STATUS" = "ACTIVE" ] && [ "$DEPLOY_STATUS" = "SUCCEEDED" ]; then
    ok "App is running!"
    break
  fi

  if [ "$APP_STATUS" = "ERROR" ] || [ "$DEPLOY_STATUS" = "FAILED" ]; then
    error "App failed to start. Check logs with: databricks apps get-logs ${APP_NAME}"
  fi

  sleep 10
  APP_WAITED=$((APP_WAITED + 10))

  if [ $((APP_WAITED % 30)) -eq 0 ]; then
    info "  Waiting... (${APP_WAITED}s, compute: ${APP_STATUS}, deploy: ${DEPLOY_STATUS})"
  fi
done

if [ $APP_WAITED -ge $MAX_APP_WAIT ]; then
  warn "Timed out waiting for app to be fully healthy"
  info "  Check status with: databricks apps get ${APP_NAME}"
  info "  Check logs with: databricks apps get-logs ${APP_NAME}"
fi

# --- Done ---
echo ""
APP_URL=$(databricks apps get "$APP_NAME" --output json 2>/dev/null | jq -r '.url // "unknown"')
ok "============================================"
ok " Deployment complete!"
ok " App URL: ${APP_URL}"
ok "============================================"
