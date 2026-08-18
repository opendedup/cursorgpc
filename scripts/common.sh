#!/usr/bin/env bash
# Shared helpers for the operator scripts. Values come from Terraform outputs
# when available, and fall back to environment variables or defaults.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${TF_DIR:-${REPO_ROOT}/terraform}"

die() {
  echo "error: $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

# tf_output <name> [fallback]
tf_output() {
  local name="$1" fallback="${2:-}" value=""

  if command -v terraform >/dev/null 2>&1 && [[ -d "${TF_DIR}/.terraform" ]]; then
    value="$(terraform -chdir="$TF_DIR" output -raw "$name" 2>/dev/null || true)"
  fi

  if [[ -z "$value" || "$value" == *"No outputs found"* ]]; then
    value="$fallback"
  fi

  printf '%s' "$value"
}

project_id() { printf '%s' "${PROJECT_ID:-$(tf_output project_id lennyisagoodboy)}"; }
region() { printf '%s' "${REGION:-$(tf_output region us-central1)}"; }
mig_name() { printf '%s' "${MIG_NAME:-$(tf_output instance_group_manager cursor-worker-mig)}"; }
secret_id() { printf '%s' "${SECRET_ID:-$(tf_output api_key_secret_id cursor-worker-api-key)}"; }

# Name of the first RUNNING instance in the managed instance group.
first_instance() {
  gcloud compute instance-groups managed list-instances "$(mig_name)" \
    --project="$(project_id)" \
    --region="$(region)" \
    --format='value(instance.basename())' \
    --limit=1
}

instance_zone() {
  local instance="$1"
  gcloud compute instances list \
    --project="$(project_id)" \
    --filter="name=${instance}" \
    --format='value(zone)' \
    --limit=1
}
