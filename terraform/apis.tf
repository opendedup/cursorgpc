locals {
  required_apis = [
    "compute.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "iap.googleapis.com",
  ]
}

resource "google_project_service" "required" {
  for_each = var.enable_apis ? toset(local.required_apis) : toset([])

  project = var.project_id
  service = each.value

  # Leaving APIs enabled on destroy avoids breaking unrelated workloads in the project.
  disable_on_destroy = false
}
