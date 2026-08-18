#!/usr/bin/env bash
# Cloud Agent bootstrap for cursorgpc.
#
# Installs the toolchain this Terraform + Bash IaC repo needs to run its
# canonical checks (see .github/workflows/checks.yml and the Makefile):
#   - Terraform 1.9.8 (pinned to match CI's hashicorp/setup-terraform)
#   - shellcheck    (bash linting)
#   - google-cloud-cli (gcloud, used by the operator scripts in scripts/)
#   - make / bash / curl / unzip (task runner and helpers)
#
# The script is idempotent and non-interactive: it can run on a fresh image or
# re-run against a warm/cached workspace without side effects. It must also stay
# safe before the setup PR is merged, when only this .cursor/ config exists and
# the terraform/ sources are absent, so the terraform init step is guarded.
set -euo pipefail

TERRAFORM_VERSION="1.9.8"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '[cursor-install] %s\n' "$*"; }

ensure_apt_packages() {
  local pkg missing=()
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if ((${#missing[@]})); then
    log "installing apt packages: ${missing[*]}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
  else
    log "apt packages already present: $*"
  fi
}

install_terraform() {
  if command -v terraform >/dev/null 2>&1 \
    && terraform version | head -1 | grep -q "v${TERRAFORM_VERSION}\b"; then
    log "terraform ${TERRAFORM_VERSION} already installed"
    return
  fi

  local tmp base zip
  tmp="$(mktemp -d)"
  base="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"
  zip="terraform_${TERRAFORM_VERSION}_linux_amd64.zip"

  log "downloading terraform ${TERRAFORM_VERSION}"
  curl -fsSL "${base}/${zip}" -o "${tmp}/${zip}"
  curl -fsSL "${base}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" -o "${tmp}/sums"
  ( cd "$tmp" && grep " ${zip}$" sums | sha256sum -c - )
  unzip -o "${tmp}/${zip}" -d "$tmp" >/dev/null
  sudo install -m 0755 "${tmp}/terraform" /usr/local/bin/terraform
  rm -rf "$tmp"
  log "terraform installed: $(terraform version | head -1)"
}

install_gcloud() {
  if command -v gcloud >/dev/null 2>&1; then
    log "gcloud already installed"
    return
  fi
  log "installing google-cloud-cli"
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y google-cloud-cli
}

prefetch_terraform_providers() {
  if [[ -d "${REPO_ROOT}/terraform" ]] && compgen -G "${REPO_ROOT}/terraform/*.tf" >/dev/null; then
    log "running terraform init (backend disabled) to fetch providers"
    terraform -chdir="${REPO_ROOT}/terraform" init -backend=false -input=false
  else
    log "no terraform/ sources present yet (setup PR unmerged); skipping terraform init"
  fi
}

ensure_apt_packages ca-certificates curl gnupg unzip make shellcheck apt-transport-https
install_terraform
install_gcloud
prefetch_terraform_providers

log "environment ready"
