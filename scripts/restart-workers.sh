#!/usr/bin/env bash
# Restart every worker so they re-read the API key, git credentials, and repos.
#
# Rolling restart replaces the VMs, which is the safest way to apply a new base
# image or bootstrap change. `--soft` only restarts the systemd service, which is
# faster and enough for a key rotation.
#
# Usage:
#   scripts/restart-workers.sh          # rolling replace of every worker
#   scripts/restart-workers.sh --soft   # restart cursor-worker.service in place
set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require gcloud

MODE="${1:-hard}"

if [[ "$MODE" == "--soft" ]]; then
  mapfile -t instances < <(gcloud compute instance-groups managed list-instances "$(mig_name)" \
    --project="$(project_id)" --region="$(region)" \
    --format='value(instance.basename())')

  ((${#instances[@]})) || die "no worker instances found in $(mig_name)"

  for instance in "${instances[@]}"; do
    echo "--- Restarting cursor-worker on ${instance}"
    "$(dirname "${BASH_SOURCE[0]}")/ssh.sh" "$instance" \
      'sudo systemctl restart cursor-worker && sudo systemctl --no-pager status cursor-worker'
  done
  exit 0
fi

echo "Rolling-replacing every worker in $(mig_name). In-flight agent sessions will be interrupted."
gcloud compute instance-groups managed rolling-action replace "$(mig_name)" \
  --project="$(project_id)" \
  --region="$(region)" \
  --max-surge=0 \
  --max-unavailable=100%
