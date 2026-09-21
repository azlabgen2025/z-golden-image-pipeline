# Golden Image Pipeline

Automated AWS golden image creation using Packer, Ansible, and GitHub Actions.

## Architecture

```
Web UI (Flask) --> GitHub Actions --> Packer --> EC2 (t2.micro / t3.small) --> AMI
                                       |
                                       +--> Ansible (packages/config)
                                       |
                                       +--> Security scan (future)
```

## Image Layers

| Layer | Contents | Built By |
|-------|----------|----------|
| Base | OS + core tools (git, docker, python, cloud-init) | `packer/base` |
| Customer | Customer-specific packages | `packer/customer` |
| Department | Department-specific packages | `packer/department` |

## Prerequisites

- AWS account (any tier — builds run on `t2.micro`, mostly within the Free Tier)
- GitHub account (a fresh repo is fine — everything is in this repository)
- **`git` and the AWS CLI v2** on the machine used for the one-time IAM setup
  (skip this if you're a restricted/non-admin user following [Step 1c](#1c-restricted--non-admin-aws-user-no-iam-rights) — the app only needs your existing access keys)

**Install `git` + AWS CLI v2 on a fresh Ubuntu VM** (skip if already present):

```bash
sudo apt-get update && sudo apt-get install -y git unzip curl
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -o awscliv2.zip && sudo ./aws/install
aws --version     # e.g. aws-cli/2.x
git --version
```

**On macOS:**

```bash
xcode-select --install                    # provides git
curl -s "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
aws --version && git --version
```

Then configure one-time credentials for the setup step (do **not** reuse these
keys for builds — builds use the GitHub OIDC role, not access keys):

```bash
aws configure    # enter an IAM user access key + secret + region
```

## Quick Start (common setup for all run methods)

> These steps are the **same for every way of running the app** — they must be done
> once before using the web UI (see [Ways to run the app](#ways-to-run-the-app)).

### 0. GitHub repo setup (one-time)

1. **Fork or push** this repository to your own GitHub account:
   ```bash
   gh repo create golden-image-pipeline --public --source . --remote upstream --push
   # or, without the gh CLI:
   git remote add origin https://github.com/<YOU>/golden-image-pipeline.git
   git push -u origin main
   ```
2. **Create a fine-grained Personal Access Token** — this is what the web UI
   uses to dispatch builds. It needs **two** permissions, both listed under
   **Permissions → Repository permissions**:
   - **Actions** = **Read and write** (lets the app trigger workflow runs)
   - **Metadata** = **Read-only** — the GitHub API *requires* this for the
     token to even see the repo; **if it's missing (or "No access") you will get
     `404 Not Found` on Connect GitHub**, even though the repo URL is correct
   Full walkthrough:
   - GitHub → **Settings** (your avatar, top-right) → **Developer settings**
   - **Personal access tokens** → **Fine-grained tokens** → **Generate new token**
   - Give it a name (e.g. `golden-image-builds`), set an expiry, then under
     **Repository access** choose **Only select repositories** → pick your new repo
   - Under **Permissions → Repository permissions**, set **Actions = Read and
     write** and **Metadata = Read-only**
   - Click **Generate token**, copy the `github_pat_...` value once — it is shown
     only once — and save it somewhere safe. This token is what the web UI uses to
     dispatch builds (see [Ways to run the app](#ways-to-run-the-app), below).
   - **Connect GitHub shows `404`?** Work through these in order:
     1. Both token permissions are set: **Actions = Read and write** and
        **Metadata = Read-only**.
     2. The token's **Repository access** has your **fork** selected — the app's
        repo field must be `<YOUR_GITHUB_USERNAME>/golden-image-pipeline`
        (not `azlabgen2025/z-golden-image-pipeline`, no `https://`).
     3. **Actions is enabled on your fork.** Forks often come with Actions off:
        open the fork in GitHub → **Actions** tab → if asked, choose
        **Enable GitHub Actions** (or fork → **Settings** → **Actions** → General
        → ensure Actions are allowed).
     4. Still 404? Diagnose directly:
        ```bash
        curl -s -H "Authorization: Bearer <GITHUB_PAT>" \
             -H "Accept: application/vnd.github+json" \
             https://api.github.com/repos/<username>/golden-image-pipeline/actions/workflows/build-image.yml
        ```
        - `200` OK → the pipe works; the app just needs the exact same string
        - `404` → none of the above; confirm the token has the fork selected
        - `403`/`401` → token scope/permissions problem

### 1. AWS Setup

> **Restricted / non-admin AWS user? Jump to [1c](#1c-restricted--non-admin-aws-user-no-iam-rights).**
> The app itself only needs *read-only* keys — but the one-time role creation below
> needs AWS **admin** rights. If you can't do IAM, have your AWS admin run it once
> (it's a single script) and hand you the ARN.

**1a. Create an IAM user + access key (needed for `aws configure`):**

- AWS Console → **IAM** → **Users** → **Create user** (name e.g. `golden-admin`)
- Attach **AdministratorAccess** to it (simplest for a personal account; scope it
  down if you prefer least-privilege)
- Open the user → **Security credentials** → **Create access key** (use case:
  *Command Line Interface*) → copy the **Access key ID** and **Secret access key**
- Configure it here [on the machine you run setup from]:
  ```bash
  aws configure
  #   AWS Access Key ID: <paste>
  #   AWS Secret Access Key: <paste>
  #   Default region name: us-east-1
  #   Default output format: json
  ```

**1b. Run the IAM/OIDC setup script:**

```bash
cd scripts
chmod +x setup-aws.sh
./setup-aws.sh us-east-1
```

The script will **prompt you** for your GitHub organisation/username and the
forked repo name (e.g. `alice` and `golden-image-pipeline`) — these become the
OIDC trust condition, so enter your **fork**, not this repository.

This creates:
- IAM role `GitHubActionsPackerRole` with an OIDC trust to your GitHub repo
- IAM policy `GoldenImagePackerPolicy` (EC2/S3/PassRole access for builds)
- Prints the role ARN to paste as a GitHub secret

**1c. Restricted / non-admin AWS user (no IAM rights):**

If you only have **account access + security keys** (a limited user, e.g. from
your company) and cannot create IAM roles, the `setup-aws.sh` step above can't
run under your account — it needs admin rights. Do this instead:

1. **Ask your AWS admin to run `setup-aws.sh` once** for you (they paste your
   fork's `org/repo` when prompted). It's a single command and creates only
   what builds need. They give you back the printed
   `AWS_ROLE_TO_ASSUME = arn:aws:iam::123456789012:role/GitHubActionsPackerRole`.
   > The admin can run it from their own machine with their own admin keys —
   > *no need to share your keys with them or theirs with you*.
2. **Your own security keys are only used by the web app for read-only
   listing** (verify login, list golden images). The *builds* run in GitHub
   Actions as the role above — your keys are never used to build, so they do
   **not** need EC2/other permissions.
3. Skip the rest of `1a/1b` tool-install steps (`aws configure`, etc.) — you
   don't need the AWS CLI at all for the web-app path.

> **Security note for the admin:** the OIDC trust is scoped to exactly one
> GitHub repo (`repo:<org>/<fork>:*`), and the role can only build AMIs — it
> can't touch anything in your AWS account outside this repo's workflow runs.

### 2. GitHub Secrets

**2a. Add the AWS role ARN as a secret:**

- GitHub → your forked repo → **Settings** → **Secrets and variables** → **Actions**
- **New repository secret**
- Name: `AWS_ROLE_TO_ASSUME` — Value: the ARN printed by `setup-aws.sh`
  (looks like `arn:aws:iam::123456789012:role/GitHubActionsPackerRole`)

**2b. Generate the golden SSH keypair and add both halves:**

```bash
# 1. Generate your OWN keypair (never reuse someone else's)
ssh-keygen -t rsa -b 2048 -f golden -N ""

# 2. Bake YOUR public key into the repo (replaces the bundled demo key)
cp golden.pub ansible/base/vars/golden_user.pub
git add ansible/base/vars/golden_user.pub
git commit -m "Bake own golden SSH key into base images"
git push

# 3. Add the PRIVATE key as the second GitHub secret:
#    repo → Settings → Secrets and variables → Actions → New repository secret
#    Name: GOLDEN_SSH_PRIVATE_KEY   Value: paste the contents of golden (the file, not .pub)
```

Why this step matters: every base image has the key `ansible/base/vars/golden_user.pub`
burned into the standard `ec2-user` account. The customized (layered) build job connects
to those images by SSH, so the private key you add as `GOLDEN_SSH_PRIVATE_KEY` **must be
the exact counterpart of that public key**. If you skip step 2, your custom builds will
fail to connect (the image only trusts the bundled key, which you don't own). Base-only
builds work without this secret.

The `AWS_ROLE_TO_ASSUME` role is what the GitHub Actions workflow assumes
(OIDC) to build AMIs in your AWS account. The web UI can also pass a
`role_arn` per account and an `aws_region` per build, which override the
secret. If you skip `GOLDEN_SSH_PRIVATE_KEY`, base builds still work; the
connection key is only used by the customized (layered) build job.

### 3. Credentials to enter in the web app

Once the app is running you paste these into **Settings/Connect AWS** and
**Settings/Connect GitHub** (they are stored Fernet-encrypted at rest):

| Where in the app | What to paste | Where you created it |
|------------------|---------------|----------------------|
| **Connect AWS** → access key ID | `AKIA...` | Admin user: Step 1a → **Security credentials** → **Create access key**. Restricted user: **your existing security keys** (they're all you need — read-only use) |
| **Connect AWS** → secret access key | `...` | same as above (shown once) |
| **Connect AWS** → region | `us-east-1` | same as above |
| **Connect GitHub** → token | `github_pat_...` | Step 0 → **Fine-grained token** (Actions read/write + Metadata read-only) |
| **Connect GitHub** → repo | `<YOU>/golden-image-pipeline` | your fork |

Keep these in your password manager — the app shows them only once when you save.

### 4. Local Build Test

```bash
# Requires valid AWS credentials in ~/.aws
./scripts/packer-build.sh amazon-linux shared
./scripts/packer-build.sh ubuntu shared          # any of the 5 OS
```

### 5. Trigger via GitHub Actions

- **Push to main** → auto-builds base image (Amazon Linux by default)
- **Manual trigger** → `Actions` tab → `Build Golden Image` → `Run workflow`
  - Choose OS, customer
  - `base_packages`: comma-separated packages for the base layer
  - `custom_packages`: comma-separated packages for the customized layer
  - `source_ami`: reuse an existing base AMI (skips the base build for customized builds)
  - `base_ami`: alternate source AMI for fresh base builds
  - `os_type=other`: requires `base_ami` (the source image); `ssh_username` defaults to `ec2-user`
- Customized builds use `source_ami` when provided, otherwise build a base first and layer on it

## Web UI

Production-grade Flask web app with multi-user auth, per-user AWS/GitHub credential store, and live build tracking.

### Ways to run the app

> **Prerequisite — common to ALL methods:** before you pick a method below,
> you must do the [Quick Start](#quick-start) steps **0–2** above once —
> they set up the GitHub repo + token, the AWS IAM/OIDC role, and the repo
> secrets. Those steps are the **same for Method 1, 2, and 3**; they are not
> method-specific. Steps **4–5** (local build test / manual trigger) are
> optional extras you can skip.

Same app, three ways. After the common Quick Start above, run it as:

| Method | Best when | Run instructions |
|--------|-----------|------------------|
| 1. **Docker (container)** | you want it running in minutes, anywhere containers run (Docker/Podman/LXD) — no repo, no build, no VM — the recommended option | [☞ Method 1 — Docker](#method-1-docker-recommended) |
| 2. **EC2 instance** | you want it hosted in the cloud with a public URL, reachable from anywhere | [☞ Method 2 — EC2 instance](#method-2-ec2-instance) |
| 3. **Local Python** | fast development and quick checks without containers | [☞ Method 3 — Local Python](#method-3-local-python) |

### Method 1: Docker (recommended)

Run the **prebuilt container image** — no repo, no build, no VM setup, no config
files. It's a standard OCI image, so it runs anywhere containers run: **Docker,
Podman, containerd (CRI-O), and LXD (LXC)**.

**Out of the box — just pull & run (zero config, defaults work):**

```bash
docker run -d --name golden-image-pipeline --restart unless-stopped \
  -p 8080:8080 \
  -v golden-image-data:/app/data \
  ghcr.io/azlabgen2025/z-golden-image-pipeline:latest
```

That's it — pull and run. Open `http://localhost:8080` (or `http://<host-ip>:8080`)
and log in with `admin` / `admin`. The image:

- **Defaults to plain HTTP on port 8080** with `admin`/`admin` login (change the
  password via the **Password** menu after first login).
- **HTTPS is automatic** when you mount certs at `/app/certs` (generate once with
  `./scripts/gen-cert.sh certs ...` for your IP/hostname).
- **Data persists** in the named `golden-image-data` volume (SQLite DB + encryption key).
- Contains the **whole pipeline toolchain** (AWS CLI v2, Packer, Ansible, git, ssh, jq),
  so you can drive `aws`/`packer`/`ansible` from inside the container.
- Is **public** — pulls need no login.
- Is rebuilt automatically on every push to `main` (workflow `publish-image.yml`).

**One-command helper (VMs/EC2/LAN with a public IP):**

```bash
# Installs Docker once, pulls the image, and starts it on a public IP:
#   HTTP on 8080:
curl -fsSL https://raw.githubusercontent.com/azlabgen2025/z-golden-image-pipeline/main/scripts/run-docker-aws.sh | sudo bash -s <public-ip-or-dns>
#   HTTPS on 443 (self-signed cert):
curl -fsSL https://raw.githubusercontent.com/azlabgen2025/z-golden-image-pipeline/main/scripts/run-docker-aws.sh | sudo bash -s <public-ip-or-dns> --https
```

**Security Group gotcha (any cloud VM):** default security groups only open SSH (22).
To reach the app you must also open **8080 (HTTP)** or **443 (HTTPS)** — the #1
reason fresh VM or EC2 container deployments "don't work".

**(Optional) Source build — full toolbox, needs the repo:**

```bash
docker compose up -d --build            # or: ./scripts/run-web.sh docker
```

- **Access**: `https://localhost:8080` — or from any machine on your LAN via the
  **host machine's IP**: `https://<host-ip>:8080` (e.g. `https://192.168.1.216:8080`).
  Change the host port with `APP_PORT=9090 docker compose up -d`.
- **HTTPS** is automatic when `certs/tls.crt`+`certs/tls.key` are present (the
  `./certs` volume) — plain `http://` otherwise.
- **Data** (SQLite DB + encryption key) persists in the `golden-image-data` volume.
- **AWS creds** from `~/.aws` are mounted read-only so `aws`, `packer`, and `ansible`
  work inside the container. Mount `.` at `/workspace` (read-only) to run ad-hoc
  `packer validate` / `ansible-playbook --syntax-check` against the repo.
- **Health**: `GET /api/health` → `{"status":"ok"}` (also the container HEALTHCHECK).

### Method 2: EC2 instance

The web UI is the control plane: you log in, paste the AWS account + GitHub
token into the app's Settings, and it dispatches real builds to GitHub Actions.

```bash
# on the EC2 box (Ubuntu 24.04, e.g. t3.medium), with your public IP/DNS:
ssh ubuntu@<box-ip>
bash -s < scripts/setup-ec2.sh https://github.com/<YOU>/golden-image-pipeline.git <box-public-ip>
```

`scripts/setup-ec2.sh` (in this repo) does everything in one shot:
1. Installs Docker, Compose, git, openssl
2. Clones the repo to `/opt/golden-image-pipeline`
3. Generates a self-signed TLS cert for the box's public IP
4. Writes `/opt/golden-image-pipeline/.env` with a random admin password
5. Runs `docker compose up -d --build` on **port 443**

Then:

- Open **`https://<box-ip>/`** (the self-signed browser warning is expected — click through)
- Health check: `curl -sk https://<box-ip>/api/version`
- Log in as `admin` / the password printed by the script
- In **Settings/Connect AWS**: add an AWS account (access key + secret, region) — these are stored
  Fernet-encrypted at rest; create the access keys in the AWS account where the golden images
  will be built
- In **Settings/Connect GitHub**: paste a PAT (Actions scope) + `YOU/golden-image-pipeline`
- Dispatch a build from **Section 1** (base) or **Section 2** (customized) and watch it live in
  **Build Jobs**

Security notes:
- The instance should be **stopped when not in use** (`docker compose stop` keeps the data volume;
  `docker compose start` resumes it). Stopping the **EC2 instance itself** also works
  (`aws ec2 stop-instances` or the console), and it starts again on demand.
- Use a dedicated security group open only to the ports you need (443 or 22), ideally
  source-restricted to your own trusted IP ranges.
- The default admin password is random per deploy (from `.env`). Change it in the app once logged in.

### Method 3: Local Python

```bash
./scripts/gen-cert.sh certs localhost 127.0.0.1   # one-time; enables HTTPS automatically
./scripts/run-web.sh                              # HTTPS if certs exist, else HTTP
```

- **Fresh start anytime:** `./scripts/reset.sh` stops the app, wipes the DB + caches, recreates a pristine DB (only `admin`/`admin`), and starts it. Use `./scripts/reset.sh --no-start` to reset without launching, or `./scripts/reset.sh docker` for Docker.
- Responses are served as **no-cache, always fresh** (`Cache-Control: no-store`), so a plain refresh (or `Cmd+Shift+R` if the tab is old) always shows the latest version — no stale modal/page bugs.

- Open `https://localhost:8080` (self-signed browser warning is expected) or `http://localhost:8080` if no certs
- Default admin login: `admin` / `admin` — no forced change on login; a non-blocking banner reminds you to set a new password (use the **Password** menu). New/reset users land straight in the app too.
- Config via env vars: `ADMIN_USER`, `ADMIN_PASSWORD`, `DATABASE_PATH`, `SECRET_KEY_FILE`, `FLASK_SECRET`, `PORT`, `FLASK_DEBUG` (default `false`), `CUSTOMER`, `DEFAULT_OS`
- AWS keys entered in the UI are encrypted at rest (Fernet) in SQLite
- GitHub connection is per-user, stored encrypted (needs a PAT with `workflow` scope)
- For any port other than 8080: `PORT=8090 ./scripts/run-web.sh`

### Feature walkthrough

- **Login/auth**: session-based, admin role creates/resets/deletes users. Login is never blocked: `admin`/`admin` (or any user) signs straight into the app, and a dismissible banner and the **Password** menu cover changing passwords whenever you're ready.
- **User management**: only admins can access it. The **Users** dialog lists existing users and user creation is opt-in via the "＋ Add New User" button (nothing is forced — you can create users later). Username must be 3-32 chars (`A-Z a-z 0-9 . _ -`), role must be `user` or `admin`, passwords ≥ 8 chars. New/reset users must set their own password on next login. Admins cannot be deleted and you cannot delete your own account.
- **Connection status panel**: shows whether the logged-in user's AWS account and GitHub connection are live (account ID, region, repo) — with Connect buttons on launch
- **Multi-user**: each user has their own AWS accounts (access keys stored encrypted) and GitHub PAT
- **Connect AWS**: add/activate/delete accounts; active account is shown and used for builds; optional `role_arn` for temporary-credential workflows
- **Connect GitHub**: verify a PAT + repo (build-image.yml must exist in that repo)
- **Build**: choose OS image, base or customized layer, packages, optional AMI name (e.g. `golden-acme-app`) and extra tags (`Environment=prod,Team=payments`)
- **Jobs**: every build is recorded in the DB with live status polled from the GitHub run (run ID + URL link), via `GET /api/jobs`
- **Images**: browse golden AMIs in the connected AWS account (`OS`, `customer`, `layer` tags)
- **Source AMIs**: resolved automatically from `config/source_amis.json` at build time; edit that file (verified patterns in `Supported Images`) when OS vendors publish updates

## Production readiness

Status: solid for internal/small-team use. The dev Flask server is NOT used in the
container — it serves via **gunicorn** (2 worker processes × 4 threads) with a
`/api/health` readiness probe, auto-generated session secret, persistent data volume,
restart policy, and optional TLS. Remaining gaps before shipping to untrusted/public use:

1. **Real TLS certificate** — currently self-signed (browser warnings). Put nginx/Caddy/ALB with an ACM cert in front, or wire certbot + Let's Encrypt into the container.
2. **Rate limiting / brute-force protection** on the login and change-password endpoints (e.g. `flask-limiter`).
3. **SQLite backups** — add a scheduled `.backup` (the DB lives in the data volume) or move to Postgres for multi-instance.
4. **Secrets rotation/audit** — GitHub PAT and AWS keys are Fernet-encrypted at rest; add rotation reminders and access logging.
5. **CSRF tokens** on POST forms if ever exposed beyond same-origin trusted clients.
6. **AMI lifecycle/retention** — old golden AMIs accumulate under `self`; add cleanup automation.
7. **Source scans** — Trivy / Amazon Inspector on output AMIs (roadmap).

Near-term improvements: `docker compose up -d --build`, add a reverse proxy, wire
Flask-Limiter, add a nightly SQLite backup cron, then re-run the fresh-build matrix.

### Reset / Fresh Start

To wipe all data (users, AWS accounts, GitHub connections, jobs) and start over with a clean default admin:

```bash
# Stop the app, then:
rm -f web/golden_image.db     # recreated on next start with only the admin user
./scripts/run-web.sh
```

Or, in one command: `./scripts/reset.sh` (stops the app, wipes DB/secret key/pycache, creates the pristine DB, and starts it). `./scripts/reset.sh --no-start` resets without launching.

- Fresh DB has exactly one user: `admin` / `admin`. There is no forced login flow — the app opens immediately and a banner reminds you to change the default password via the **Password** button.
- To only reset the admin password without wiping data, start with `ADMIN_RESET=1`:

```bash
ADMIN_RESET=1 python3 web/app.py   # resets admin to admin/admin (forced change) on startup
```

### Run with HTTPS (manual)

Self-signed certs (for local/LAN). The browser will show a "not secure" warning because it's self-signed — click through to the app.

```bash
./scripts/gen-cert.sh certs localhost 127.0.0.1 <your-lan-ip>
TLS_CERT=certs/tls.crt TLS_KEY=certs/tls.key python3 web/app.py   # https://localhost:8080
```

If no `TLS_CERT`/`TLS_KEY` are set, the app serves plain HTTP (no cert required). Using `./scripts/run-web.sh` does this automatically.

### Run directly

```bash
cd web
python3 app.py        # dev (debug off by default)
gunicorn -w 2 -b 0.0.0.0:8080 app:app   # production
```

For an externally reachable HTTPS deployment, put a reverse proxy (Caddy/nginx) in front and let it handle real certificates.

## Supported Images

Source AMIs and their AWS account owners are centralized in `config/source_amis.json` and refreshed automatically before each GitHub Actions build ("Resolve Latest Source AMI" step). When an OS vendor publishes a new AMI, no code change is needed — the newest matching image is picked up automatically.

| OS | Packer Dir | Playbook | SSH User | AMI Owner | Free Tier | Build status |
|----|-----------|----------|----------|-----------|-----------|--------------|
| Amazon Linux 2023 | `packer/amazon-linux/` | `ansible/base/amazon-linux.yml` | ec2-user | amazon | ✅ | ✅ verified green |
| Ubuntu 24.04 | `packer/ubuntu/` | `ansible/base/ubuntu.yml` | ec2-user | Canonical | ✅ | ✅ verified green |
| Debian 12 | `packer/debian/` | `ansible/base/debian.yml` | ec2-user | Debian | ✅ | ✅ verified (CI green after BDM fix) |
| Debian 13 | `packer/debian-13/` | `ansible/base/debian.yml` | ec2-user | Debian | ✅ | ⏳ added, build pending |
| Rocky Linux 9 | `packer/rocky/` | `ansible/base/rocky.yml` | ec2-user | Rocky | ✅ (needs 1× Marketplace subscribe) | ✅ verified green |
| Rocky Linux 10 | `packer/rocky-10/` | `ansible/base/rocky.yml` | ec2-user | Rocky | ✅ (needs Marketplace subscribe, SKU `7istt4u6drf5udz02zdppptuy`) | ✅ verified green |
| Fedora | `packer/fedora/` | `ansible/base/fedora.yml` | ec2-user | Fedora | ✅ | ✅ verified green |
| RHEL 9 | `packer/rhel/` | `ansible/base/rhel.yml` | ec2-user | Red Hat (AWS-published) | ✅ free hourly images | ✅ verified green |
| RHEL 10 | `packer/rhel-10/` | `ansible/base/rhel.yml` | ec2-user | Red Hat (AWS-published) | ✅ free hourly images | ✅ verified green |
| AlmaLinux 9 | `packer/almalinux/` | `ansible/base/almalinux.yml` | ec2-user | AlmaLinux | ✅ (needs 1× Marketplace subscribe) | ✅ verified green |
| AlmaLinux 10 | `packer/almalinux-10/` | `ansible/base/almalinux.yml` | ec2-user | AlmaLinux | ✅ (needs 1× Marketplace subscribe) | ✅ verified green |
| Other | `packer/other/` | `ansible/base/other.yml` | configurable (default ec2-user) | you specify | depends on source | depends on source |

**Unified login:** Every golden image creates a standard `ec2-user` account with passwordless sudo and SSH access. After launching any golden AMI with a keypair, log in as `ec2-user` regardless of the OS.

### Build gotchas (all hit during round-1 testing)

- **Debian (12 & 13): block-device name is `/dev/xvda`** (not `/dev/sda1`). A mismatched `launch_block_device_mappings` override makes the instance fail to boot and silently drop port 22 — literally indistinguishable from an SSH timeout. Keep the template's device_name aligned with the AMI's actual root device.
- **Debian (12 & 13), AlmaLinux (9 & 10) and RHEL 10 reject ED25519 SSH keys.** AWS/Packer default keypairs are ED25519, which Ubuntu/Amazon Linux/Rocky/Fedora/RHEL 9 accept but these images' cloud-init ignores. The workflow injects an RSA keypair for those `os_type`s (requires `ec2:ImportKeyPair` in `GoldenImagePackerPolicy`, already added live and in `setup-aws.sh`). Packer still connects as the OS bootstrap user internally; the playbook copies that key into the standard `ec2-user` account at build time.
- **Rocky & AlmaLinux images come from AWS Marketplace** (free), **one SKU per major version**. First build fails with `OptInRequired` until the product terms are accepted once; links are surfaced in the web UI. Rocky 9 SKU `3qk9e6x2ni81uiqnorll45r3f`, Rocky 10 SKU `7istt4u6drf5udz02zdppptuy`, AlmaLinux SKU `3kukoxmnoighcsbjd0u4nq9ds`.
- **RHEL 9/10 use AWS-published free hourly images** — no Marketplace opt-in needed. (A separate paid "RHEL 9/10" Marketplace product exists, but the pipeline targets the free AWS-published images.)
- **Fedora image names** are `Fedora-Cloud-Base-AmazonEC2.x86_64-<release>-<build>.0` (dot before `x86_64`); bump the release number in `config/source_amis.json` + `packer/fedora/main.pkr.hcl` each cycle. Default AMI name is `golden-fedora-43-base`.
- **Rocky/Alma default instance type is `t3.small`** (their Marketplace product rejects `t2.micro`); other OSes stay on `t2.micro`.

## Project Structure

```
golden-image-pipeline/
├── packer/
│   ├── amazon-linux/
│   ├── ubuntu/
│   ├── debian/
│   ├── debian-13/
│   ├── rocky/
│   ├── rocky-10/
│   ├── almalinux/
│   ├── almalinux-10/
│   ├── rhel/
│   ├── rhel-10/
│   ├── fedora/
│   └── other/               # generic template for "other" OS
│       ├── variables.pkr.hcl
│       └── main.pkr.hcl    # extra_tags merged into AMI tags
├── config/
│   └── source_amis.json    # central source-AMI registry (name pattern, owners)
├── ansible/
│   └── base/               # per-OS playbooks
web/
    ├── app.py              # Flask app (routes, sessions, JSON API)
    ├── db.py               # SQLite (users, aws_accounts, github_connections, jobs)
    ├── crypto.py           # Fernet encryption for secrets at rest
    ├── aws_utils.py        # boto3 per-account sessions, images, AMI resolution
    ├── github.py           # GitHub Actions dispatch + run status
    ├── templates/          # login.html, index.html
    └── requirements.txt    # flask, cryptography, boto3, requests, gunicorn
scripts/
    ├── setup-aws.sh        # IAM/OIDC setup
    ├── setup-ec2.sh        # one-shot EC2 deploy (clone→certs→.env→compose)
    ├── run-docker-aws.sh   # pull-and-run prebuilt GHCR image (no build/clone)
    ├── packer-build.sh     # local build helper
    ├── gen-cert.sh         # self-signed TLS cert generator
    ├── run-web.sh          # run app (local/docker), auto-enables HTTPS
    └── reset.sh            # full fresh start: stop, wipe DB/caches, recreate, run
    └── docker-entrypoint.sh # container entrypoint, auto-detects certs
Dockerfile
docker-compose.yml
.github/workflows/
    └── build-image.yml     # multi-OS workflow (inputs: ami_name, ami_tags, aws_region, aws_role_to_assume)
```

## Adding a New Package to Catalog

1. Add package name to `PACKAGE_CATALOG` in `web/app.py`
2. Amazon Linux: ensure it exists in `yum/dnf` repos
3. Test locally: `./scripts/packer-build.sh amazon-linux shared`

## Cost Notes (Free Tier)

| Resource | Cost |
|----------|------|
| t2.micro build instance (most OSes) | Free (750 hrs/month) |
| t3.small build instance (Rocky/Alma) | ~$2.65/month (below free-tier t3.small ceiling at 750h) |
| 20 GB gp3 volume | Free (30 GB allowance) |
| AMI storage | 1 AMI free |
| GitHub Actions | Free (2000 min/month public) |
| RHEL 9/10 (AWS-published hourly) | Free image; instance still billed as normal |
| Rocky/Alma Marketplace | Free subscribe |

## Roadmap

- [x] Amazon Linux, Ubuntu, Debian 12, Rocky 9/10, Fedora, RHEL 9/10, AlmaLinux 9/10 base images (verified green)
- [x] First per-OS build test rounds (every failure classified & fixed — see Supported Images)
- [x] AlmaLinux 9/10 + RHEL 10 + Rocky 10 green (one-time Marketplace subscribes)
- [x] Fedora AMI name corrected (`golden-fedora-43-base`)
- [x] Full cost-save cleanup (all AMIs/snapshots/keypairs/SGs removed) — images reproducible on demand
- [x] Docker toolbox image (AWS CLI/Packer/Ansible/git + gunicorn, `/api/health`, auto-TLS)
- [x] Debian 13 packer template + web-UI option (config verified, build pending)
- [ ] Debian 13 + fresh-build verification run
- [ ] Production hardening (see "Production readiness" — reverse proxy/TLS, rate limiting, DB backups)
- [ ] Customer-specific AMI sharing
- [ ] Security scanning (Trivy/Amazon Inspector)
- [ ] Department image layering

## License & Copyright

Copyright (c) 2026 Deepesh Rajpal.

This Source Code Form is subject to the terms of the Mozilla Public License,
v. 2.0 (MPL-2.0). A copy is in the [LICENSE](./LICENSE) file at the repo root,
and you can also obtain it at <https://mozilla.org/MPL/2.0/>. You may use,
modify, and distribute this project under the terms of that license — including
for commercial use. Changes you make to the project's original source files
must be distributed under MPL-2.0; new files you add around it may carry terms
of your choosing.

All trademarks, service marks, and product names are the property of their
respective owners. Third-party components remain under their own licenses.

Contact: Deepesh Rajpal (via this repository).