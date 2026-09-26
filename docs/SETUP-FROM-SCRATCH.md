# Setup from scratch — complete guide for a non-expert

Follow the steps in order. Each step is one block you can copy and paste.
Total time: about 30 minutes, most of it waiting.

**You need:** a GitHub account, an AWS account, and one EC2 Ubuntu server.

---

## Step 0 — Start the EC2 server (AWS console)

In the AWS console: **EC2 → Instances → Launch instance**

| Setting | Value |
|---|---|
| Name | `golden-pipeline` |
| Image | **Ubuntu Server 24.04 LTS** (x86_64) |
| Instance type | **t3.medium** or larger (t3.small may run out of memory) |
| Key pair | Create or pick one — you need it to SSH in |

**Important — the firewall (Security Group).** While creating, or afterwards via
**Security Groups → Edit inbound rules**, add:

| Type | Port | Source |
|---|---|---|
| SSH | 22 | My IP |
| Custom TCP | 8080 | Anywhere (`0.0.0.0/0`) |

Without the 8080 rule the app runs but you cannot open it in a browser.

Click **Launch instance**, then wait until the state says **Running** and copy the
**Public IPv4 address** (looks like `3.14.15.16`).

Open the app on **port 8080** for the rest of this guide.

---

## Step 1 — Log in to the server

On your own computer (not the server), open Terminal and run — replace the two
values:

```bash
ssh -i ~/Downloads/golden-pipeline.pem ubuntu@YOUR.SERVER.IP.ADDRESS
```

- macOS: if it complains the key is too open, run
  `chmod 400 ~/Downloads/golden-pipeline.pem` and try again.
- Windows: use **MobaXterm** or Windows Terminal with the `.pem` key.

You should now see a prompt ending in `ubuntu@ip-...:~$`. **Everything from here
on is typed into that window.**

---

## Step 2 — Install the tools you need

Copy and paste this whole block:

```bash
sudo apt-get update
sudo apt-get install -y git curl unzip zip openssh-client awscli
git --version
aws --version
```

You should see a version number for both `git` and `aws`.

> If `aws --version` shows **`aws-cli/1.x`**, that is fine — everything here
> works with it. To get the newer version 2 instead, run this instead of the
> `awscli` line above, before Step 3:
> ```bash
> curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
> unzip -o awscliv2.zip && sudo ./aws/install
> ```

Now install the GitHub helper tool:

```bash
curl -fsSL https://raw.githubusercontent.com/cli/cli/trunk/scripts/gh-installer.sh | bash
gh --version
```

---

## Step 3 — Tell the AWS CLI who you are

Go to the AWS console → **IAM → Users → Create user**.

- User name: `golden-admin`
- Tick **"Give this user access to AWS resources directly"**
- Permissions: search and attach **AdministratorAccess**
- Click **Create user**

Then open that user → **Security credentials** → **Create access key** →
choose **Command Line Interface** → **Create**. Copy the two values that appear
(the Access key ID looks like `AKIA...` and the Secret access key is a long
string). **The secret is shown only once — copy it somewhere safe now.**

Back in your SSH window, run:

```bash
aws configure
```

It asks four questions. Answer:

```
AWS Access Key ID [none]: AKIA...          <- paste yours
AWS Secret Access Key [none]:              <- paste yours
Default region name [none]: us-east-1
Default output format [none]:              <- just press Enter
```

Confirm it worked:

```bash
aws sts get-caller-identity
```

You should see your **Account** and **Arn**. If you get an error, the keys are
wrong — repeat this step.

---

## Step 4 — Log in to GitHub from the server

```bash
gh auth login
```

It will ask:

1. `GitHub.com` → choose **GitHub.com**
2. `HTTPS` → choose **HTTPS**
3. `Login with a web browser` → choose **Y**

It then prints a **one-time code** like `XXXX-XXXX`. On your **own computer**,
open <https://github.com/login/device>, type that code, and press **Authorize**.

Back on the server, it should say `Logged in as YOUR-GITHUB-USERNAME`.

Check it:

```bash
gh auth status
```

---

## Step 5 — Tell the scripts your name

Copy and paste this block, changing **only the first line** to your real
GitHub username:

```bash
export GH_USER="your-github-username"
export REPO="z-golden-image-pipeline"
export REGION="us-east-1"
export MY_IP="YOUR.SERVER.IP.ADDRESS"
```

From here on, every command below is copy-pasteable as-is.

---

## Step 6 — Get the project onto your GitHub account

Copy and paste this whole block:

```bash
cd ~
git clone https://github.com/azlabgen2025/z-golden-image-pipeline.git
cd z-golden-image-pipeline
git remote rename origin upstream
gh repo create "$REPO" --public --source . --remote origin --push
```

This copies the project into a **new public repository under your own account**.
It is your own copy, not a fork, so GitHub Actions is switched on by default.

Confirm:

```bash
gh repo view --json nameWithOwner -q .nameWithOwner
```

It must print **your-username/z-golden-image-pipeline**.

---

## Step 7 — One command to finish the setup

This creates the AWS role, the security key, and the two GitHub secrets:

```bash
cd ~/z-golden-image-pipeline
./scripts/bootstrap.sh "$GH_USER/$REPO" "$REGION"
```

It takes a minute or two. You should see `[1/3]`, `[2/3]`, `[3/3]`, then a
"Setup finished" summary with a login URL.

> **This is the step that goes wrong most often.** The name you passed —
> `your-username/z-golden-image-pipeline` — is written into the AWS security
> settings. If you accidentally pass `azlabgen2025/z-golden-image-pipeline`
> instead, your builds will fail later with a credentials error.

---

## Step 8 — Check it worked

```bash
./scripts/verify-setup.sh "$GH_USER/$REPO" "$REGION"
```

Scroll to the bottom. You want:

```
pass=18  warn=0  fail=0
Ready to build. Start with amazon-linux
```

**If you see `fail=` anything above 0**, copy the whole output and send it to
whoever helped you — each failure line prints the exact command that fixes it.
The most common one is a trust policy pointing at the wrong repository; the fix
is simply to re-run Step 7.

---

## Step 9 — Start the app

```bash
sudo ./scripts/run-docker-aws.sh "$MY_IP"
```

It installs Docker, pulls the app, and prints something like:

```
URL:   http://3.14.15.16:8080
Login: admin / <a long random password>
```

**Open that URL in your browser and log in** with the `admin` user and the
password it printed. Write the password down — it is only shown once.

If the page will not load, it is almost always the firewall: confirm the 8080
inbound rule from Step 0 exists.

To see the password again later:

```bash
grep ADMIN_PASSWORD /opt/golden-image-pipeline/.env
```

---

## Step 10 — Connect the app to your accounts

Inside the app, open **Settings**:

**Connect AWS** — paste the same access key ID and secret from Step 3. This is
only used to list your images; the builds themselves do not use it.

**Connect GitHub** — create a token first:

1. On your own computer, go to
   <https://github.com/settings/personal-access-tokens/new>
2. Name it `golden-builds`, set an expiry, and choose **Only select
   repositories** → pick your new `z-golden-image-pipeline` repo
3. Under **Repository permissions**: set **Actions = Read and write** and
   **Metadata = Read-only**
4. Click **Generate token** and copy the `github_pat_...` value (shown once)
5. Paste it into the app, with your repo as `your-username/z-golden-image-pipeline`
   — no `https://`, just `username/repo`

> If the app says **404** on Connect GitHub, it is almost always the two
> permissions above. Re-check Actions = Read and write.

---

## Step 11 — Run your first build

In the app, start a build of **amazon-linux** in **us-east-1**. It takes roughly
10-15 minutes.

Watch it run under the **Jobs** tab. A finished job shows a green check and the
new AMI name.

**Do not start with Rocky or AlmaLinux** on your first run — those need a
one-time free Marketplace subscription in the AWS console. amazon-linux, ubuntu
and debian need nothing extra.

---

## If something goes wrong

Run this and send the output:

```bash
./scripts/verify-setup.sh "$GH_USER/$REPO" "$REGION"
```

Also useful:

| Symptom | What to do |
|---|---|
| Build fails, "credentials could not be loaded" | Re-run Step 7 with **your** repo name, then Step 8 |
| App page will not open | Check the 8080 inbound rule in Step 0 |
| Forgot the admin password | `grep ADMIN_PASSWORD /opt/golden-image-pipeline/.env` |
| Connect GitHub returns 404 | Fix the two token permissions in Step 10 |
| "VcpuLimitExceeded" | Stop old instances, or ask AWS to raise the limit |
| Want to start completely over | Delete your GitHub repo and repeat from Step 6 |
