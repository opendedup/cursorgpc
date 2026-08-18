resource "google_compute_network" "worker" {
  count = var.create_network ? 1 : 0

  project                 = var.project_id
  name                    = "${var.name_prefix}-vpc"
  description             = "Egress-only network for Cursor self-hosted Cloud Agent workers."
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.required]
}

resource "google_compute_subnetwork" "worker" {
  count = var.create_network ? 1 : 0

  project                  = var.project_id
  name                     = "${var.name_prefix}-${var.region}"
  region                   = var.region
  network                  = google_compute_network.worker[0].id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  dynamic "log_config" {
    for_each = var.enable_flow_logs ? [1] : []

    content {
      aggregation_interval = "INTERVAL_10_MIN"
      flow_sampling        = 0.5
      metadata             = "INCLUDE_ALL_METADATA"
    }
  }
}

# Workers have no external IP, so all outbound traffic leaves through Cloud NAT.
resource "google_compute_router" "worker" {
  count = var.create_nat ? 1 : 0

  project = var.project_id
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = local.network_name
}

resource "google_compute_router_nat" "worker" {
  count = var.create_nat ? 1 : 0

  project                            = var.project_id
  name                               = "${var.name_prefix}-nat"
  region                             = var.region
  router                             = google_compute_router.worker[0].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Cursor's docs are explicit that workers need no inbound access. The only
# ingress opened here is for GCP-internal callers: health check probes and,
# optionally, IAP-tunnelled SSH for operators.
resource "google_compute_firewall" "health_checks" {
  count = var.enable_autohealing ? 1 : 0

  project     = var.project_id
  name        = "${var.name_prefix}-allow-health-checks"
  network     = local.network_name
  description = "Allow Google health check probes to reach the worker management endpoint."
  direction   = "INGRESS"
  priority    = 1000

  # Documented probe ranges for Google Cloud health checks.
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = [local.network_tag]

  allow {
    protocol = "tcp"
    ports    = [tostring(var.management_port)]
  }
}

resource "google_compute_firewall" "iap_ssh" {
  count = var.enable_iap_ssh ? 1 : 0

  project     = var.project_id
  name        = "${var.name_prefix}-allow-iap-ssh"
  network     = local.network_name
  description = "Allow SSH from the IAP TCP forwarding range."
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = ["35.235.240.0/20"]
  target_tags   = [local.network_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "egress_allow" {
  count = var.restrict_egress ? 1 : 0

  project     = var.project_id
  name        = "${var.name_prefix}-allow-egress"
  network     = local.network_name
  description = "Allow the outbound traffic workers need: HTTPS to Cursor, git hosts and registries, HTTP for apt, and DNS."
  direction   = "EGRESS"
  priority    = 1000

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = [local.network_tag]

  allow {
    protocol = "tcp"
    ports    = var.egress_allow_tcp_ports
  }

  allow {
    protocol = "tcp"
    ports    = ["53"]
  }

  allow {
    protocol = "udp"
    ports    = ["53"]
  }
}

resource "google_compute_firewall" "egress_deny" {
  count = var.restrict_egress ? 1 : 0

  project     = var.project_id
  name        = "${var.name_prefix}-deny-egress"
  network     = local.network_name
  description = "Deny all other egress from workers. Traffic to the metadata server is always permitted by GCP."
  direction   = "EGRESS"
  priority    = 65534

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = [local.network_tag]

  deny {
    protocol = "all"
  }
}
