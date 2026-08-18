#!/usr/bin/env bash
# Show fleet state from both sides: the GCE managed instance group and Cursor's
# view of connected workers.
#
# Set CURSOR_API_KEY to the pool's service account key to include Cursor's view.
set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require gcloud

echo "=== GCE managed instance group: $(mig_name) ==="
gcloud compute instance-groups managed list-instances "$(mig_name)" \
  --project="$(project_id)" \
  --region="$(region)" \
  --format='table(instance.basename(), instanceStatus, currentAction, healthState())'

echo
echo "=== Instance group health ==="
gcloud compute instance-groups managed describe "$(mig_name)" \
  --project="$(project_id)" \
  --region="$(region)" \
  --format='yaml(targetSize, status, currentActions)'

if [[ -z "${CURSOR_API_KEY:-}" ]]; then
  echo
  echo "Set CURSOR_API_KEY to the pool's service account key to also query Cursor's fleet API."
  exit 0
fi

require curl

cursor_api() {
  local path="$1"
  curl --silent --show-error --request GET \
    --url "https://api.cursor.com/v0/private-workers${path}" \
    -u "${CURSOR_API_KEY}:"
}

pretty() {
  if command -v jq >/dev/null 2>&1; then
    jq .
  else
    cat
  fi
}

echo
echo "=== Cursor pools ==="
cursor_api "/pools?scope=team_pool" | pretty

echo
echo "=== Cursor workers ==="
cursor_api "?scope=team_pool&limit=50" | pretty

echo
echo "=== Cursor utilization summary ==="
cursor_api "/summary" | pretty
