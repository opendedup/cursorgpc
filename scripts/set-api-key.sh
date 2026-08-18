#!/usr/bin/env bash
# Store a Cursor service account API key in Secret Manager, where the workers
# read it from at every start. Adding a new version rotates the key; workers pick
# it up the next time the service restarts.
#
# Usage:
#   CURSOR_API_KEY=key_... scripts/set-api-key.sh
#   scripts/set-api-key.sh                # prompts without echoing
set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require gcloud

PROJECT="$(project_id)"
SECRET="$(secret_id)"

if [[ -z "${CURSOR_API_KEY:-}" ]]; then
  read -r -s -p "Cursor service account API key: " CURSOR_API_KEY
  echo
fi

[[ -n "$CURSOR_API_KEY" ]] || die "no API key provided"

if [[ "$CURSOR_API_KEY" =~ [[:space:]] ]]; then
  die "the key contains whitespace; it was probably copied with a trailing newline"
fi

# Only service account keys can manage pool worker capacity, so a successful
# fleet-management call is a reliable way to reject the wrong key type before it
# reaches the workers, where the failure is much harder to read. Machine mode
# expects a personal user key, which this endpoint rejects by design.
if [[ "${SKIP_VERIFY:-0}" != "1" ]] && command -v curl >/dev/null 2>&1; then
  status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --url "https://api.cursor.com/v0/private-workers/summary" \
    -u "${CURSOR_API_KEY}:" || echo 000)"

  case "$status" in
  200)
    echo "Verified: the key can manage pool worker capacity, so it works in either worker mode."
    ;;
  401 | 403)
    if [[ "$(worker_mode)" == "machine" ]]; then
      echo "Note: this is not a service account key, which is expected for worker_mode = \"machine\"."
    else
      die "Cursor rejected the key for pool fleet management (HTTP ${status}). Pool workers need a service account key from Dashboard > Settings > API Keys > Service Accounts, on an Enterprise plan; user, personal, team, and organization keys are rejected. Either use a service account key, or set worker_mode = \"machine\" to run My Machines workers with this key. Set SKIP_VERIFY=1 to store it anyway."
    fi
    ;;
  000)
    echo "warning: could not reach api.cursor.com to verify the key; storing it unverified" >&2
    ;;
  *)
    echo "warning: unexpected HTTP ${status} while verifying the key; storing it anyway" >&2
    ;;
  esac
fi

if ! gcloud secrets describe "$SECRET" --project="$PROJECT" >/dev/null 2>&1; then
  die "secret ${SECRET} does not exist in ${PROJECT}; run terraform apply first"
fi

printf '%s' "$CURSOR_API_KEY" |
  gcloud secrets versions add "$SECRET" --project="$PROJECT" --data-file=-

echo "Stored a new version of ${SECRET} in ${PROJECT}."
echo "Restart the workers to pick it up: scripts/restart-workers.sh"
