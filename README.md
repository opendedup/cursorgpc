# cursorgpc

Terraform for running [Cursor self-hosted Cloud Agents](https://cursor.com/docs/cloud-agent/self-hosted-guides/pool) on Google Compute Engine.

Defaults target the `lennyisagoodboy` project: one `e2-standard-16` worker (16 vCPU, 64 GB) in `us-central1`, on a private VPC with Cloud NAT for egress and no inbound access.

Cursor publishes reference deployments for [EC2, ECS, and EKS](https://github.com/cursor/cookbook/tree/main/self-hosted-cloud-agent) but nothing for GCP, so this repo fills that gap using GCP-native building blocks: a regional managed instance group, Secret Manager for the API key, and the Ops Agent for logs and metrics.

## What "self-hosted" does and does not mean

A worker opens a long-lived **outbound** HTTPS connection to Cursor and executes the agent's tool calls — terminal commands, file edits, browser actions, stdio MCP servers — on your machine. The agent loop itself (inference, planning, orchestration) still runs in Cursor's cloud.

Two things leave your network: file chunks the model reads during inference, and agent artifacts such as screenshots and videos. Your repos, build caches, secrets, and tool execution stay on your VMs. If your requirement is "source code never leaves our perimeter", self-hosted workers do not satisfy it.

## Architecture

```
                        GCP project: lennyisagoodboy
  ┌──────────────────────────────────────────────────────────────────────┐
  │  VPC cursor-worker-vpc                                              │
  │  subnet cursor-worker-us-central1 (10.60.0.0/24, no external IPs)    │
  │                                                                      │
  │   ┌────────────────────────────────────────────┐                     │
  │   │ Regional MIG cursor-worker-mig (us-central1)│                    │
  │   │  e2-standard-16, Ubuntu 24.04, Shielded VM  │                    │
  │   │                                             │                    │
  │   │  systemd cursor-worker.service              │                    │
  │   │    └─ cursor-worker-run                     │                    │
  │   │         ├─ refresh git workspaces           │    ┌────────────┐  │
  │   │         ├─ read API key ───────────────────────► │  Secret    │  │
  │   │         └─ agent worker --pool ... start    │    │  Manager   │  │
  │   │                                             │    └────────────┘  │
  │   │  :8080 /healthz /readyz /metrics ◄── health check (autohealing)   │
  │   └────────────────────────────────────────────┘                     │
  │                          │ outbound HTTPS only                       │
  └──────────────────────────┼───────────────────────────────────────────┘
                             ▼
                        Cloud NAT ──► api2.cursor.sh, api2direct.cursor.sh,
                                      cloud-agent-artifacts.s3.us-east-1.amazonaws.com,
                                      your git hosts and package registries
```

Notable design choices:

- **The worker runs natively under systemd**, not in a container. Agents get the whole 16-vCPU machine, and Docker is installed for the agent's own builds instead of wrapping the worker itself.
- **The API key never touches disk.** `cursor-worker-run` reads it from Secret Manager through the metadata-server token at each start and exports it only into the worker process. Rotation is a new secret version plus a service restart.
- **Autohealing probes `/healthz`, never `/readyz`.** `/healthz` tracks the connection to Cursor and stays healthy during a session; `/readyz` deliberately returns 503 while a session holds the worker, so probing it would kill busy workers.
- **Workspaces are refreshed before every session.** When `--idle-release-timeout` fires, the CLI exits 0, systemd restarts it, and the workspace is re-fetched and hard-reset first. Untracked build caches survive by default (`worker_reset_mode = "reset"`).

## Prerequisites

- A **Cursor Enterprise plan**. Pool workers are Enterprise-only.
- A **service account API key** from Dashboard → Settings → API Keys → Service Accounts. It is shown once. User, personal, team, and organization keys are rejected by pool workers.
- Self-hosted routing enabled in the [Cloud Agents dashboard](https://cursor.com/dashboard/cloud-agents#self-hosted-agents): **Allow Self-Hosted Agents**, or **Require Self-Hosted Agents** to route everything to your fleet.
- `gcloud` and Terraform >= 1.5 locally, authenticated with `gcloud auth application-default login`.
- On the GCP project: `roles/owner`, or the combination of `compute.admin`, `iam.serviceAccountAdmin`, `secretmanager.admin`, `resourcemanager.projectIamAdmin`, and `serviceusage.serviceUsageAdmin`.
- Regional CPU quota for `16 × worker_count` vCPUs in `us-central1`.

## Quickstart

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit worker_pool_name, worker_repos, and worker_labels for your setup.

make init
make apply
```

Store the service account API key (Terraform creates the secret but never holds the value):

```bash
CURSOR_API_KEY=key_... make api-key
```

Workers poll for the secret while booting, so the order does not matter. Watch the first worker come up:

```bash
make status          # GCE instances and health
make bootstrap-log   # apt, Docker, CLI install, repo clone
make follow          # tail cursor-worker.service
```

Prefer to do it by hand, or already have a machine with the CLI installed? [`docs/manual-setup.md`](docs/manual-setup.md) is the same deployment as a `gcloud` runbook, including the one-line My Machines variant for a single personal worker.

A connected worker logs its registered roots, which is the source of truth for what Cursor sees:

```text
repo=your-org/your-repo
workspacePaths: [your-repo]
x-repository-urls: ["https://github.com/your-org/your-repo.git"]
```

It then appears in the [Cloud Agents dashboard](https://cursor.com/dashboard/cloud-agents) under the pool name you configured.

## Sending agents to the fleet

Pick the pool in the worker selector in the dashboard, or target it from a trigger:

| Surface | Syntax |
| --- | --- |
| Dashboard | Choose the pool in the worker selector when starting a session or editing an automation |
| GitHub | `@cursoragent pool=gce-us-central1 ...` |
| Slack | `@Cursor pool=gce-us-central1 ...` or `self_hosted=true` |
| Linear | `pool=gce-us-central1` in the issue body |
| API | `{"env": {"type": "pool", "name": "gce-us-central1"}}` on `POST https://api.cursor.com/v1/agents` |

## Private repositories

Public HTTPS clones work out of the box. For private repos, put a git credential line in its own secret and point the fleet at it:

```bash
gcloud secrets create cursor-worker-git-credentials --project=lennyisagoodboy --replication-policy=automatic
printf 'https://x-access-token:ghp_yourtoken@github.com\n' \
  | gcloud secrets versions add cursor-worker-git-credentials --project=lennyisagoodboy --data-file=-
```

```hcl
git_credentials_secret_id = "cursor-worker-git-credentials"
```

Each worker writes the value to `~/.git-credentials` (mode 0600) and enables git's `store` credential helper. A GitHub App installation token or a fine-grained PAT scoped to the repos in `worker_repos` is preferable to a classic PAT. Use a short expiry and rotate by adding a new secret version and running `make restart`.

## Configuration

Full reference in [`terraform/variables.tf`](terraform/variables.tf). The variables that matter most:

| Variable | Default | Purpose |
| --- | --- | --- |
| `project_id` | `lennyisagoodboy` | Target project |
| `region` | `us-central1` | Target region |
| `machine_type` | `e2-standard-16` | 16 vCPU / 64 GB per worker |
| `worker_count` | `1` | Fleet size; one session claims one worker |
| `worker_pool_name` | `default` | Pool name used by triggers |
| `worker_repos` | `[]` | Repos cloned onto each worker; first is primary. Empty means a repo-less pool |
| `worker_labels` | `{}` | Routing labels. `repo` and `pool` are reserved by Cursor |
| `worker_idle_release_timeout` | `600` | Seconds to hold the worker after a session, for follow-ups |
| `worker_reset_mode` | `reset` | `reset` keeps build caches, `clean` wipes untracked files, `none` leaves the checkout |
| `install_docker` | `true` | Docker Engine for the agent's builds |
| `extra_apt_packages` / `extra_setup_script` | `[]` / `""` | Language toolchains and other repo-specific setup |
| `use_spot` | `false` | Spot VMs; cheaper, but preemption kills in-flight sessions |
| `restrict_egress` | `true` | Deny-all egress plus allow rules for HTTPS, HTTP, and DNS |

Sizing is a judgment call: Cursor publishes no worker spec and recommends sizing a worker like a CI runner or devbox for the repo it serves. `e2-standard-16` is generous for most repos; if agents mostly edit and run small test suites, `e2-standard-8` halves the bill.

### Toolchains

The bootstrap installs git, curl, jq, Python 3, build-essential, tmux, and Docker. Anything else your builds need belongs in `extra_apt_packages` or `extra_setup_script`, which runs as root at the end of the bootstrap and must be idempotent:

```hcl
extra_setup_script = <<-EOT
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
  corepack enable
EOT
```

Repo-level `.cursor/hooks.json` hooks and project skills in `.cursor/skills/` are picked up automatically. Note that `.cursor/environment.json` is a Cursor-managed-VM feature: on a self-hosted worker there is no VM for Cursor to provision, so treat the bootstrap script as your `install` phase.

## Operations

```bash
make status              # MIG instances, health state, and (with CURSOR_API_KEY) Cursor's fleet view
make logs                # recent worker logs from Cloud Logging
make follow              # tail cursor-worker.service on one worker
make ssh                 # IAP SSH into a worker
make scale N=3           # resize now; also set worker_count to keep it
make restart             # restart cursor-worker.service everywhere (picks up a rotated key)
make replace             # rolling-replace every VM (new image or bootstrap change)
```

`make ssh` needs IAP access. Grant it declaratively with `iap_ssh_members = ["user:you@example.com"]`, which adds `roles/iap.tunnelResourceAccessor` and `roles/compute.osAdminLogin`.

Rotating the API key: `CURSOR_API_KEY=key_... make api-key` then `make restart`. Workers read the latest secret version at every start, so no Terraform run is needed.

Changing `extra_setup_script`, the image, or any other instance-template field makes Terraform create a new template and roll the MIG. The update policy replaces in place (`max_surge_fixed = 0`) so a 16-vCPU fleet never doubles its quota usage mid-update; in-flight sessions on replaced workers are interrupted.

### Monitoring

With `install_ops_agent = true` (the default) worker logs land in Cloud Logging under the `cursor-worker` and `cursor-worker-bootstrap` syslog identifiers, and host metrics in Cloud Monitoring. Set `enable_prometheus_metrics = true` to also scrape the worker's own gauges and counters:

| Metric | Meaning |
| --- | --- |
| `cursor_self_hosted_worker_connected` | 1 when the outbound connection to Cursor is up |
| `cursor_self_hosted_worker_session_active` | 1 while a session runs on this worker |
| `cursor_self_hosted_worker_last_activity_unix_seconds` | Last frame or heartbeat from Cursor |
| `cursor_self_hosted_worker_connect_attempts_total` / `_connect_retry_total` | Connection attempts and retries |
| `cursor_self_hosted_worker_session_ends_total` | Sessions ended, labeled by `reason` |

`session_active` across the fleet is the signal to scale on. Cursor also exposes a [fleet management API](https://cursor.com/docs/cloud-agent/api/endpoints.md#fleet-management) (`/v0/private-workers/summary`) that `make status` queries when `CURSOR_API_KEY` is set.

## Networking and security

Workers need outbound HTTPS to:

| Host | Purpose | If blocked |
| --- | --- | --- |
| `api2.cursor.sh`, `api2direct.cursor.sh` | Agent session | The worker cannot start or continue a session |
| `cloud-agent-artifacts.s3.us-east-1.amazonaws.com` | Artifact uploads | Screenshots and videos fail to upload; sessions keep working |
| `downloads.cursor.com` | CLI download and self-update | Bootstrap fails |

No inbound ports, public IPs, or VPN tunnels are required. The only ingress rules here are for GCP-internal callers: health check probes on the management port from `35.191.0.0/16` and `130.211.0.0/22`, and optional IAP SSH from `35.235.240.0/20`.

`restrict_egress = true` installs a deny-all egress rule at priority 65534 plus allow rules for TCP 443, TCP 80 (apt on the stock images), and DNS. VPC firewall rules match IP ranges, not hostnames, so this is a port-level control rather than a domain allowlist. For true FQDN filtering, route egress through [Secure Web Proxy](https://cloud.google.com/secure-web-proxy/docs/overview) or your own proxy and set `worker_env = { HTTPS_PROXY = "http://proxy:3128" }`. Note that Cursor uses HTTP/2 bidirectional streaming, so an SSL-inspecting proxy needs `.cursor.sh` excluded from inspection.

Other security properties worth knowing:

- Workers run with a dedicated service account holding only `logging.logWriter`, `monitoring.metricWriter`, the Ops Agent metadata role, and `secretAccessor` on the one secret. Add more with `additional_worker_roles`.
- Since scopes are `cloud-platform` and bounded by IAM, be deliberate about extra roles: an agent has shell access to the VM and therefore to the service account's permissions.
- The worker runs as the unprivileged `cursor` user. With `install_docker = true` that user is in the `docker` group, which is root-equivalent on the host. Set `install_docker = false` if that is unacceptable.
- Shielded VM (secure boot, vTPM, integrity monitoring) and OS Login are enabled; project-wide SSH keys are blocked.
- Cursor caps self-hosted capacity at 10 workers per user and 50 per team.

## Cost

A single on-demand `e2-standard-16` in `us-central1` is roughly $0.54/hour, about $390/month, plus roughly $20/month for the 200 GB balanced disk and Cloud NAT usage. Check the [pricing calculator](https://cloud.google.com/products/calculator) for current rates. Ways to trim it:

- `use_spot = true` for a large discount, accepting that preemption fails in-flight sessions.
- A smaller `machine_type`, or `worker_count = 0` when the fleet is idle (`make scale N=0`) since durable pool records survive at zero capacity.
- Scale on `cursor_self_hosted_worker_session_active` or the fleet summary API instead of running peak capacity around the clock.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| No worker in the dashboard | Secret has no version yet, or the key is not a service account key. Check `make follow` for `could not read the Cursor API key`. |
| `agent` not found in service logs | The CLI install failed, usually egress. Check `make bootstrap-log`. |
| Worker connects, repo missing | Clone failed. `make bootstrap-log` shows `WARNING clone of ... failed`; private repos need `git_credentials_secret_id`. |
| VM recreated in a loop | `/healthz` never came up within `autohealing_initial_delay_sec`. Raise it, or set `enable_autohealing = false` while debugging. |
| Only the first repo seems registered | Expected: the dashboard groups a worker under its primary repo. Confirm with `workspacePaths` and `x-repository-urls` in the verbose logs. |
| Sessions still run on Cursor's infrastructure | Self-hosted routing is off in the dashboard, or the trigger lacks `pool=` / `self_hosted=true`. |
| `terraform apply` fails on quota | Request more `CPUS` quota in `us-central1`; each worker needs 16 vCPUs. |

## Repository layout

```
terraform/
  apis.tf, locals.tf, network.tf, iam.tf, secrets.tf, worker.tf, outputs.tf
  templates/startup.sh.tftpl      GCE startup script (idempotent, runs every boot)
  files/cursor-worker-secret      Reads Secret Manager via the metadata token
  files/cursor-worker-prepare     Clones and refreshes the workspace roots
  files/cursor-worker-run         systemd entrypoint that execs the worker CLI
scripts/                          Operator helpers used by the Makefile
docs/manual-setup.md              The same worker built by hand with gcloud
```

## References

- [Self-hosted pool guide](https://cursor.com/docs/cloud-agent/self-hosted-guides/pool.md)
- [Choose where Cloud Agents run](https://cursor.com/docs/cloud-agent/self-hosted-guides/choose-runtime.md)
- [My Machines](https://cursor.com/docs/cloud-agent/self-hosted-guides/my-machines.md) for a single personal worker
- [Kubernetes deployment guide](https://cursor.com/docs/cloud-agent/self-hosted-guides/kubernetes.md) if you would rather run this on GKE
- [Cloud Agents API](https://cursor.com/docs/cloud-agent/api/endpoints.md)
- [Cursor cookbook: self-hosted Cloud Agents](https://github.com/cursor/cookbook/tree/main/self-hosted-cloud-agent)
