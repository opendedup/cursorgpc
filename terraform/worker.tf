data "google_compute_image" "worker" {
  project = split("/", var.boot_image)[0]
  family  = split("/", var.boot_image)[1]

  depends_on = [google_project_service.required]
}

# /healthz reports whether the outbound connection to Cursor's cloud is up. It
# stays healthy while a session runs, so autohealing never reaps a busy worker.
# (/readyz intentionally flips to 503 when a session claims the worker, which is
# why it must not be used here.)
resource "google_compute_health_check" "worker" {
  count = var.enable_autohealing ? 1 : 0

  project             = var.project_id
  name                = "${var.name_prefix}-connected"
  description         = "Checks that a worker is connected to Cursor's cloud."
  check_interval_sec  = 30
  timeout_sec         = 10
  healthy_threshold   = 1
  unhealthy_threshold = 3

  http_health_check {
    port         = var.management_port
    request_path = "/healthz"
  }
}

resource "google_compute_instance_template" "worker" {
  project     = var.project_id
  name_prefix = "${var.name_prefix}-"
  description = "Cursor self-hosted Cloud Agent worker."
  region      = var.region

  machine_type   = var.machine_type
  can_ip_forward = false
  tags           = [local.network_tag]
  labels         = var.labels

  disk {
    source_image = data.google_compute_image.worker.self_link
    auto_delete  = true
    boot         = true
    disk_size_gb = var.boot_disk_size_gb
    disk_type    = var.boot_disk_type
    labels       = var.labels
  }

  network_interface {
    network            = local.network_name
    subnetwork         = local.subnetwork_name
    subnetwork_project = var.project_id

    dynamic "access_config" {
      for_each = var.assign_public_ip ? [1] : []
      content {}
    }
  }

  service_account {
    email = google_service_account.worker.email
    # Access is bounded by the IAM roles granted to the service account.
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    startup-script         = local.startup_script
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  scheduling {
    provisioning_model          = var.use_spot ? "SPOT" : "STANDARD"
    preemptible                 = var.use_spot
    automatic_restart           = !var.use_spot
    on_host_maintenance         = var.use_spot ? "TERMINATE" : "MIGRATE"
    instance_termination_action = var.use_spot ? "DELETE" : null
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_region_instance_group_manager" "worker" {
  project            = var.project_id
  name               = "${var.name_prefix}-mig"
  region             = var.region
  base_instance_name = var.name_prefix
  target_size        = var.worker_count

  distribution_policy_zones        = local.zones
  distribution_policy_target_shape = "EVEN"

  version {
    name              = "primary"
    instance_template = google_compute_instance_template.worker.self_link
  }

  named_port {
    name = "management"
    port = var.management_port
  }

  dynamic "auto_healing_policies" {
    for_each = var.enable_autohealing ? [1] : []

    content {
      health_check      = google_compute_health_check.worker[0].id
      initial_delay_sec = var.autohealing_initial_delay_sec
    }
  }

  update_policy {
    type                         = "PROACTIVE"
    instance_redistribution_type = "PROACTIVE"
    minimal_action               = "REPLACE"
    # Workers are stateless and fungible, so replace in place instead of surging
    # extra 16-vCPU instances that could exceed regional CPU quota.
    max_surge_fixed       = 0
    max_unavailable_fixed = length(local.zones)
  }
}
