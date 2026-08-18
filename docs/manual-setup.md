# Manual setup

The same worker as the Terraform in this repo, built by hand with `gcloud` and a
shell. Useful for a first test, for debugging a fleet that misbehaves, or when
you just want one worker and no state file.

Everything below assumes:

```bash
export PROJECT_ID=lennyisagoodboy
export REGION=us-central1
export ZONE=us-central1-a
export POOL=gce-us-central1
gcloud config set project "$PROJECT_ID"
```

## If the CLI is already installed and you only want a worker now

The smallest possible version, on any machine that already has `agent`:

```bash
agent login                    # or: export CURSOR_API_KEY=<user api key>
cd /path/to/your/repo
agent worker start
```

That is a [My Machines](https://cursor.com/docs/cloud-agent/self-hosted-guides/my-machines.md)
worker: your machine, bound to that checkout, targetable from a trigger with
`worker=<name>`. It needs no Enterprise plan and no service account key.

Everything else on this page is the [pool](https://cursor.com/docs/cloud-agent/self-hosted-guides/pool.md)
variant, which is what an org-managed fleet on GCE wants. Pool mode requires an
Enterprise plan and a **service account** API key. User, personal, team, and
organization keys are rejected. Create one at Dashboard → Settings → API Keys →
Service Accounts; it is shown once. Also turn on **Allow Self-Hosted Agents** (or
**Require Self-Hosted Agents**) in the
[Cloud Agents dashboard](https://cursor.com/dashboard/cloud-agents#self-hosted-agents).

To turn a machine you already have into a pool worker, skip ahead to
[Run the worker](#5-run-the-worker).

## Which key do I have?

There is no documented prefix that distinguishes a user API key from a service
account key, so check what the key can do instead. Fleet management is service
account only, which makes it a reliable probe:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -u "$CURSOR_API_KEY:" \
  https://api.cursor.com/v0/private-workers/summary
```

`200` means the key works for pool workers. `401` or `403` means it is a user,
personal, team, or organization key: fine for `agent login` / My Machines and for
`agent -p` in CI, but pool workers will reject it. `scripts/set-api-key.sh` runs
this check before storing anything.

The rejection you get from the worker itself looks like this, and is not
something a flag or a retry will fix:

```text
Error: Pool workers (--pool) require a service account API key.
```

The fix is either a service account key, or dropping `--pool` to run the same VM
as a My Machines worker:

```bash
export CURSOR_API_KEY=<your user api key>     # or: agent login

agent worker \
  --name gce-us-central1-1 \
  --worker-dir ~/git \
  --management-addr 0.0.0.0:8080 \
  start --verbose
```

Target that worker with `worker=gce-us-central1-1` (or `machine=`) from GitHub,
Slack, or the dashboard's worker selector, instead of `pool=`. Everything else on
this page is unchanged. In Terraform this is `worker_mode = "machine"`.

Wherever the key ends up, keep it out of shell history and out of git. Use
`read -r -s` to enter it, or pipe it straight from a secret store.

## 1. Enable APIs

```bash
gcloud services enable \
  compute.googleapis.com \
  secretmanager.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  iap.googleapis.com
```

## 2. Service account and secret

The worker's identity, scoped to writing telemetry and reading one secret:

```bash
gcloud iam service-accounts create cursor-worker-sa \
  --display-name="Cursor self-hosted Cloud Agent worker"

export WORKER_SA="cursor-worker-sa@${PROJECT_ID}.iam.gserviceaccount.com"

for role in roles/logging.logWriter roles/monitoring.metricWriter; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${WORKER_SA}" --role="$role" --condition=None
done
```

Store the API key in Secret Manager rather than baking it into the VM, so the
worker can re-read it and you can rotate it by adding a version:

```bash
gcloud secrets create cursor-worker-api-key --replication-policy=automatic

read -r -s -p "Cursor service account API key: " CURSOR_API_KEY; echo
printf %s "$CURSOR_API_KEY" | gcloud secrets versions add cursor-worker-api-key --data-file=-

gcloud secrets add-iam-policy-binding cursor-worker-api-key \
  --member="serviceAccount:${WORKER_SA}" \
  --role=roles/secretmanager.secretAccessor
```

## 3. Network

Workers need outbound HTTPS and nothing inbound, so: a custom subnet, Cloud NAT
for egress, and no external IP.

```bash
gcloud compute networks create cursor-worker-vpc --subnet-mode=custom

gcloud compute networks subnets create "cursor-worker-${REGION}" \
  --network=cursor-worker-vpc \
  --region="$REGION" \
  --range=10.60.0.0/24 \
  --enable-private-ip-google-access

gcloud compute routers create cursor-worker-router \
  --network=cursor-worker-vpc --region="$REGION"

gcloud compute routers nats create cursor-worker-nat \
  --router=cursor-worker-router \
  --router-region="$REGION" \
  --auto-allocate-nat-external-ips \
  --nat-all-subnet-ip-ranges
```

SSH reaches the VM through IAP TCP forwarding, which is the only ingress needed:

```bash
gcloud compute firewall-rules create cursor-worker-allow-iap-ssh \
  --network=cursor-worker-vpc \
  --direction=INGRESS --action=allow \
  --rules=tcp:22 --source-ranges=35.235.240.0/20 \
  --target-tags=cursor-worker-worker
```

You also need `roles/iap.tunnelResourceAccessor` and an OS Login role on the
project to use it:

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="user:$(gcloud config get-value account)" \
  --role=roles/iap.tunnelResourceAccessor --condition=None
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="user:$(gcloud config get-value account)" \
  --role=roles/compute.osAdminLogin --condition=None
```

## 4. The VM

```bash
gcloud compute instances create cursor-worker-1 \
  --zone="$ZONE" \
  --machine-type=e2-standard-16 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=200GB \
  --boot-disk-type=pd-balanced \
  --network-interface=network=cursor-worker-vpc,subnet="cursor-worker-${REGION}",no-address \
  --service-account="$WORKER_SA" \
  --scopes=https://www.googleapis.com/auth/cloud-platform \
  --tags=cursor-worker-worker \
  --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
  --metadata=enable-oslogin=TRUE
```

`e2-standard-16` is 16 vCPU and 64 GB, so the project needs at least 16 `CPUS`
of quota free in the region.

```bash
gcloud compute ssh cursor-worker-1 --zone="$ZONE" --tunnel-through-iap
```

Everything from here runs on the VM.

## 5. Run the worker

Install the toolchain your repo's builds and tests need. At minimum the worker
needs `git` on `PATH`:

```bash
sudo apt-get update
sudo apt-get install -y git curl jq build-essential python3 tmux unzip
```

Docker is optional and only for the agent's own builds. If you add it, remember
that the `docker` group is root-equivalent on the host:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"   # log out and back in
```

Install the CLI (skip if you already have it):

```bash
curl https://cursor.com/install -fsS | bash
agent --version
```

Clone the repos the worker will serve. Use writable paths under `$HOME`:

```bash
mkdir -p ~/workspace
git clone https://github.com/your-org/your-repo.git ~/workspace/your-repo
```

Read the API key out of Secret Manager. The stock Ubuntu image has no `gcloud`,
so go through the metadata server, which is also what the Terraform bootstrap
does:

```bash
TOKEN=$(curl -s -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token \
  | jq -r .access_token)

CURSOR_API_KEY=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://secretmanager.googleapis.com/v1/projects/lennyisagoodboy/secrets/cursor-worker-api-key/versions/latest:access" \
  | jq -r .payload.data | base64 -d)

export CURSOR_API_KEY
```

Preflight, then start. Worker options go **before** the subcommand; putting them
after `start` silently does the wrong thing:

```bash
agent worker \
  --pool gce-us-central1 \
  --worker-dir ~/workspace/your-repo \
  debug --json

agent worker \
  --pool gce-us-central1 \
  --worker-dir ~/workspace/your-repo \
  --idle-release-timeout 600 \
  --management-addr 0.0.0.0:8080 \
  start --verbose
```

A healthy worker logs its registered roots, which is the source of truth for
what Cursor actually sees:

```text
repo=your-org/your-repo
workspacePaths: [your-repo]
x-repository-urls: ["https://github.com/your-org/your-repo.git"]
```

It should now appear in the dashboard under the `gce-us-central1` pool. Send it
work with `@cursoragent pool=gce-us-central1 ...` on GitHub, `pool=` from Slack
or Linear, or the pool selector in the dashboard.

Repeat `--worker-dir` for up to 20 repos; the first is the primary one used for
assignment identity and dashboard display. Add `--label key=value` (or
`--labels-file`) for routing labels, but not `repo` or `pool`, which Cursor sets
itself.

## Optional: a display for browser work

The stock image is headless, so a browser has nothing to draw on. If your agents
need browser or GUI tool calls, or you want to watch what they do:

```bash
sudo apt-get install -y xvfb fluxbox x11vnc x11-utils dbus-x11 fonts-liberation

curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
  | sudo gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
  | sudo tee /etc/apt/sources.list.d/google-chrome.list
sudo apt-get update && sudo apt-get install -y google-chrome-stable
```

Run the display, a window manager, and a loopback-only VNC server:

```bash
Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp &
DISPLAY=:99 fluxbox &
x11vnc -display :99 -localhost -rfbport 5900 -shared -forever -nopw &
export DISPLAY=:99
```

Restart the worker so it inherits `DISPLAY`. To look at that display from your
laptop, forward the port over IAP and point a VNC client at `localhost:5900`:

```bash
gcloud compute ssh cursor-worker-1 --zone="$ZONE" --tunnel-through-iap \
  -- -N -L 5900:localhost:5900
```

In Terraform this is `install_desktop = true`, which also installs the three
services as systemd units so they survive a reboot. Note that this gets a browser
and a viewable desktop onto the worker; whether Cursor's computer-use tooling
drives it end to end on a self-hosted worker is not something the docs state
either way.

## 6. Keep it running

`agent worker ... start` in an SSH session dies with the session, and it exits 0
on its own once `--idle-release-timeout` fires. Put it under systemd so it comes
back, and so each restart re-reads the key:

```bash
sudo tee /etc/systemd/system/cursor-worker.service >/dev/null <<EOF
[Unit]
Description=Cursor self-hosted Cloud Agent worker
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME
Environment=HOME=$HOME
Environment=PATH=$HOME/.local/bin:$HOME/.cursor/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/local/bin/cursor-worker-run
Restart=always
RestartSec=5
SyslogIdentifier=cursor-worker

[Install]
WantedBy=multi-user.target
EOF
```

`ExecStart` points at a wrapper because the key has to be fetched at each start
rather than written into the unit file:

```bash
sudo tee /usr/local/bin/cursor-worker-run >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=lennyisagoodboy
SECRET_ID=cursor-worker-api-key
WORKER_DIR="$HOME/workspace/your-repo"

TOKEN=$(curl -s -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token \
  | jq -r .access_token)
CURSOR_API_KEY=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${SECRET_ID}/versions/latest:access" \
  | jq -r .payload.data | base64 -d)
export CURSOR_API_KEY

git -C "$WORKER_DIR" fetch --prune origin || true
git -C "$WORKER_DIR" reset --hard origin/HEAD || true

exec agent worker \
  --pool gce-us-central1 \
  --worker-dir "$WORKER_DIR" \
  --idle-release-timeout 600 \
  --management-addr 0.0.0.0:8080 \
  start --verbose
EOF
sudo chmod 0755 /usr/local/bin/cursor-worker-run
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cursor-worker
journalctl -u cursor-worker -f
```

Check the endpoints the management address exposes:

```bash
curl -s localhost:8080/healthz    # 200 while connected to Cursor
curl -s localhost:8080/readyz     # 200 idle, 503 once a session claims the worker
curl -s localhost:8080/metrics    # Prometheus gauges and counters
```

## What the Terraform adds on top

If you outgrow the manual VM, the differences are:

- A regional managed instance group, so a dead worker is recreated and `N`
  workers is a number rather than N repetitions of the above.
- Autohealing on `/healthz`. Note that `/readyz` is deliberately unsuitable for
  this: it returns 503 while a session holds the worker, so probing it would
  replace busy workers mid-session.
- Workspace refresh before every session, with build caches preserved.
- Private repo credentials from a second secret, written to `~/.git-credentials`.
- Ops Agent for logs and metrics, and optional deny-all egress firewalling.
- Idempotent bootstrap in a startup script, so a replaced VM rebuilds itself.

## Cleaning up

```bash
gcloud compute instances delete cursor-worker-1 --zone="$ZONE" --quiet
gcloud compute routers nats delete cursor-worker-nat --router=cursor-worker-router --router-region="$REGION" --quiet
gcloud compute routers delete cursor-worker-router --region="$REGION" --quiet
gcloud compute firewall-rules delete cursor-worker-allow-iap-ssh --quiet
gcloud compute networks subnets delete "cursor-worker-${REGION}" --region="$REGION" --quiet
gcloud compute networks delete cursor-worker-vpc --quiet
gcloud secrets delete cursor-worker-api-key --quiet
gcloud iam service-accounts delete "$WORKER_SA" --quiet
```
