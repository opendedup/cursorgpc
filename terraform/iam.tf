resource "google_service_account" "worker" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-sa"
  display_name = "Cursor self-hosted Cloud Agent worker"
  description  = "Identity for GCE workers that execute Cursor Cloud Agent tool calls."

  depends_on = [google_project_service.required]
}

locals {
  worker_project_roles = concat(
    [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
    ],
    var.install_ops_agent ? ["roles/stackdriver.resourceMetadata.writer"] : [],
    var.additional_worker_roles,
  )
}

resource "google_project_iam_member" "worker" {
  for_each = toset(local.worker_project_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.worker.email}"
}

# Secret access is granted per secret rather than project-wide.
resource "google_secret_manager_secret_iam_member" "api_key" {
  project   = var.project_id
  secret_id = var.cursor_api_key_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.worker.email}"

  depends_on = [google_secret_manager_secret.api_key]
}

resource "google_secret_manager_secret_iam_member" "git_credentials" {
  count = var.git_credentials_secret_id != "" ? 1 : 0

  project   = var.project_id
  secret_id = var.git_credentials_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.worker.email}"
}

# Optional operator access: IAP tunnelling plus OS Login on the workers.
resource "google_project_iam_member" "iap_tunnel" {
  for_each = toset(var.iap_ssh_members)

  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = each.value
}

resource "google_project_iam_member" "os_login" {
  for_each = toset(var.iap_ssh_members)

  project = var.project_id
  role    = "roles/compute.osAdminLogin"
  member  = each.value
}
