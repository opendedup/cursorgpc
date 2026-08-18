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

case "$CURSOR_API_KEY" in
key_*) ;;
*) echo "warning: the key does not start with 'key_'; pool workers reject user, personal, team, and organization keys" >&2 ;;
esac

if ! gcloud secrets describe "$SECRET" --project="$PROJECT" >/dev/null 2>&1; then
  die "secret ${SECRET} does not exist in ${PROJECT}; run terraform apply first"
fi

printf '%s' "$CURSOR_API_KEY" |
  gcloud secrets versions add "$SECRET" --project="$PROJECT" --data-file=-

echo "Stored a new version of ${SECRET} in ${PROJECT}."
echo "Restart the workers to pick it up: scripts/restart-workers.sh"
