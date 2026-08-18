SHELL := /usr/bin/env bash
TF_DIR ?= terraform
TF := terraform -chdir=$(TF_DIR)

export TF_DIR

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show the available targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: init
init: ## Initialize Terraform
	$(TF) init

.PHONY: fmt
fmt: ## Format Terraform files
	$(TF) fmt -recursive

.PHONY: validate
validate: ## Check formatting and validate the configuration
	$(TF) fmt -check -recursive
	$(TF) validate

.PHONY: lint
lint: ## Syntax-check the bash helpers and operator scripts
	@for f in $(TF_DIR)/files/* scripts/*.sh; do bash -n "$$f" && echo "ok $$f"; done
	@command -v shellcheck >/dev/null 2>&1 \
		&& shellcheck $(TF_DIR)/files/* scripts/*.sh \
		|| echo "shellcheck not installed, skipping"

.PHONY: plan
plan: ## Show the planned changes
	$(TF) plan

.PHONY: apply
apply: ## Create or update the worker fleet
	$(TF) apply

.PHONY: destroy
destroy: ## Tear down the worker fleet
	$(TF) destroy

.PHONY: output
output: ## Show Terraform outputs
	$(TF) output

.PHONY: api-key
api-key: ## Store the Cursor service account API key in Secret Manager
	scripts/set-api-key.sh

.PHONY: status
status: ## Show fleet status from GCE and, with CURSOR_API_KEY, from Cursor
	scripts/fleet-status.sh

.PHONY: logs
logs: ## Read recent worker logs from Cloud Logging
	scripts/logs.sh recent

.PHONY: follow
follow: ## Tail the worker journal on one instance over IAP
	scripts/logs.sh follow

.PHONY: bootstrap-log
bootstrap-log: ## Show the bootstrap log of one worker
	scripts/logs.sh bootstrap

.PHONY: ssh
ssh: ## SSH into a worker over IAP
	scripts/ssh.sh

.PHONY: vnc
vnc: ## Tunnel a worker's virtual display to localhost:5900 (needs install_desktop)
	scripts/vnc.sh

.PHONY: restart
restart: ## Restart the worker service on every instance
	scripts/restart-workers.sh --soft

.PHONY: replace
replace: ## Rolling-replace every worker VM
	scripts/restart-workers.sh

.PHONY: scale
scale: ## Resize the fleet, for example: make scale N=3
	scripts/scale.sh $(N)
