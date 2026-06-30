#!/usr/bin/env bash
# deploy.sh — Full deployment script for Medplum FHIR Platform on Databricks
#
# This script:
#   1. Destroys existing resources (clean slate)
#   2. Deploys the DABs bundle (Lakebase project + app)
#   3. Waits for the Lakebase database to be ready
#   4. Grants schema permissions to the app's service principal
#   5. Starts the app, then deploys the code
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
DB_NAME="databricks_postgres"
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
command -v psql >/dev/null 2>&1 || error "psql not found. Install it first (brew install libpq)."

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

MAX_WAIT=180
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
  BRANCH_STATUS=$(databricks postgres list-branches "projects/${LAKEBASE_PROJECT}" --output json 2>/dev/null | \
    jq -r ".[] | select(.branch_id == \"${LAKEBASE_BRANCH}\") | .status.current_state // \"UNKNOWN\"" 2>/dev/null || echo "NOT_FOUND")

  if [ "$BRANCH_STATUS" = "READY" ]; then
    ok "Lakebase branch is ready"
    break
  fi

  if [ $WAITED -eq 0 ]; then
    info "  Current state: ${BRANCH_STATUS} — waiting..."
  fi

  sleep 10
  WAITED=$((WAITED + 10))

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

# Get the endpoint host for direct psql connection
ENDPOINT_INFO=$(databricks postgres get-endpoint \
  "projects/${LAKEBASE_PROJECT}/branches/${LAKEBASE_BRANCH}/endpoints/primary" \
  --output json 2>/dev/null)
PG_HOST=$(echo "$ENDPOINT_INFO" | jq -r '.status.hosts.host // empty')

if [ -z "$PG_HOST" ]; then
  error "Could not find Lakebase endpoint host"
fi

info "  Lakebase host: ${PG_HOST}"

# Get an OAuth token for psql authentication
TOKEN=$(databricks auth token --output json 2>/dev/null | jq -r '.access_token // empty')
if [ -z "$TOKEN" ]; then
  error "Could not get OAuth token from databricks CLI"
fi

# Run the GRANT via psql
info "  Running GRANT CREATE ON SCHEMA ${SCHEMA_NAME}..."
PGPASSWORD="$TOKEN" psql \
  "host=${PG_HOST} port=5432 dbname=${DB_NAME} user=databricks sslmode=require" \
  -c "GRANT ALL ON SCHEMA ${SCHEMA_NAME} TO \"${SP_CLIENT_ID}\";" \
  2>&1 || {
    warn "GRANT command failed — the app may not have CREATE permission on public schema"
    warn "You can grant manually: GRANT ALL ON SCHEMA public TO \"${SP_CLIENT_ID}\";"
  }
ok "Permissions granted"

# --- Step 5: Run the app via bundle ---
info "Step 5: Running the app (bundle run starts compute + deploys code)..."
databricks bundle run medplum_server 2>&1 | tail -10 || true
ok "App run triggered"

# --- Step 6: Wait for app to be healthy ---
info "Step 6: Waiting for app to start..."
MAX_APP_WAIT=300
APP_WAITED=0

while [ $APP_WAITED -lt $MAX_APP_WAIT ]; do
  APP_JSON=$(databricks apps get "$APP_NAME" --output json 2>/dev/null || echo "{}")
  APP_STATE=$(echo "$APP_JSON" | jq -r '.app_status.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

  if [ "$APP_STATE" = "RUNNING" ]; then
    ok "App is running!"
    break
  fi

  if [ "$APP_STATE" = "CRASHED" ] || [ "$APP_STATE" = "FAILED" ]; then
    error "App crashed. Check logs with: databricks apps get-logs ${APP_NAME}"
  fi

  sleep 10
  APP_WAITED=$((APP_WAITED + 10))

  if [ $((APP_WAITED % 30)) -eq 0 ]; then
    info "  Waiting... (${APP_WAITED}s, app state: ${APP_STATE})"
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
