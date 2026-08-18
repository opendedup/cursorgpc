#!/usr/bin/env bash
# Forward a worker's virtual display to a local VNC port.
#
# Requires install_desktop = true. The VNC server on the worker listens on
# loopback only, so this SSH tunnel (itself gated by IAP and IAM) is the only way
# in. Connect a VNC client to localhost:<local port> while this runs.
#
# Usage:
#   scripts/vnc.sh                       # first instance, local port 5900
#   scripts/vnc.sh cursor-worker-abcd 5901
set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require gcloud

INSTANCE="${1:-}"
LOCAL_PORT="${2:-5900}"

[[ -n "$INSTANCE" ]] || INSTANCE="$(first_instance)"
[[ -n "$INSTANCE" ]] || die "no worker instances found in $(mig_name)"

ZONE="$(instance_zone "$INSTANCE")"
[[ -n "$ZONE" ]] || die "could not determine the zone of ${INSTANCE}"

echo "Forwarding ${INSTANCE}:5900 to localhost:${LOCAL_PORT}. Connect a VNC client to localhost:${LOCAL_PORT}."
echo "Press Ctrl-C to close the tunnel."

exec gcloud compute ssh "$INSTANCE" \
  --project="$(project_id)" \
  --zone="$ZONE" \
  --tunnel-through-iap \
  -- -N -L "${LOCAL_PORT}:localhost:5900"
