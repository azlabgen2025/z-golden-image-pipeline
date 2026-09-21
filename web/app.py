# Golden Image Pipeline
# Copyright (c) 2026 Deepesh Rajpal. All rights reserved.
# See NOTICE at the repo root for terms.

import os
import re
import json
from functools import wraps

from flask import Flask, render_template, request, jsonify, session, redirect, url_for

import db
import github
import aws_utils
from crypto import encrypt_secret, decrypt_secret

_RUN_NAME_RE = re.compile(r"\(([^)]+)\)\s*\.?$")

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET", "dev-secret-change-me")


def _load_version():
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "version.json")) as fh:
            return json.load(fh)
    except Exception:
        fallback = {"version": "0.0.0", "build": "n/a", "commit": "dev", "date": "unknown", "marker": "build dev"}
        return fallback


APP_VERSION = _load_version()


@app.context_processor
def inject_version():
    return {"APP_VERSION": APP_VERSION}

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
CUSTOMER = os.environ.get("CUSTOMER", "shared")

_BASE_TOOLS = ["git", "vim", "htop", "jq", "tree", "unzip", "tar"]
_dev = lambda *pkgs: {"Dev Tools": list(pkgs)}
_web = lambda *pkgs: {"Web Servers": list(pkgs)}
_mon = lambda *pkgs: {"Monitoring": list(pkgs)}
_sec = lambda *pkgs: {"Security": list(pkgs)}
_db = lambda *pkgs: {"Databases": list(pkgs)}


def _cat(groups):
    return {"Base Tools": list(_BASE_TOOLS), **groups}


# Curated per-OS package checklists for the build form. These are real dnf/apt
# package names available in each distro's DEFAULT repos. The build is
# strict at provision time: if a requested custom package cannot be installed,
# the build FAILS listing exactly which package and why. We only OFFER
# names proven to install in each distro's default repos (validated in the
# all-11-green validation matrix). Update as distros change.
OS_PACKAGE_GROUPS = {
    "amazon-linux": _cat(_dev("docker", "nodejs", "podman")
                         | _web("httpd")
                         | _mon("amazon-cloudwatch-agent")
                         | _sec("fail2ban", "aide", "rkhunter")
                         | _db("mariadb", "redis", "sqlite3")),
    "ubuntu": _cat(_dev("docker.io", "nodejs", "golang")
                   | _web("nginx")
                   | _mon("prometheus-node-exporter")
                   | _sec("fail2ban", "aide", "rkhunter")
                   | _db("postgresql", "redis", "sqlite3")),
    "debian": _cat(_dev("docker.io", "nodejs", "golang")
                   | _web("nginx")
                   | _mon("prometheus-node-exporter")
                   | _sec("fail2ban", "aide", "rkhunter")
                   | _db("postgresql", "mariadb", "redis", "sqlite3")),
    "debian-13": _cat(_dev("docker.io", "nodejs", "golang")
                      | _web("nginx")
                      | _mon("prometheus-node-exporter")
                      | _sec("fail2ban", "aide", "rkhunter")
                      | _db("postgresql", "redis", "sqlite3")),
    "rocky": _cat(_dev("python3", "python3-pip", "nodejs", "golang")
                  | _web("nginx")
                  | _mon("prometheus-node-exporter")
                  | _sec("fail2ban", "aide", "rkhunter")
                  | _db("postgresql", "mariadb", "redis", "sqlite3")),
    "rocky-10": _cat(_dev("python3", "python3-pip", "nodejs", "golang")
                     | _web("nginx")
                     | _mon("prometheus-node-exporter")
                     | _sec("fail2ban", "aide", "rkhunter")
                     | _db("postgresql", "mariadb", "valkey", "sqlite3")),
    "rhel": _cat(_dev("python3", "python3-pip", "nodejs", "golang")
                 | _web("nginx")
                 | _mon("prometheus-node-exporter")
                 | _sec("fail2ban", "aide", "rkhunter")
                 | _db("postgresql", "redis", "sqlite3")),
    "rhel-10": _cat(_dev("python3", "python3-pip", "nodejs", "golang")
                    | _web("nginx")
                    | _mon("prometheus-node-exporter")
                    | _sec("fail2ban", "aide", "rkhunter")
                    | _db("postgresql", "valkey", "sqlite3")),
    "fedora": _cat(_dev("python3", "python3-pip", "nodejs", "golang")
                   | _web("nginx")
                   | _mon("prometheus-node-exporter")
                   | _sec("fail2ban", "aide", "rkhunter")
                   | _db("postgresql", "mariadb", "redis", "sqlite3")),
    "almalinux": _cat(_dev("python3", "python3-pip", "nodejs", "golang")
                      | _web("nginx")
                      | _mon("prometheus-node-exporter")
                      | _sec("fail2ban", "aide", "rkhunter")
                      | _db("postgresql", "mariadb", "redis", "sqlite3")),
    "almalinux-10": _cat(_dev("python3", "python3-pip", "nodejs", "golang")
                         | _web("nginx")
                         | _mon("prometheus-node-exporter")
                         | _sec("fail2ban", "aide", "rkhunter")
                         | _db("postgresql", "mariadb", "valkey", "sqlite3")),
    "other": {},
}

OS_OPTIONS = ["amazon-linux", "ubuntu", "debian", "debian-13", "rocky", "rocky-10",
              "fedora", "rhel", "rhel-10", "almalinux", "almalinux-10"]

OS_LABELS = {
    "amazon-linux": "Amazon Linux 2023",
    "ubuntu": "Ubuntu 24.04 LTS",
    "debian": "Debian 12",
    "debian-13": "Debian 13",
    "rocky": "Rocky Linux 9",
    "rocky-10": "Rocky Linux 10",
    "fedora": "Fedora",
    "rhel": "Red Hat Enterprise Linux 9",
    "rhel-10": "Red Hat Enterprise Linux 10",
    "almalinux": "AlmaLinux 9",
    "almalinux-10": "AlmaLinux 10",
}

OS_ALIASES = {
    "amazon linux": "amazon-linux", "amazon linux 2023": "amazon-linux",
    "amzn": "amazon-linux", "ubuntu": "ubuntu", "ubuntu 22": "ubuntu",
    "ubuntu 22.04": "ubuntu", "ubuntu 24": "ubuntu", "ubuntu 24.04": "ubuntu",
    "debian": "debian", "debian 12": "debian", "debian 13": "debian-13",
    "trixie": "debian-13", "rocky": "rocky",
    "rocky linux": "rocky", "rocky 9": "rocky", "rocky linux 9": "rocky",
    "rocky 10": "rocky-10", "rocky linux 10": "rocky-10", "fedora": "fedora",
    "rhel": "rhel", "red hat": "rhel", "redhat": "rhel",
    "red hat enterprise linux": "rhel", "rhel 9": "rhel",
    "red hat enterprise linux 9": "rhel", "rhel 10": "rhel-10",
    "red hat enterprise linux 10": "rhel-10",
    "almalinux": "almalinux",
    "alma linux": "almalinux", "alma": "almalinux",
    "almalinux 9": "almalinux", "alma linux 9": "almalinux",
    "almalinux 10": "almalinux-10", "alma linux 10": "almalinux-10",
}

# Map AMI OS tags (set by packer templates) to canonical os_type keys.
# Lowercase match; packer tags should mirror OS_LABELS values exactly so the
# reverse lookup stays 1:1. "RHEL 9"/"RHEL 10" kept for older images.
OS_TYPE_FROM_TAG = {label.lower(): key for key, label in OS_LABELS.items()}
OS_TYPE_FROM_TAG.update({
    "rhel 9": "rhel", "rhel 10": "rhel-10",
    "other / custom": "other", "other": "other",
})

# Base AMI name prefixes matching the packer templates' ami_name defaults.
# Used to derive the layer-2 (customized) default name when none is provided:
# os_type -> "golden-<family>-<release>" (base name minus the "-base" suffix).
OS_AMI_BASE_NAME = {
    "amazon-linux": "golden-amazon-linux-2023",
    "ubuntu": "golden-ubuntu-2404",
    "debian": "golden-debian-12",
    "debian-13": "golden-debian-13",
    "rocky": "golden-rocky-9",
    "rocky-10": "golden-rocky-10",
    "fedora": "golden-fedora-43",
    "rhel": "golden-rhel-9",
    "rhel-10": "golden-rhel-10",
    "almalinux": "golden-almalinux-9",
    "almalinux-10": "golden-almalinux-10",
}


def default_layer2_ami_name(os_type):
    """Default AMI name for customized (layer-2) builds: golden-<os>-customized-layer2."""
    prefix = OS_AMI_BASE_NAME.get(os_type)
    if not prefix:
        return "golden-customized-layer2"
    return f"{prefix}-customized-layer2"


def os_type_from_tag(tag):
    """Resolve an AMI OS tag (e.g. 'Ubuntu 24.04 LTS') to an os_type key."""
    if not tag:
        return ""
    key = OS_TYPE_FROM_TAG.get(str(tag).strip().lower())
    if key:
        return key
    return OS_ALIASES.get(str(tag).strip().lower(), "")


def os_label(key):
    """Display label for an os_type key (falls back to prettified key)."""
    return OS_LABELS.get(key, key.replace("-", " ").title())


AMI_RE = re.compile(r"^ami-[a-f0-9]{8,}$")


def login_required(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if "user_id" not in session:
            if request.path.startswith("/api/"):
                return jsonify({"status": "error", "message": "Not authenticated"}), 401
            return redirect(url_for("index"))
        return f(*args, **kwargs)
    return wrapper


def get_current_user():
    return db.get_user_by_id(session.get("user_id"))


def _aws_status(user):
    account = db.get_active_aws_account(user)
    if account is None:
        return {"connected": False, "message": "No AWS account configured"}
    ident = aws_utils.account_identity(account)
    if ident["ok"]:
        return {
            "connected": True,
            "account_id": ident["account_id"],
            "arn": ident["arn"],
            "region": ident["region"],
            "account_name": account["name"],
            "message": "Connected",
        }
    return {
        "connected": False,
        "account_name": account["name"],
        "error": ident["error"],
        "message": _aws_error_hint(ident["error"]),
    }


def _aws_error_hint(error_text):
    """Map a raw boto3/STS error to a plain-language fix."""
    e = (error_text or "").lower()
    if "invalidclienttokenid" in e or "signaturedoesnotmatch" in e:
        return ("Credentials are wrong or were deleted. Re-create the access key "
                "in AWS (IAM → user → Security credentials → Create access key) "
                "and paste the new Access Key ID + Secret. Access Key IDs start "
                "with 'AKIA'.")
    if "accessdenied" in e or "not authorized" in e or "unauthorized" in e:
        return ("The key is valid but the IAM user lacks permission. Create the "
                "key for a user with AdministratorAccess (as in Quick Start step 1a).")
    if "mfa" in e:
        return "Your IAM user requires MFA for programmatic calls — the access key alone isn't enough. Use a user without an MFA-for-API policy, or scope its permissions down."
    if ("not enabled" in e) and ("region" in e or "us-east-1" in e):
        return "Check the region field — the app can't reach AWS in that region. It should be e.g. us-east-1."
    return f"Credentials are invalid: {error_text}"


def _github_status(user):
    conn = db.get_github_connection(user["id"])
    if conn is None:
        return {"connected": False, "message": "No GitHub repository connected"}
    token = decrypt_secret(conn["token_enc"])
    if not token:
        return {"connected": False, "message": "GitHub token missing"}
    result = github.verify_connection(token, conn["repo"])
    if result["ok"]:
        return {"connected": True, "repo": conn["repo"], "message": f"Connected to {conn['repo']}"}
    return {"connected": False, "repo": conn["repo"], "error": result.get("error"), "message": "Token invalid or no repo access"}


# ---------------------------------------------------------------------------
# Pages & session auth
# ---------------------------------------------------------------------------

@app.after_request
def no_cache(resp):
    """Never let the browser serve stale HTML/JS — fresh version on every load."""
    resp.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    resp.headers["Pragma"] = "no-cache"
    resp.headers["Expires"] = "0"
    return resp


@app.route("/")
def index():
    if "user_id" not in session:
        return render_template("login.html")
    user = get_current_user()
    return render_template(
        "index.html",
        os_package_groups=OS_PACKAGE_GROUPS,
        os_options=OS_OPTIONS,
        os_labels=OS_LABELS,
        os_type=os.environ.get("DEFAULT_OS", "amazon-linux"),
        region=AWS_REGION,
        customer=CUSTOMER,
        username=user["username"],
        role=user["role"],
        must_change_password=bool(user["must_change_password"]),
    )


@app.route("/notices")
def notices():
    try:
        with open(os.path.join(os.path.dirname(__file__), "..", "NOTICE"), "r") as f:
            notice_text = f.read()
    except OSError:
        notice_text = "NOTICE file not found."
    return render_template("notice.html", notice_text=notice_text)


@app.route("/api/version")
def api_version():
    return jsonify({
        "status": "ok",
        "version": APP_VERSION.get("version", ""),
        "build": APP_VERSION["build"],
        "commit": APP_VERSION["commit"],
        "date": APP_VERSION["date"],
        "marker": APP_VERSION["marker"],
    })


@app.route("/api/health")
def api_health():
    """Liveness/readiness probe for load balancers & the container HEALTHCHECK."""
    try:
        with db.get_conn() as conn:
            conn.execute("SELECT 1").fetchone()
    except Exception:
        return jsonify({"status": "error", "marker": APP_VERSION["marker"]}), 503
    return jsonify({"status": "ok", "marker": APP_VERSION["marker"]})


@app.route("/api/auth/login", methods=["POST"])
def api_login():
    data = request.get_json(silent=True) or {}
    username = (data.get("username") or "").strip()
    password = data.get("password") or ""
    user = db.authenticate(username, password)
    if user is None:
        return jsonify({"status": "error", "message": "Invalid username or password"}), 401
    session.clear()
    session["user_id"] = user["id"]
    return jsonify({
        "status": "ok",
        "username": user["username"],
        "role": user["role"],
        "must_change_password": bool(user["must_change_password"]),
    })


@app.route("/api/auth/logout", methods=["POST"])
def api_logout():
    session.clear()
    return jsonify({"status": "ok"})


@app.route("/api/auth/me", methods=["GET"])
def api_me():
    user = get_current_user()
    if user is None:
        return jsonify({"status": "error", "message": "Not authenticated"}), 401
    return jsonify({
        "status": "ok",
        "user_id": user["id"],
        "username": user["username"],
        "role": user["role"],
        "must_change_password": bool(user["must_change_password"]),
    })


@app.route("/api/auth/change-password", methods=["POST"])
@login_required
def api_change_password():
    data = request.get_json(silent=True) or {}
    current = data.get("current") or ""
    new = data.get("new") or ""
    user = get_current_user()
    if len(new) < 8:
        return jsonify({"status": "error", "message": "New password must be at least 8 characters"}), 400
    if user["must_change_password"] and not current:
        pass
    elif db.authenticate(user["username"], current) is None:
        return jsonify({"status": "error", "message": "Current password is incorrect"}), 400
    db.change_password(user["id"], new)
    return jsonify({"status": "ok", "message": "Password updated"})


# ---------------------------------------------------------------------------
# Admin: user management
# ---------------------------------------------------------------------------

@app.route("/api/users", methods=["GET", "POST"])
@login_required
def api_users():
    user = get_current_user()
    if user["role"] != "admin":
        return jsonify({"status": "error", "message": "Admin access required"}), 403
    if request.method == "GET":
        return jsonify({"status": "ok", "users": [dict(u) for u in db.list_users()]})
    data = request.get_json(silent=True) or {}
    username = (data.get("username") or "").strip()
    password = data.get("password") or ""
    role = data.get("role") or "user"
    if not re.match(r"^[A-Za-z0-9_.-]+$", username) or not (3 <= len(username) <= 32):
        return jsonify({"status": "error", "message": "Username must be 3-32 chars using letters, digits, . _ -"}), 400
    if role not in ("user", "admin"):
        return jsonify({"status": "error", "message": "Role must be 'user' or 'admin'"}), 400
    if not password:
        return jsonify({"status": "error", "message": "Username and password required"}), 400
    if len(password) < 8:
        return jsonify({"status": "error", "message": "Password must be at least 8 characters"}), 400
    try:
        db.create_user(username, password, role)
    except Exception:
        return jsonify({"status": "error", "message": f"User '{username}' already exists"}), 400
    return jsonify({"status": "ok", "message": f"User '{username}' created (must set new password on first login)"})


@app.route("/api/users/<int:user_id>", methods=["DELETE", "POST"])
@login_required
def api_user(user_id):
    user = get_current_user()
    if user["role"] != "admin":
        return jsonify({"status": "error", "message": "Admin access required"}), 403
    if request.method == "DELETE":
        if user_id == user["id"]:
            return jsonify({"status": "error", "message": "Cannot delete your own account"}), 400
        db.delete_user(user_id)
        return jsonify({"status": "ok"})
    data = request.get_json(silent=True) or {}
    action = data.get("action")
    if action == "reset_password":
        new_pass = data.get("new_password") or ""
        if len(new_pass) < 8:
            return jsonify({"status": "error", "message": "Password must be at least 8 characters"}), 400
        db.reset_other_user_password(user_id, new_pass)
        return jsonify({"status": "ok", "message": "Password reset; user must change it on next login"})
    return jsonify({"status": "error", "message": "Unknown action"}), 400


# ---------------------------------------------------------------------------
# Connectivity status (both AWS and GitHub)
# ---------------------------------------------------------------------------

@app.route("/api/status")
@login_required
def api_status():
    user = get_current_user()
    return jsonify({
        "status": "ok",
        "aws": _aws_status(user),
        "github": _github_status(user),
    })


# ---------------------------------------------------------------------------
# AWS account management
# ---------------------------------------------------------------------------

@app.route("/api/aws/accounts", methods=["GET", "POST"])
@login_required
def api_aws_accounts():
    user = get_current_user()
    if request.method == "GET":
        accounts = []
        for acc in db.list_aws_accounts(user["id"]):
            accounts.append({
                "id": acc["id"],
                "name": acc["name"],
                "region": acc["region"],
                "role_arn": acc["role_arn"],
                "is_active": (acc["id"] == user["active_account_id"]),
                "access_key_masked": "****",
            })
        return jsonify({"status": "ok", "accounts": accounts, "active_account_id": user["active_account_id"]})

    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    access_key = (data.get("access_key") or "").strip()
    secret_key = data.get("secret_key") or ""
    region = (data.get("region") or AWS_REGION).strip()
    role_arn = (data.get("role_arn") or "").strip()
    if not name or not access_key or not secret_key:
        return jsonify({"status": "error", "message": "Account name, Access Key, and Secret Key are required"}), 400

    # Validate the keys BEFORE storing, so an account can't be saved as
    # "active" with invalid credentials.
    test = aws_utils.account_identity({
        "access_key_enc": encrypt_secret(access_key),
        "secret_key_enc": encrypt_secret(secret_key),
        "region": region,
    })
    if not test["ok"]:
        hint = _aws_error_hint(test["error"])
        return jsonify({
            "status": "error",
            "message": hint,
            "error": test["error"],
        }), 400

    account_id = db.add_aws_account(
        user["id"], name, encrypt_secret(access_key), encrypt_secret(secret_key), region, role_arn
    )
    if user["active_account_id"] is None:
        db.set_active_account(user["id"], account_id)
    return jsonify({"status": "ok", "message": "AWS account added", "account_id": account_id})


@app.route("/api/aws/accounts/<int:account_id>/activate", methods=["POST"])
@login_required
def api_aws_activate(account_id):
    user = get_current_user()
    acc = db.get_aws_account(account_id)
    if acc is None or acc["user_id"] != user["id"]:
        return jsonify({"status": "error", "message": "Account not found"}), 404
    db.set_active_account(user["id"], account_id)
    return jsonify({"status": "ok", "message": "AWS account activated"})


@app.route("/api/aws/accounts/<int:account_id>", methods=["DELETE"])
@login_required
def api_aws_delete(account_id):
    user = get_current_user()
    acc = db.get_aws_account(account_id)
    if acc is None or acc["user_id"] != user["id"]:
        return jsonify({"status": "error", "message": "Account not found"}), 404
    db.delete_aws_account(account_id)
    if user["active_account_id"] == account_id:
        db.set_active_account(user["id"], None)
    return jsonify({"status": "ok", "message": "AWS account removed"})


# ---------------------------------------------------------------------------
# GitHub connection management
# ---------------------------------------------------------------------------

@app.route("/api/github", methods=["GET", "POST"])
@login_required
def api_github():
    user = get_current_user()
    if request.method == "GET":
        conn = db.get_github_connection(user["id"])
        return jsonify({
            "status": "ok",
            "repo": conn["repo"] if conn else "",
            "connected": conn is not None,
        })
    data = request.get_json(silent=True) or {}
    token = (data.get("token") or "").strip()
    repo = (data.get("repo") or "").strip()
    if not token or not repo:
        return jsonify({"status": "error", "message": "GitHub token and repo (owner/repo) are required"}), 400
    result = github.verify_connection(token, repo)
    if not result["ok"]:
        return jsonify({"status": "error", "message": result["error"]}), 400
    db.set_github_connection(user["id"], encrypt_secret(token), repo)
    return jsonify({"status": "ok", "message": f"Connected to {repo}"})


@app.route("/api/github/test", methods=["POST"])
@login_required
def api_github_test():
    user = get_current_user()
    conn = db.get_github_connection(user["id"])
    if conn is None:
        return jsonify({"status": "error", "message": "No GitHub connection configured"}), 400
    token = decrypt_secret(conn["token_enc"])
    result = github.verify_connection(token, conn["repo"])
    return jsonify(result)


# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------

@app.route("/api/images")
@login_required
def api_images():
    user = get_current_user()
    account = db.get_active_aws_account(user)
    if account is None:
        return jsonify({"status": "error", "message": "No AWS account configured. Connect one first."}), 400
    images, error = aws_utils.describe_images(account)
    if error:
        return jsonify({"status": "error", "message": error}), 502
    for img in images:
        img["os_type"] = os_type_from_tag(img["os"])
    return jsonify({"status": "ok", "images": images})


# ---------------------------------------------------------------------------
# Builds
# ---------------------------------------------------------------------------

@app.route("/api/build", methods=["POST"])
@login_required
def api_build():
    user = get_current_user()
    data = request.get_json(silent=True)
    if data is None:
        return jsonify({"status": "error", "message": "Invalid or missing JSON body"}), 400

    if user["must_change_password"]:
        return jsonify({"status": "error", "message": "Change your password before building images."}), 403

    github_conn = db.get_github_connection(user["id"])
    if github_conn is None:
        return jsonify({
            "status": "error",
            "message": "No GitHub repository connected. Connect GitHub to trigger real builds.",
        }), 400

    os_type = data.get("os_type", "amazon-linux")
    customer = (data.get("customer") or "").strip() or CUSTOMER
    target = data.get("target", "base")
    ssh_username = (data.get("ssh_username") or "").strip() or "ec2-user"
    ami_name = (data.get("ami_name") or "").strip()
    ami_tags = (data.get("ami_tags") or "").strip()
    alt = (data.get("alt_image") or "").strip()
    base_ami = ""

    if os_type == "other":
        if not alt:
            return jsonify({
                "status": "error",
                "message": "OS 'other' selected but no image name or AMI ID provided.",
            }), 400
        if AMI_RE.match(alt):
            base_ami = alt
        else:
            key = alt.lower()
            if key in OS_ALIASES:
                os_type = OS_ALIASES[key]
                base_ami = ""
            else:
                account = db.get_active_aws_account(user)
                resolved = aws_utils.resolve_image_on_aws(account, alt) if account else ""
                if resolved:
                    base_ami = resolved
                else:
                    return jsonify({
                        "status": "error",
                        "message": f"Could not resolve '{alt}' to an AMI on AWS. Try using the AMI ID directly.",
                    }), 400
    else:
        resolved_os, resolved_ami = _parse_alt_image(alt, os_type, user)
        if resolved_os is None:
            return jsonify({
                "status": "error",
                "message": f"Unrecognized image '{alt}'. Provide an AMI ID (ami-...) or a supported OS name: {', '.join(OS_OPTIONS)}.",
            }), 400
        os_type = resolved_os
        base_ami = resolved_ami

    if os_type not in OS_OPTIONS + ["other"]:
        return jsonify({"status": "error", "message": "Invalid OS type"}), 400

    base_packages = data.get("base_packages", [])
    custom_packages = data.get("custom_packages", [])
    source_ami = (data.get("source_ami") or "").strip()
    if target == "customized" and not custom_packages:
        return jsonify({
            "status": "error",
            "message": "No customized packages selected. Select packages or enter comma-separated names.",
        }), 400

    if target == "customized" and not source_ami:
        return jsonify({
            "status": "error",
            "message": "No base golden image selected. Build a base image first (Section 1), then customize it.",
        }), 400

    if target == "customized" and source_ami:
        account = db.get_active_aws_account(user)
        if account is not None:
            base_info, err = aws_utils.describe_single_image(account, source_ami)
            if err:
                return jsonify({
                    "status": "error",
                    "message": f"Could not verify base image {source_ami}: {err}",
                }), 400
            base_os_type = os_type_from_tag(base_info.get("os", "")) if base_info else ""
            if not base_os_type:
                return jsonify({
                    "status": "error",
                    "message": f"Base image {source_ami} has no recognized OS tag; cannot determine the OS to customize.",
                }), 400
            if os_type not in (base_os_type, "other"):
                return jsonify({
                    "status": "error",
                    "message": f"OS mismatch: base image {source_ami} is {os_label(base_os_type)}, "
                               f"but {os_type} was sent. Use a {os_label(base_os_type)} base image for this build.",
                }), 400
            os_type = base_os_type

    account = db.get_active_aws_account(user)
    aws_account_name = account["name"] if account else ""
    aws_role_to_assume = account["role_arn"] if account and account["role_arn"] else ""

    if target == "customized" and not ami_name:
        ami_name = default_layer2_ami_name(os_type)

    token = decrypt_secret(github_conn["token_enc"])
    repo = github_conn["repo"]

    inputs = {
        "os_type": os_type,
        "customer": customer,
        "ssh_username": ssh_username,
        "base_packages": ",".join(base_packages),
        "custom_packages": ",".join(custom_packages),
        "source_ami": source_ami,
        "base_ami": base_ami,
        "ami_name": ami_name,
        "ami_tags": ami_tags,
        "aws_region": account["region"] if account else AWS_REGION,
        "aws_role_to_assume": aws_role_to_assume,
    }

    job_id = db.add_job(
        user["id"], target, os_type, customer, ami_name, ami_tags,
        inputs["aws_region"], aws_account_name, inputs,
    )

    result = github.trigger_workflow_dispatch(token, repo, inputs)
    if not result["ok"]:
        db.update_job_status(job_id, "failed", message=result["error"])
        return jsonify({"status": "error", "message": result["error"]}), 502

    db.update_job_status(
        job_id, "running", message="Workflow dispatched",
        run_id=result.get("run_id"), run_url=result.get("run_url"),
    )
    if result.get("run_id"):
        _sync_job_statuses(user)
    return jsonify({
        "status": "triggered",
        "job_id": job_id,
        "target": target,
        "os_type": os_type,
        "customer": customer,
        "message": "Build dispatched to GitHub Actions. Track progress in the Jobs section.",
    })


def _parse_alt_image(alt, os_type, user):
    if not alt:
        return os_type, ""
    if AMI_RE.match(alt):
        return os_type, alt
    key = alt.lower()
    if key in OS_ALIASES:
        return OS_ALIASES[key], ""
    account = db.get_active_aws_account(user)
    resolved = aws_utils.resolve_image_on_aws(account, alt) if account else ""
    if resolved:
        return os_type, resolved
    return None, None


# ---------------------------------------------------------------------------
# Jobs (submitted builds + live GitHub status)
# ---------------------------------------------------------------------------

def _sync_job_statuses(user):
    """Poll GitHub for run_status of unknown/running jobs and update the DB."""
    github_conn = db.get_github_connection(user["id"])
    if github_conn is None:
        return
    token = decrypt_secret(github_conn["token_enc"])
    repo = github_conn["repo"]
    for job in db.list_jobs(user["id"]):
        if job["run_id"] is None:
            continue
        run, err = github.run_status(token, repo, job["run_id"])
        if run is None:
            continue
        new_status = _map_gh_to_job(run["status"], run["conclusion"])
        if new_status != job["status"]:
            db.update_job_status(
                job["id"], new_status,
                run_id=run["run_id"], run_url=run["run_url"],
                message=run.get("conclusion") or run.get("status") or "",
            )


def _map_gh_to_job(gh_status, conclusion):
    if gh_status == "completed":
        return "success" if conclusion == "success" else ("failed" if conclusion else "cancelled")
    return "running"


def _parse_os_from_run_name(name):
    """Extract the OS from a run name like 'Build Golden Image (amazon-linux)'."""
    m = _RUN_NAME_RE.search(name or "")
    return m.group(1).strip() if m else ""


def _github_runs_as_jobs(user):
    """Surface recent GitHub workflow runs not already tracked in the local DB."""
    github_conn = db.get_github_connection(user["id"])
    if github_conn is None:
        return []
    token = decrypt_secret(github_conn["token_enc"])
    repo = github_conn["repo"]
    runs, err = github.list_runs(token, repo)
    if runs is None:
        return []
    known_ids = {j["run_id"] for j in db.list_jobs(user["id"]) if j["run_id"]}
    jobs = []
    for r in runs:
        run_id = r.get("id")
        if run_id in known_ids:
            continue
        status = _map_gh_to_job(r.get("status"), r.get("conclusion"))
        jobs.append({
            "id": f"gh-{run_id}",
            "run_id": run_id,
            "run_url": r.get("html_url") or "",
            "run_type": r.get("event") or "workflow_dispatch",
            "os_type": _parse_os_from_run_name(r.get("name") or r.get("display_title") or ""),
            "customer": "",
            "ami_name": "",
            "ami_tags": "",
            "aws_region": "",
            "aws_account_name": "",
            "status": status,
            "message": r.get("conclusion") or r.get("status") or "",
            "created_at": r.get("created_at") or "",
            "updated_at": r.get("updated_at") or "",
        })
    return jobs


@app.route("/api/jobs")
@login_required
def api_jobs():
    user = get_current_user()
    _sync_job_statuses(user)
    jobs = []
    for j in db.list_jobs(user["id"]):
        jobs.append({
            "id": j["id"],
            "run_id": j["run_id"],
            "run_url": j["run_url"],
            "run_type": j["run_type"],
            "os_type": j["os_type"],
            "customer": j["customer"],
            "ami_name": j["ami_name"],
            "ami_tags": j["ami_tags"],
            "aws_region": j["aws_region"],
            "aws_account_name": j["aws_account_name"],
            "status": j["status"],
            "message": j["message"],
            "created_at": j["created_at"],
            "updated_at": j["updated_at"],
        })
    jobs = _github_runs_as_jobs(user) + jobs
    jobs.sort(key=lambda j: j["created_at"] or "", reverse=True)
    return jsonify({"status": "ok", "jobs": jobs})


@app.route("/api/jobs/<int:job_id>")
@login_required
def api_job(job_id):
    user = get_current_user()
    job = db.get_job(job_id)
    if job is None or job["user_id"] != user["id"]:
        return jsonify({"status": "error", "message": "Job not found"}), 404
    _sync_job_statuses(user)
    job = db.get_job(job_id)
    return jsonify({"status": "ok", "job": {
        "id": job["id"],
        "run_id": job["run_id"],
        "run_url": job["run_url"],
        "run_type": job["run_type"],
        "os_type": job["os_type"],
        "customer": job["customer"],
        "ami_name": job["ami_name"],
        "ami_tags": job["ami_tags"],
        "aws_region": job["aws_region"],
        "aws_account_name": job["aws_account_name"],
        "status": job["status"],
        "message": job["message"],
        "inputs": json.loads(job["inputs"]),
        "created_at": job["created_at"],
        "updated_at": job["updated_at"],
    }})


if __name__ == "__main__":
    db.init_db()
    db.create_default_admin()
    if os.environ.get("ADMIN_RESET", "").lower() in ("1", "true", "yes"):
        db.reset_admin_password()
        print(
            f"[reset] admin '{db.DEFAULT_ADMIN_USER}' password reset "
            f"to '{db.DEFAULT_ADMIN_PASS}' (set ADMIN_PASSWORD env to choose) "
            "- will be forced to change on next login"
        )
    debug = os.environ.get("FLASK_DEBUG", "false").lower() == "true"
    tls_cert = os.environ.get("TLS_CERT", "")
    tls_key = os.environ.get("TLS_KEY", "")
    if not tls_cert or not tls_key:
        _repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        _cand_cert = os.path.join(_repo, "certs", "tls.crt")
        _cand_key  = os.path.join(_repo, "certs", "tls.key")
        if os.path.isfile(_cand_cert) and os.path.isfile(_cand_key):
            tls_cert, tls_key = _cand_cert, _cand_key
    ssl_context = None
    if tls_cert and tls_key:
        ssl_context = (tls_cert, tls_key)
        app.config["SESSION_COOKIE_SECURE"] = True
        print(f"[https] serving with TLS: cert={tls_cert} key={tls_key}")
    else:
        print("[http] serving plain HTTP — add certs/tls.crt + certs/tls.key to enable HTTPS automatically")
    app.run(
        host="0.0.0.0",
        port=int(os.environ.get("PORT", 8080)),
        debug=debug,
        ssl_context=ssl_context,
    )