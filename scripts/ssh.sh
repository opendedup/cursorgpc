#!/usr/bin/env bash
# SSH into a worker through IAP TCP forwarding. Workers have no external IP.
#
# Usage:
#   scripts/ssh.sh                       # first instance in the group
#   scripts/ssh.sh cursor-worker-abcd    # a specific instance
#   scripts/ssh.sh '' 'systemctl status cursor-worker'
set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require gcloud

INSTANCE="${1:-}"
COMMAND="${2:-}"

[[ -n "$INSTANCE" ]] || INSTANCE="$(first_instance)"
[[ -n "$INSTANCE" ]] || die "no worker instances found in $(mig_name)"

ZONE="$(instance_zone "$INSTANCE")"
[[ -n "$ZONE" ]] || die "could not determine the zone of ${INSTANCE}"

args=(compute ssh "$INSTANCE" --project="$(project_id)" --zone="$ZONE" --tunnel-through-iap)
[[ -n "$COMMAND" ]] && args+=(--command "$COMMAND")

exec gcloud "${args[@]}"
