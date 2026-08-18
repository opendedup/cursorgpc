data "google_compute_zones" "available" {
  project = var.project_id
  region  = var.region
  status  = "UP"

  depends_on = [google_project_service.required]
}

locals {
  zones = length(var.zones) > 0 ? var.zones : data.google_compute_zones.available.names

  network_name    = var.create_network ? google_compute_network.worker[0].name : var.network
  subnetwork_name = var.create_network ? google_compute_subnetwork.worker[0].name : var.subnetwork

  network_tag = "${var.name_prefix}-worker"

  worker_home      = "/home/${var.worker_user}"
  workspace_root   = "/home/${var.worker_user}/workspace"
  management_addr  = "0.0.0.0:${var.management_port}"
  service_agent_sa = google_service_account.worker.email

  # Every repo gets an explicit directory name so the bootstrap and the worker
  # agree on the --worker-dir paths.
  worker_repos = [
    for repo in var.worker_repos : {
      url    = repo.url
      name   = coalesce(repo.name, trimsuffix(basename(repo.url), ".git"))
      branch = coalesce(repo.branch, "")
    }
  ]

  # Non-secret worker configuration, delivered as a systemd EnvironmentFile.
  worker_env = merge(
    {
      CURSOR_GCP_PROJECT_ID              = var.project_id
      CURSOR_API_KEY_SECRET_ID           = var.cursor_api_key_secret_id
      CURSOR_GIT_CREDENTIALS_SECRET_ID   = var.git_credentials_secret_id
      CURSOR_WORKER_POOL_NAME            = var.worker_pool_name
      CURSOR_WORKER_IDLE_RELEASE_TIMEOUT = tostring(var.worker_idle_release_timeout)
      CURSOR_WORKER_LABELS_FILE          = "/etc/cursor/labels.json"
      CURSOR_WORKER_MANAGEMENT_ADDR      = local.management_addr
      CURSOR_WORKER_REPOS_FILE           = "/etc/cursor/repos.json"
      CURSOR_WORKER_RESET_MODE           = var.worker_reset_mode
      CURSOR_WORKER_WORKSPACE_ROOT       = local.workspace_root
      CURSOR_WORKER_VERBOSE              = var.worker_verbose ? "1" : "0"
    },
    var.worker_env,
  )

  startup_script = templatefile("${path.module}/templates/startup.sh.tftpl", {
    worker_user               = var.worker_user
    workspace_root            = local.workspace_root
    install_docker            = var.install_docker
    install_ops_agent         = var.install_ops_agent
    enable_prometheus_metrics = var.enable_prometheus_metrics && var.install_ops_agent
    management_port           = var.management_port
    extra_apt_packages        = join(" ", var.extra_apt_packages)
    extra_setup_script        = var.extra_setup_script
    # jsonencode quotes and escapes each value, which both systemd's
    # EnvironmentFile parser and `set -a; . file` in bash understand.
    worker_env_file    = join("\n", [for k, v in local.worker_env : "${k}=${jsonencode(v)}"])
    labels_json        = jsonencode(var.worker_labels)
    repos_json         = jsonencode(local.worker_repos)
    secret_script_b64  = base64encode(file("${path.module}/files/cursor-worker-secret"))
    prepare_script_b64 = base64encode(file("${path.module}/files/cursor-worker-prepare"))
    run_script_b64     = base64encode(file("${path.module}/files/cursor-worker-run"))
  })
}
