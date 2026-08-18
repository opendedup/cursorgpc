#!/usr/bin/env bash
# Read worker logs.
#
# Usage:
#   scripts/logs.sh              # recent worker + bootstrap logs from Cloud Logging
#   scripts/logs.sh follow       # tail the journal on one worker over IAP
#   scripts/logs.sh bootstrap    # bootstrap log of one worker
set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require gcloud

MODE="${1:-recent}"

case "$MODE" in
recent)
  gcloud logging read \
    'resource.type="gce_instance" AND (jsonPayload.SYSLOG_IDENTIFIER="cursor-worker" OR jsonPayload.SYSLOG_IDENTIFIER="cursor-worker-bootstrap" OR textPayload:"cursor-worker")' \
    --project="$(project_id)" \
    --freshness="${FRESHNESS:-1h}" \
    --limit="${LIMIT:-200}" \
    --format='table(timestamp, resource.labels.instance_id, jsonPayload.MESSAGE, textPayload)'
  ;;
follow)
  "$(dirname "${BASH_SOURCE[0]}")/ssh.sh" "${2:-}" \
    'sudo journalctl -u cursor-worker -n 200 -f'
  ;;
bootstrap)
  "$(dirname "${BASH_SOURCE[0]}")/ssh.sh" "${2:-}" \
    'sudo tail -n 300 /var/log/cursor-worker-bootstrap.log'
  ;;
*)
  die "unknown mode: ${MODE} (expected recent, follow, or bootstrap)"
  ;;
esac
