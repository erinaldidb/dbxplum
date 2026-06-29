#!/bin/bash
set -e

echo "Medplum server not built yet."
echo "Run Phase 4 (Medplum Server Build & Adaptation) to populate this app."
echo "Listening on port ${DATABRICKS_APP_PORT:-8103} as placeholder..."

# Keep the process alive so the app doesn't crash-loop during validation
while true; do sleep 3600; done
