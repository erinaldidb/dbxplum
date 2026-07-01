#!/usr/bin/env bash
# build-medplum.sh — Build Medplum server bundle and frontend from upstream source
#
# Clones https://github.com/medplum/medplum, builds @medplum/server and @medplum/app,
# and installs the artifacts into apps/medplum-server/.
#
# Usage:
#   ./build-medplum.sh                         # latest GitHub release tag
#   ./build-medplum.sh --version v5.1.22       # exact tag
#   ./build-medplum.sh --version v5.1          # latest tag matching prefix
#   ./build-medplum.sh --keep-src              # reuse medplum-src/ checkout between runs
#
set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_DIR="$SCRIPT_DIR/apps/medplum-server"
SRC_DIR="$SCRIPT_DIR/medplum-src"
MEDPLUM_REPO="https://github.com/medplum/medplum.git"

VERSION_SPEC="latest"
KEEP_SRC=false

usage() {
  cat <<EOF
Usage: $0 [options]

Build Medplum server and frontend from upstream source into apps/medplum-server/.

Options:
  --version <tag|prefix>   Release tag (e.g. v5.1.22) or prefix (e.g. v5.1).
                           Defaults to the latest GitHub release.
  --keep-src               Reuse an existing medplum-src/ checkout when possible.
  -h, --help               Show this help.

Examples:
  $0
  $0 --version v5.1.22
  $0 --version 5.1
EOF
}

log() { printf '  › %s\n' "$*"; }
ok() { printf '  ✓ %s\n' "$*"; }
die() { printf '  ✗ %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [ $# -ge 2 ] || die "--version requires a value"
      VERSION_SPEC="$2"
      shift 2
      ;;
    --keep-src) KEEP_SRC=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

printf '\n  Building Medplum artifacts (spec: %s)\n\n' "$VERSION_SPEC"

# --- Preflight ---
command -v git >/dev/null 2>&1 || die "git not found"
command -v node >/dev/null 2>&1 || die "node not found (Node 22+ required)"
command -v npm >/dev/null 2>&1 || die "npm not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
command -v curl >/dev/null 2>&1 || die "curl not found"

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 22 ] || die "Node 22+ required (found $(node -v))"

# --- Resolve version tag ---
normalize_tag() {
  local v="$1"
  case "$v" in
    v*) printf '%s' "$v" ;;
    *) printf 'v%s' "$v" ;;
  esac
}

resolve_version_tag() {
  local spec="$1"

  if [ "$spec" = "latest" ]; then
    curl -fsSL "https://api.github.com/repos/medplum/medplum/releases/latest" \
      | jq -r '.tag_name // empty' \
      | grep -E '^v[0-9]' \
      || die "Could not resolve latest Medplum release tag from GitHub"
    return
  fi

  local normalized prefix
  normalized="$(normalize_tag "$spec")"

  if git ls-remote --tags "$MEDPLUM_REPO" "refs/tags/${normalized}" 2>/dev/null | grep -q .; then
    printf '%s' "$normalized"
    return
  fi

  prefix="$normalized"
  git ls-remote --tags "$MEDPLUM_REPO" \
    | awk -F/ '{print $3}' \
    | grep -E "^${prefix}" \
    | sort -V \
    | tail -1
}

MEDPLUM_TAG="$(resolve_version_tag "$VERSION_SPEC")"
[ -n "$MEDPLUM_TAG" ] || die "No Medplum tag found for spec: $VERSION_SPEC"

MEDPLUM_VERSION="${MEDPLUM_TAG#v}"
log "Resolved tag: $MEDPLUM_TAG (version $MEDPLUM_VERSION)"

# --- Clone or update source ---
if [ -d "$SRC_DIR/.git" ] && [ "$KEEP_SRC" = true ]; then
  log "Updating existing checkout in medplum-src/"
  git -C "$SRC_DIR" fetch --depth 1 origin "refs/tags/${MEDPLUM_TAG}:refs/tags/${MEDPLUM_TAG}" 2>/dev/null \
    || git -C "$SRC_DIR" fetch --tags origin
  git -C "$SRC_DIR" checkout -f "$MEDPLUM_TAG"
else
  log "Cloning $MEDPLUM_REPO at $MEDPLUM_TAG"
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$MEDPLUM_TAG" "$MEDPLUM_REPO" "$SRC_DIR"
fi

GIT_HASH="$(git -C "$SRC_DIR" rev-parse --short=7 HEAD)"

# --- Install and build upstream ---
log "Installing upstream dependencies (npm ci)..."
( cd "$SRC_DIR" && npm ci )

log "Configuring frontend build (.env placeholder; baseUrl patched after build)..."
printf 'MEDPLUM_BASE_URL=/\n' > "$SRC_DIR/packages/app/.env"

log "Building @medplum/server and @medplum/app..."
( cd "$SRC_DIR" && npm run build:fast )

[ -f "$SRC_DIR/packages/server/dist/index.js" ] || die "Server build output missing"
[ -f "$SRC_DIR/packages/app/dist/index.html" ] || die "App build output missing"

# --- Bundle server into a single ESM file ---
log "Bundling server into apps/medplum-server/server/index.mjs..."
mkdir -p "$APP_DIR/server"
node "$APP_DIR/scripts/bundle-server.mjs" "$SRC_DIR" "$APP_DIR/server/index.mjs"

# --- Sync runtime dependencies (externalized from the bundle) ---
log "Syncing externalized server dependencies into package.json..."
TMP_PKG="$(mktemp)"
jq -s '
  .[1].dependencies as $server |
  ($server | to_entries | map(select(
    .key == "bcrypt" or
    .key == "pdfmake" or
    ((.key | startswith("@opentelemetry/")) and .key != "@opentelemetry/propagator-aws-xray") or
    (.key | startswith("@appsignal/"))
  )) | from_entries) as $external |
  {
    name: "medplum-server",
    version: "1.0.0",
    private: true,
    type: "module",
    engines: { node: ">=22.0.0" },
    scripts: {
      build: "node scripts/build.js",
      start: "node start.js"
    },
    dependencies: ({ dotenv: "^16.4.0" } + $external)
  }
' "$APP_DIR/package.json" "$SRC_DIR/packages/server/package.json" > "$TMP_PKG"
mv "$TMP_PKG" "$APP_DIR/package.json"
log "Run npm install in apps/medplum-server/ locally (package-lock.json is not committed)."

# --- FHIR definition files ---
log "Copying FHIR R4 definitions..."
rm -rf "$APP_DIR/server/fhir"
mkdir -p "$APP_DIR/server/fhir/r4"
cp -R "$SRC_DIR/packages/definitions/dist/fhir/r4/." "$APP_DIR/server/fhir/r4/"

# Optional: gzip large JSON payloads (start.js decompresses on first boot)
for json in "$APP_DIR/server/fhir/r4"/*.json; do
  [ -f "$json" ] || continue
  gzip -9 -c "$json" > "${json}.gz"
  rm -f "$json"
done

# --- pdfmake / fontkit trie data required at runtime ---
log "Copying fontkit trie files..."
cp "$SRC_DIR/node_modules/@foliojs-fork/fontkit/"{data,indic,use}.trie "$APP_DIR/server/"
cp "$SRC_DIR/node_modules/@foliojs-fork/linebreak/src/classes.trie" "$APP_DIR/server/"

# --- Frontend static assets ---
log "Installing frontend into apps/medplum-server/public/..."
rm -rf "$APP_DIR/public"
mkdir -p "$APP_DIR/public"
cp -R "$SRC_DIR/packages/app/dist/." "$APP_DIR/public/"

# Inject Databricks token-relay script and version metadata into index.html
APP_JS="$(find "$APP_DIR/public/assets" -maxdepth 1 -name 'index-*.js' ! -name '*.map' | head -1)"
APP_CSS="$(find "$APP_DIR/public/assets" -maxdepth 1 -name 'index-*.css' | head -1)"
[ -n "$APP_JS" ] && [ -n "$APP_CSS" ] || die "Could not locate built frontend assets"

log "Patching frontend baseUrl for same-origin deployment..."
python3 - "$APP_JS" <<'PY'
import sys
from pathlib import Path

js_path = Path(sys.argv[1])
js = js_path.read_text()
needle = "{baseUrl:`/`,"
replacement = "{baseUrl:window.location.origin+`/`,"
if needle not in js:
    raise SystemExit(f"ERROR: expected frontend config marker not found in {js_path}")
js_path.write_text(js.replace(needle, replacement, 1))
PY

APP_JS_HREF="/assets/$(basename "$APP_JS")"
APP_CSS_HREF="/assets/$(basename "$APP_CSS")"
VERSION_META="${MEDPLUM_VERSION}-${GIT_HASH}"

python3 - "$APP_DIR/public/index.html" "$VERSION_META" "$APP_JS_HREF" "$APP_CSS_HREF" <<'PY'
import sys
from pathlib import Path

index_path, version_meta, js_href, css_href = sys.argv[1:5]
html = Path(index_path).read_text()

relay = """    <script>
      // Token relay: Databricks gateway strips Authorization headers.
      // Mirror the Medplum access token to a cookie so the proxy can inject it.
      (function() {
        const COOKIE_NAME = '__medplum_token';
        function saveToken(token) {
          document.cookie = COOKIE_NAME + '=' + encodeURIComponent(token) + '; path=/; SameSite=Lax; Secure';
        }
        const origFetch = window.fetch;
        window.fetch = function(input, init) {
          if (init && init.headers) {
            let authValue = null;
            if (init.headers instanceof Headers) {
              authValue = init.headers.get('Authorization');
            } else if (Array.isArray(init.headers)) {
              const pair = init.headers.find(([k]) => k.toLowerCase() === 'authorization');
              if (pair) authValue = pair[1];
            } else if (typeof init.headers === 'object') {
              authValue = init.headers['Authorization'] || init.headers['authorization'];
            }
            if (authValue && authValue.startsWith('Bearer ')) {
              saveToken(authValue.slice(7));
            }
          }
          return origFetch.apply(this, arguments);
        };
        const origSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
        XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
          if (name.toLowerCase() === 'authorization' && typeof value === 'string' && value.startsWith('Bearer ')) {
            saveToken(value.slice(7));
          }
          return origSetRequestHeader.call(this, name, value);
        };
      })();
    </script>"""

import re
html = re.sub(
    r'<meta name="medplum-version" content="[^"]*" */?>',
    f'<meta name="medplum-version" content="{version_meta}" />',
    html,
    count=1,
)
html = re.sub(
    r'<script type="module" crossorigin src="[^"]+"></script>',
    relay + f'\n    <script type="module" crossorigin src="{js_href}"></script>',
    html,
    count=1,
)
html = re.sub(
    r'<link rel="stylesheet" crossorigin href="[^"]+">',
    f'<link rel="stylesheet" crossorigin href="{css_href}">',
    html,
    count=1,
)
Path(index_path).write_text(html)
PY

# --- Update runtime version in start.js ---
log "Updating MEDPLUM_VERSION in start.js..."
if grep -q "process.env.MEDPLUM_VERSION" "$APP_DIR/start.js"; then
  sed -i.bak "s/process.env.MEDPLUM_VERSION = '[^']*'/process.env.MEDPLUM_VERSION = '${MEDPLUM_VERSION}'/" "$APP_DIR/start.js"
  rm -f "$APP_DIR/start.js.bak"
else
  die "Could not find MEDPLUM_VERSION assignment in start.js"
fi

printf '\n'
ok "Medplum $MEDPLUM_VERSION ($GIT_HASH) built successfully"
printf '      Server bundle : apps/medplum-server/server/index.mjs\n'
printf '      Frontend      : apps/medplum-server/public/\n'
printf '      FHIR data     : apps/medplum-server/server/fhir/r4/\n'
printf '\n'
