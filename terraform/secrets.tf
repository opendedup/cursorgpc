# The secret is created empty. The key value is added out of band so it never
# passes through Terraform state or a .tfvars file.
resource "google_secret_manager_secret" "api_key" {
  count = var.create_secret ? 1 : 0

  project   = var.project_id
  secret_id = var.cursor_api_key_secret_id
  labels    = var.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}
