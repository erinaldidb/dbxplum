#!/usr/bin/env bash
# deploy.sh — Full deployment script for Medplum FHIR Platform on Databricks
#
# Usage:
#   ./deploy.sh              # Full deploy (destroy + deploy + grant + start)
#   ./deploy.sh --no-destroy # Skip the destroy step (redeploy in place)
#
set -euo pipefail

# Re-exec with bash if invoked via `sh deploy.sh` (macOS /bin/sh lacks bash features)
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

# Always run from the repo root so bundle commands resolve databricks.yml
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- Configuration ---
BUNDLE_NAME="medplum-fhir-platform"
APP_NAME="medplum-server"
LAKEBASE_PROJECT="medplum"
LAKEBASE_BRANCH="production"
DB_NAME="databricks_postgres"
SCHEMA_NAME="public"

# --- Colors & styles ---
if [ -t 1 ]; then
  BOLD='\033[1m'
  DIM='\033[2m'
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  MAGENTA='\033[0;35m'
  WHITE='\033[0;37m'
  NC='\033[0m'
  IS_TTY=true
else
  BOLD='' DIM='' RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' WHITE='' NC=''
  IS_TTY=false
fi

# --- UI helpers ---
TOTAL_STEPS=7
CURRENT_STEP=0
DEPLOY_START=$(date +%s)

ui_banner() {
  local mode="Full deploy"
  [ "${SKIP_DESTROY:-false}" = true ] && mode="Redeploy (--no-destroy)"
  printf '\n'
  printf '%b' "${CYAN}${BOLD}"
  printf '  ╔══════════════════════════════════════════════════════════════╗\n'
  printf '  ║                                                              ║\n'
  printf '  ║              ░▒▓%b  DBXPLUM  %b▓▒░                               ║\n' "${WHITE}" "${CYAN}${BOLD}"
  printf '  ║                                                              ║\n'
  printf '  ║        %bMedplum FHIR Platform on Databricks%b                   ║\n' "${WHITE}" "${CYAN}${BOLD}"
  printf '  ║        %bLakebase · Databricks Apps · Co-located Redis%b         ║\n' "${DIM}" "${CYAN}${BOLD}"
  printf '  ║                                                              ║\n'
  printf '  ╚══════════════════════════════════════════════════════════════╝\n'
  printf '%b' "${NC}"
  printf '  %bBundle:%b  %s\n' "${DIM}" "${NC}" "$BUNDLE_NAME"
  printf '  %bApp:%b     %s\n' "${DIM}" "${NC}" "$APP_NAME"
  printf '  %bMode:%b    %s\n' "${DIM}" "${NC}" "$mode"
  printf '\n'
}

ui_divider() {
  printf '%b  ──────────────────────────────────────────────────────────────%b\n' "${DIM}" "${NC}"
}

ui_step_begin() {
  local title=$1
  CURRENT_STEP=$((CURRENT_STEP + 1))
  ui_divider
  printf '  %b[%d/%d]%b  %b%s%b\n' \
    "${MAGENTA}${BOLD}" "$CURRENT_STEP" "$TOTAL_STEPS" "${NC}" \
    "${BOLD}" "$title" "${NC}"
  printf '\n'
}

ui_detail() {
  printf '         %b·%b  %s\n' "${DIM}" "${NC}" "$*"
}

ui_info() {
  printf '  %b›%b  %s\n' "${BLUE}" "${NC}" "$*"
}

ui_ok() {
  printf '  %b✓%b  %s\n' "${GREEN}${BOLD}" "${NC}" "$*"
}

ui_warn() {
  printf '  %b!%b  %s\n' "${YELLOW}${BOLD}" "${NC}" "$*"
}

ui_error() {
  printf '\n'
  printf '  %b✗%b  %s\n' "${RED}${BOLD}" "${NC}" "$*"
  printf '\n'
  exit 1
}

# Progress bar: ui_progress <elapsed> <max_seconds> <label>
ui_progress() {
  local elapsed=$1 max=$2 label=${3:-}
  local width=36
  local pct=0
  [ "$max" -gt 0 ] && pct=$(( elapsed * 100 / max ))
  [ "$pct" -gt 100 ] && pct=100
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local bar_f bar_e
  bar_f=$(printf '%*s' "$filled" '' | tr ' ' '█')
  bar_e=$(printf '%*s' "$empty" '' | tr ' ' '░')
  if [ "$IS_TTY" = true ]; then
    printf '\r  %s %b%s%b%s %3d%% (%ds/%ds)  ' \
      "$label" "${CYAN}" "$bar_f" "${DIM}" "$bar_e" "$pct" "$elapsed" "$max"
  elif [ $((elapsed % 30)) -eq 0 ] || [ "$elapsed" -ge "$max" ] || [ "$pct" -eq 100 ]; then
    printf '  %s %b%s%b%s %3d%% (%ds/%ds)\n' \
      "$label" "${CYAN}" "$bar_f" "${DIM}" "$bar_e" "$pct" "$elapsed" "$max"
  fi
}

ui_progress_done() {
  [ "$IS_TTY" = true ] && printf '\r%*s\r' 80 ''
}

ui_success_box() {
  local url=$1
  local elapsed=$(( $(date +%s) - DEPLOY_START ))
  local mins=$(( elapsed / 60 ))
  local secs=$(( elapsed % 60 ))
  printf '\n'
  printf '%b' "${GREEN}${BOLD}"
  printf '  ╔══════════════════════════════════════════════════════════════════════════╗\n'
  printf '  ║                    DEPLOYMENT COMPLETE                                   ║\n'
  printf '  ╠══════════════════════════════════════════════════════════════════════════╣\n'
  printf '%b' "${NC}"
  printf '  %b║%b  %bApp URL%b                                                         %b║%b\n' \
    "${GREEN}${BOLD}" "${NC}" "${DIM}" "${NC}" "${GREEN}${BOLD}" "${NC}"
  printf '  %b║%b  %s%b\n' "${GREEN}${BOLD}" "${NC}" "$url" "${NC}"
  printf '  %b║%b                                                                      %b║%b\n' \
    "${GREEN}${BOLD}" "${NC}" "${GREEN}${BOLD}" "${NC}"
  printf '  %b║%b  %bDuration:%b  %dm %ds                                              %b║%b\n' \
    "${GREEN}${BOLD}" "${NC}" "${DIM}" "${NC}" "$mins" "$secs" "${GREEN}${BOLD}" "${NC}"
  printf '%b' "${GREEN}${BOLD}"
  printf '  ╚══════════════════════════════════════════════════════════════════════════╝\n'
  printf '%b\n' "${NC}"
}

error() { ui_error "$*"; }

# --- Parse arguments ---
SKIP_DESTROY=false
for arg in "$@"; do
  case "$arg" in
    --no-destroy) SKIP_DESTROY=true ;;
    --help|-h)
      printf 'Usage: %s [--no-destroy]\n\n  --no-destroy   Skip destroying existing resources\n' "$0"
      exit 0
      ;;
    *) error "Unknown argument: $arg" ;;
  esac
done

ui_banner

# --- Pre-flight checks ---
ui_step_begin "Pre-flight checks"
ui_info "Validating toolchain and bundle configuration..."

command -v databricks >/dev/null 2>&1 || error "databricks CLI not found. Install it first."
command -v jq >/dev/null 2>&1 || error "jq not found. Install it first."
command -v psql >/dev/null 2>&1 || error "psql not found. Install it first (brew install libpq)."

databricks bundle validate >/dev/null 2>&1 || error "Bundle validation failed. Run 'databricks bundle validate' to see errors."

ui_detail "databricks CLI  $(databricks --version 2>/dev/null | head -1 || echo 'ok')"
ui_detail "bundle target   dev"
ui_ok "Pre-flight checks passed"

# --- Step 1: Destroy existing resources ---
if [ "$SKIP_DESTROY" = false ]; then
  ui_step_begin "Destroy existing resources"
  ui_info "Tearing down previous deployment..."
  databricks bundle destroy --auto-approve 2>&1 | tail -5
  ui_ok "Resources destroyed"

  ui_info "Waiting for app '${APP_NAME}' to be fully deleted..."
  MAX_DELETE_WAIT=180
  DELETE_WAITED=0
  while [ $DELETE_WAITED -lt $MAX_DELETE_WAIT ]; do
    APP_EXISTS=$(databricks apps get "$APP_NAME" 2>&1 || true)
    if echo "$APP_EXISTS" | grep -qi "does not exist\|not found\|RESOURCE_DOES_NOT_EXIST\|404"; then
      break
    fi
    APP_STATE=$(echo "$APP_EXISTS" | jq -r '.app_status.state // empty' 2>/dev/null || true)
    if [ "$APP_STATE" = "DELETED" ]; then
      break
    fi
    sleep 10
    DELETE_WAITED=$((DELETE_WAITED + 10))
    ui_progress "$DELETE_WAITED" "$MAX_DELETE_WAIT" "Deleting"
  done
  ui_progress_done

  if [ $DELETE_WAITED -ge $MAX_DELETE_WAIT ]; then
    ui_warn "Deletion wait timed out after ${MAX_DELETE_WAIT}s — proceeding anyway"
  else
    ui_ok "App fully deleted (${DELETE_WAITED}s)"
  fi
else
  ui_step_begin "Destroy existing resources"
  ui_warn "Skipped (--no-destroy)"
fi

# --- Step 2: Deploy the bundle ---
ui_step_begin "Deploy DABs bundle"
ui_info "Provisioning Lakebase project and app definition..."

DEPLOY_ATTEMPTS=0
MAX_DEPLOY_ATTEMPTS=3
while [ $DEPLOY_ATTEMPTS -lt $MAX_DEPLOY_ATTEMPTS ]; do
  DEPLOY_OUTPUT=$(databricks bundle deploy 2>&1) && break
  DEPLOY_ATTEMPTS=$((DEPLOY_ATTEMPTS + 1))
  if echo "$DEPLOY_OUTPUT" | grep -qi "already exists"; then
    ui_warn "App still exists — retrying in 30s ($DEPLOY_ATTEMPTS/$MAX_DEPLOY_ATTEMPTS)..."
    sleep 30
  else
    echo "$DEPLOY_OUTPUT" | tail -10
    error "Bundle deploy failed with unexpected error"
  fi
done
if [ $DEPLOY_ATTEMPTS -ge $MAX_DEPLOY_ATTEMPTS ]; then
  echo "$DEPLOY_OUTPUT" | tail -10
  error "Bundle deploy failed after $MAX_DEPLOY_ATTEMPTS attempts — try again in a minute."
fi
echo "$DEPLOY_OUTPUT" | tail -5
ui_ok "Bundle deployed"

# --- Step 3: Wait for Lakebase database to be ready ---
ui_step_begin "Wait for Lakebase database"
ui_info "Branch: ${LAKEBASE_PROJECT}/${LAKEBASE_BRANCH}"

MAX_WAIT=180
WAITED=0
BRANCH_STATUS="UNKNOWN"
while [ $WAITED -lt $MAX_WAIT ]; do
  BRANCH_STATUS=$(databricks postgres list-branches "projects/${LAKEBASE_PROJECT}" --output json 2>/dev/null | \
    jq -r ".[] | select(.branch_id == \"${LAKEBASE_BRANCH}\") | .status.current_state // \"UNKNOWN\"" 2>/dev/null || echo "NOT_FOUND")

  if [ "$BRANCH_STATUS" = "READY" ]; then
    ui_progress "$MAX_WAIT" "$MAX_WAIT" "Lakebase"
    ui_progress_done
    ui_ok "Lakebase branch is ready"
    break
  fi

  sleep 10
  WAITED=$((WAITED + 10))
  ui_progress "$WAITED" "$MAX_WAIT" "Lakebase (${BRANCH_STATUS})"
done
ui_progress_done

if [ $WAITED -ge $MAX_WAIT ]; then
  ui_warn "Timed out waiting for Lakebase (last state: ${BRANCH_STATUS})"
  ui_warn "Proceeding — grant step may fail if database isn't ready"
fi

# --- Step 4: Grant permissions to app service principal ---
ui_step_begin "Grant schema permissions"

APP_INFO=$(databricks apps get "$APP_NAME" --output json 2>/dev/null)
SP_CLIENT_ID=$(echo "$APP_INFO" | jq -r '.service_principal_client_id // empty')
[ -z "$SP_CLIENT_ID" ] && error "Could not find service principal for app '${APP_NAME}'"

ENDPOINT_PATH="projects/${LAKEBASE_PROJECT}/branches/${LAKEBASE_BRANCH}/endpoints/primary"
ui_detail "Service principal  ${SP_CLIENT_ID}"
ui_detail "Endpoint           ${ENDPOINT_PATH}"
ui_info "Running GRANT ALL ON SCHEMA ${SCHEMA_NAME}..."

if ! databricks psql "$ENDPOINT_PATH" -- \
  -d "${DB_NAME}" \
  -c "GRANT ALL ON SCHEMA ${SCHEMA_NAME} TO \"${SP_CLIENT_ID}\";"; then
  ui_warn "GRANT failed — app may lack CREATE permission on public schema"
  ui_detail "Manual fix: databricks psql ${ENDPOINT_PATH} -- -d ${DB_NAME} -c 'GRANT ALL ON SCHEMA public TO \"${SP_CLIENT_ID}\";'"
fi
ui_ok "Permissions granted"

# --- Step 5: Start compute, deploy code, and wait for the app ---
ui_step_begin "Start app and deploy code"
ui_info "Starting compute and pushing source (may take several minutes)..."
printf '\n'

if ! databricks bundle run medplum_server; then
  error "Failed to start app. Check logs: databricks apps get-logs ${APP_NAME}"
fi

printf '\n'
ui_ok "App started and code deployed"

# --- Step 6: Verify app is healthy ---
ui_step_begin "Verify app health"

APP_JSON=$(databricks apps get "$APP_NAME" --output json 2>/dev/null || echo "{}")
APP_STATE=$(echo "$APP_JSON" | jq -r '.app_status.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
COMPUTE_STATE=$(echo "$APP_JSON" | jq -r '.compute_status.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

[ "$COMPUTE_STATE" = "STOPPED" ] && error "Compute still stopped. Check: databricks apps get ${APP_NAME}"
[ "$APP_STATE" = "CRASHED" ] || [ "$APP_STATE" = "FAILED" ] && \
  error "App crashed after startup. Check logs: databricks apps get-logs ${APP_NAME}"

if [ "$APP_STATE" != "RUNNING" ]; then
  ui_info "Current state: app=${APP_STATE}, compute=${COMPUTE_STATE} — waiting..."
  MAX_APP_WAIT=300
  APP_WAITED=0

  while [ $APP_WAITED -lt $MAX_APP_WAIT ]; do
    APP_JSON=$(databricks apps get "$APP_NAME" --output json 2>/dev/null || echo "{}")
    APP_STATE=$(echo "$APP_JSON" | jq -r '.app_status.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
    COMPUTE_STATE=$(echo "$APP_JSON" | jq -r '.compute_status.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

    if [ "$APP_STATE" = "RUNNING" ]; then
      ui_progress "$MAX_APP_WAIT" "$MAX_APP_WAIT" "Health"
      ui_progress_done
      ui_ok "App is running"
      break
    fi

    [ "$APP_STATE" = "CRASHED" ] || [ "$APP_STATE" = "FAILED" ] && \
      error "App crashed. Check logs: databricks apps get-logs ${APP_NAME}"
    [ "$COMPUTE_STATE" = "STOPPED" ] && \
      error "Compute stopped unexpectedly. Check logs: databricks apps get-logs ${APP_NAME}"

    sleep 10
    APP_WAITED=$((APP_WAITED + 10))
    ui_progress "$APP_WAITED" "$MAX_APP_WAIT" "Health (${APP_STATE})"
  done
  ui_progress_done

  if [ $APP_WAITED -ge $MAX_APP_WAIT ]; then
    ui_warn "Timed out waiting for RUNNING (last state: ${APP_STATE})"
    ui_detail "databricks apps get ${APP_NAME}"
    ui_detail "databricks apps get-logs ${APP_NAME}"
  fi
else
  ui_detail "app=${APP_STATE}, compute=${COMPUTE_STATE}"
  ui_ok "App is running"
fi

# --- Done ---
APP_URL=$(databricks apps get "$APP_NAME" --output json 2>/dev/null | jq -r '.url // "unknown"')
ui_success_box "$APP_URL"
