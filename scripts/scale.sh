#!/usr/bin/env bash
# Resize the worker fleet.
#
# This changes the managed instance group directly, which is useful for a quick
# scale-up. Update worker_count in terraform.tfvars to make it permanent,
# otherwise the next `terraform apply` resets the size.
#
# Usage: scripts/scale.sh <count>
set -euo pipefail

# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require gcloud

SIZE="${1:?usage: scripts/scale.sh <count>}"

[[ "$SIZE" =~ ^[0-9]+$ ]] || die "count must be a non-negative integer"
if ((SIZE > 50)); then
  die "Cursor allows at most 50 workers per team; contact Cursor to raise the cap"
fi

gcloud compute instance-groups managed resize "$(mig_name)" \
  --project="$(project_id)" \
  --region="$(region)" \
  --size="$SIZE"

echo "Resized $(mig_name) to ${SIZE}. Remember to set worker_count = ${SIZE} in terraform.tfvars."
