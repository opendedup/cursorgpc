variable "project_id" {
  description = "GCP project that hosts the worker fleet."
  type        = string
  default     = "lennyisagoodboy"
}

variable "region" {
  description = "GCP region for the worker fleet and all regional resources."
  type        = string
  default     = "us-central1"
}

variable "zones" {
  description = "Zones the regional managed instance group spreads workers across. Empty means every UP zone in the region. Pin this if the machine type is not offered in every zone."
  type        = list(string)
  default     = []
}

variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
  default     = "cursor-worker"
}

variable "labels" {
  description = "Labels applied to the GCP resources that support them."
  type        = map(string)
  default = {
    component  = "cursor-self-hosted-worker"
    managed-by = "terraform"
  }
}

variable "enable_apis" {
  description = "Enable the Google APIs the fleet needs. Set to false when a platform team manages API enablement."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------

variable "machine_type" {
  description = "Machine type for each worker. e2-standard-16 is 16 vCPU / 64 GB."
  type        = string
  default     = "e2-standard-16"
}

variable "worker_count" {
  description = "Number of workers in the pool. Each Cloud Agent session claims one worker at a time. Cursor allows up to 10 workers per user and 50 per team."
  type        = number
  default     = 1

  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 50
    error_message = "worker_count must be between 0 and 50 (Cursor's per-team worker cap)."
  }
}

variable "boot_image" {
  description = "Boot image for workers. The bootstrap script targets Debian-family apt distributions and is tested on Ubuntu 24.04 LTS."
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB. Sized for repo clones, build caches, and container images."
  type        = number
  default     = 200
}

variable "boot_disk_type" {
  description = "Boot disk type. pd-balanced is a good default; pd-ssd helps build-heavy repos."
  type        = string
  default     = "pd-balanced"
}

variable "use_spot" {
  description = "Run workers as Spot VMs. Cheaper, but GCP can preempt a worker mid-session and the agent run fails."
  type        = bool
  default     = false
}

variable "assign_public_ip" {
  description = "Give workers an external IP. Leave false and use Cloud NAT: workers only need outbound access."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "create_network" {
  description = "Create a dedicated VPC and subnet for the fleet. Set to false to attach to an existing network."
  type        = bool
  default     = true
}

variable "network" {
  description = "Existing VPC network name. Required when create_network is false."
  type        = string
  default     = ""
}

variable "subnetwork" {
  description = "Existing subnetwork name in var.region. Required when create_network is false."
  type        = string
  default     = ""
}

variable "subnet_cidr" {
  description = "Primary IPv4 range for the created subnet."
  type        = string
  default     = "10.60.0.0/24"
}

variable "create_nat" {
  description = "Create a Cloud Router and Cloud NAT so workers without external IPs can reach the internet. Set to false when the network already has NAT."
  type        = bool
  default     = true
}

variable "restrict_egress" {
  description = "Replace the VPC's implied allow-all egress with a deny-all rule plus allow rules for HTTPS, HTTP, and DNS. FQDN-level filtering needs Secure Web Proxy or an outbound proxy; see the README."
  type        = bool
  default     = true
}

variable "egress_allow_tcp_ports" {
  description = "TCP destination ports allowed out of the workers when restrict_egress is true. 443 reaches Cursor, git hosts, and registries; 80 is needed by apt on the stock images."
  type        = list(string)
  default     = ["80", "443"]
}

variable "enable_iap_ssh" {
  description = "Allow SSH from the IAP TCP forwarding range so operators can reach workers without external IPs."
  type        = bool
  default     = true
}

variable "iap_ssh_members" {
  description = "Principals granted IAP tunnel access and OS Login on the project, for example [\"user:you@example.com\"]. Empty makes no project-level IAM change."
  type        = list(string)
  default     = []
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs on the created subnet."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Cursor worker configuration
# ---------------------------------------------------------------------------

variable "cursor_api_key_secret_id" {
  description = "Secret Manager secret holding the Cursor service account API key. Pool workers reject user, personal, team, and organization keys."
  type        = string
  default     = "cursor-worker-api-key"
}

variable "create_secret" {
  description = "Create the API key secret. Terraform never stores the key itself; add a version with scripts/set-api-key.sh."
  type        = bool
  default     = true
}

variable "git_credentials_secret_id" {
  description = "Optional Secret Manager secret whose value is written to ~/.git-credentials on each worker, for example \"https://x-access-token:TOKEN@github.com\". Leave empty for public repos or repo-less pools."
  type        = string
  default     = ""
}

variable "worker_mode" {
  description = "\"pool\" registers workers for org-wide pool assignment and requires a Cursor Enterprise plan plus a service account API key. \"machine\" runs My Machines workers, which accept a personal user API key and are targeted by name instead of by pool."
  type        = string
  default     = "pool"

  validation {
    condition     = contains(["pool", "machine"], var.worker_mode)
    error_message = "worker_mode must be either pool or machine."
  }
}

variable "worker_pool_name" {
  description = "Cursor pool name workers register with. Sessions route only to workers in the pool they target. Ignored when worker_mode is \"machine\"."
  type        = string
  default     = "default"
}

variable "worker_name" {
  description = "Display name reported to Cursor. Empty uses the instance hostname, which keeps names unique across the fleet. Mainly useful with worker_mode = \"machine\", where triggers target a worker by name."
  type        = string
  default     = ""
}

variable "worker_idle_release_timeout" {
  description = "Seconds the worker stays connected after a session ends, to absorb follow-up messages. When it fires the CLI exits 0 and systemd restarts it with a refreshed workspace. 0 disables idle release."
  type        = number
  default     = 600
}

variable "worker_labels" {
  description = "Cursor worker labels used for routing, for example { team = \"backend\", env = \"production\" }. The repo and pool labels are reserved and set by Cursor."
  type        = map(string)
  default     = {}

  validation {
    condition     = length(setintersection(keys(var.worker_labels), ["repo", "pool"])) == 0
    error_message = "The repo and pool worker labels are reserved by Cursor and must not be set manually."
  }
}

variable "worker_repos" {
  description = "Repositories cloned onto each worker. The first entry is the primary repo for assignment identity and dashboard display. Empty creates a repo-less pool."
  type = list(object({
    url    = string
    name   = optional(string)
    branch = optional(string)
  }))
  default = []

  validation {
    condition     = length(var.worker_repos) <= 20
    error_message = "The Cursor CLI accepts at most 20 --worker-dir paths."
  }
}

variable "worker_reset_mode" {
  description = "How workspaces are refreshed before each worker session. \"reset\" hard-resets tracked files and keeps build caches, \"clean\" also removes untracked files, \"none\" leaves the workspace alone."
  type        = string
  default     = "reset"

  validation {
    condition     = contains(["none", "reset", "clean"], var.worker_reset_mode)
    error_message = "worker_reset_mode must be one of: none, reset, clean."
  }
}

variable "worker_verbose" {
  description = "Start the worker with --verbose. Verbose logs are the source of truth for which workspace roots and repo labels registered."
  type        = bool
  default     = true
}

variable "worker_env" {
  description = "Extra environment variables for the worker process, for example { HTTPS_PROXY = \"http://proxy:3128\" }. Do not put secrets here; they land in instance metadata."
  type        = map(string)
  default     = {}
}

variable "management_port" {
  description = "Port for the worker's /healthz, /readyz, and /metrics endpoints. Autohealing probes /healthz."
  type        = number
  default     = 8080
}

variable "enable_autohealing" {
  description = "Recreate workers whose /healthz endpoint stops responding. /healthz tracks the outbound connection to Cursor and stays healthy during a session, so busy workers are not replaced."
  type        = bool
  default     = true
}

variable "autohealing_initial_delay_sec" {
  description = "Grace period before autohealing starts probing a new worker. Must comfortably exceed bootstrap time (apt, Docker, CLI install, repo clone)."
  type        = number
  default     = 900
}

# ---------------------------------------------------------------------------
# Worker image contents
# ---------------------------------------------------------------------------

variable "worker_user" {
  description = "Local user that owns the workspace and runs the worker process."
  type        = string
  default     = "cursor"
}

variable "install_docker" {
  description = "Install Docker Engine and add the worker user to the docker group, so agents can build and run containers."
  type        = bool
  default     = true
}

variable "install_github_cli" {
  description = "Install the GitHub CLI (gh) from GitHub's apt repository."
  type        = bool
  default     = true
}

variable "install_poetry" {
  description = "Install Poetry for the worker user with the official installer, landing on the worker's PATH."
  type        = bool
  default     = true
}

variable "poetry_version" {
  description = "Poetry version to install, for example \"2.1.3\". Empty installs the latest release; pin it for reproducible builds."
  type        = string
  default     = ""
}

variable "github_token_secret_id" {
  description = "Optional Secret Manager secret holding a GitHub token. Exported to the worker as GH_TOKEN and GITHUB_TOKEN so gh works non-interactively, and used for HTTPS git clones when git_credentials_secret_id is unset."
  type        = string
  default     = ""
}

variable "install_desktop" {
  description = "Install a virtual display (Xvfb on :99), a minimal window manager, Google Chrome, and a loopback-only VNC server. Needed for any browser or GUI work on the worker, since the base image is headless. Also lets an operator view the display over an SSH tunnel."
  type        = bool
  default     = false
}

variable "install_ops_agent" {
  description = "Install the Google Cloud Ops Agent so worker logs and host metrics reach Cloud Logging and Cloud Monitoring."
  type        = bool
  default     = true
}

variable "enable_prometheus_metrics" {
  description = "Have the Ops Agent scrape the worker's Prometheus endpoint into Cloud Monitoring. Requires install_ops_agent."
  type        = bool
  default     = false
}

variable "extra_apt_packages" {
  description = "Additional apt packages installed at boot, for example [\"python3-venv\", \"postgresql-client\"]."
  type        = list(string)
  default     = []
}

variable "extra_setup_script" {
  description = "Bash appended to the bootstrap script, after the CLI is installed and before the worker service starts. Use it to install language toolchains or private registry config. Runs as root and must be idempotent."
  type        = string
  default     = ""
}

variable "additional_worker_roles" {
  description = "Extra project-level IAM roles for the worker service account, for example [\"roles/artifactregistry.reader\"]."
  type        = list(string)
  default     = []
}
