import os
import sqlite3
from datetime import datetime, timezone
from werkzeug.security import generate_password_hash, check_password_hash

_DB_PATH = os.environ.get(
    "DATABASE_PATH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden_image.db"),
)

DEFAULT_ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
DEFAULT_ADMIN_PASS = os.environ.get("ADMIN_PASSWORD", "admin")


def get_conn():
    conn = sqlite3.connect(_DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db():
    with get_conn() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                role TEXT NOT NULL DEFAULT 'user',
                must_change_password INTEGER NOT NULL DEFAULT 1,
                active_account_id INTEGER,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS aws_accounts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                access_key_enc TEXT NOT NULL,
                secret_key_enc TEXT NOT NULL,
                region TEXT NOT NULL DEFAULT 'us-east-1',
                role_arn TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS github_connections (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL UNIQUE,
                token_enc TEXT NOT NULL,
                repo TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS jobs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL,
                run_id INTEGER,
                run_url TEXT,
                run_type TEXT NOT NULL,
                os_type TEXT NOT NULL,
                customer TEXT NOT NULL DEFAULT 'shared',
                ami_name TEXT NOT NULL DEFAULT '',
                ami_tags TEXT NOT NULL DEFAULT '',
                aws_region TEXT NOT NULL DEFAULT 'us-east-1',
                aws_account_name TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'queued',
                inputs TEXT NOT NULL DEFAULT '{}',
                message TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            );
            """
        )


def create_default_admin():
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id FROM users WHERE username = ?", (DEFAULT_ADMIN_USER,)
        ).fetchone()
        if row is None:
            conn.execute(
                "INSERT INTO users (username, password_hash, role, must_change_password, created_at) "
                "VALUES (?, ?, 'admin', 1, ?)",
                (
                    DEFAULT_ADMIN_USER,
                    generate_password_hash(DEFAULT_ADMIN_PASS),
                    _now(),
                ),
            )


def reset_admin_password(username=DEFAULT_ADMIN_USER, password=DEFAULT_ADMIN_PASS):
    """Reset an admin's password and force a change on next login."""
    with get_conn() as conn:
        conn.execute(
            "UPDATE users SET password_hash=?, must_change_password=1 WHERE username=?",
            (generate_password_hash(password), username),
        )


# ---- Users ----

def get_user_by_id(user_id):
    with get_conn() as conn:
        return conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()


def get_user_by_username(username):
    with get_conn() as conn:
        return conn.execute(
            "SELECT * FROM users WHERE username = ?", (username,)
        ).fetchone()


def authenticate(username, password):
    user = get_user_by_username(username)
    if user and check_password_hash(user["password_hash"], password):
        return user
    return None


def change_password(user_id, new_password):
    with get_conn() as conn:
        conn.execute(
            "UPDATE users SET password_hash = ?, must_change_password = 0 WHERE id = ?",
            (generate_password_hash(new_password), user_id),
        )


def list_users():
    with get_conn() as conn:
        return conn.execute(
            "SELECT id, username, role, must_change_password, created_at FROM users ORDER BY id"
        ).fetchall()


def create_user(username, password, role="user"):
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO users (username, password_hash, role, must_change_password, created_at) "
            "VALUES (?, ?, ?, 1, ?)",
            (username, generate_password_hash(password), role, _now()),
        )


def delete_user(user_id):
    with get_conn() as conn:
        conn.execute("DELETE FROM users WHERE id = ? AND role != 'admin'", (user_id,))


def reset_other_user_password(user_id, new_password):
    with get_conn() as conn:
        conn.execute(
            "UPDATE users SET password_hash = ?, must_change_password = 1 WHERE id = ?",
            (generate_password_hash(new_password), user_id),
        )


def set_active_account(user_id, account_id):
    with get_conn() as conn:
        conn.execute(
            "UPDATE users SET active_account_id = ? WHERE id = ?", (account_id, user_id)
        )


# ---- AWS accounts ----

def add_aws_account(user_id, name, access_key_enc, secret_key_enc, region, role_arn=""):
    with get_conn() as conn:
        cur = conn.execute(
            "INSERT INTO aws_accounts (user_id, name, access_key_enc, secret_key_enc, region, role_arn, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (user_id, name, access_key_enc, secret_key_enc, region, role_arn, _now()),
        )
        return cur.lastrowid


def list_aws_accounts(user_id):
    with get_conn() as conn:
        return conn.execute(
            "SELECT * FROM aws_accounts WHERE user_id = ? ORDER BY id", (user_id,)
        ).fetchall()


def get_aws_account(account_id):
    with get_conn() as conn:
        return conn.execute(
            "SELECT * FROM aws_accounts WHERE id = ?", (account_id,)
        ).fetchone()


def get_active_aws_account(user):
    account_id = user["active_account_id"]
    if account_id:
        return get_aws_account(account_id)
    accounts = list_aws_accounts(user["id"])
    return accounts[0] if accounts else None


def delete_aws_account(account_id):
    with get_conn() as conn:
        conn.execute("DELETE FROM aws_accounts WHERE id = ?", (account_id,))


# ---- GitHub connections ----

def get_github_connection(user_id):
    with get_conn() as conn:
        return conn.execute(
            "SELECT * FROM github_connections WHERE user_id = ?", (user_id,)
        ).fetchone()


def set_github_connection(user_id, token_enc, repo):
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO github_connections (user_id, token_enc, repo, updated_at) VALUES (?, ?, ?, ?) "
            "ON CONFLICT(user_id) DO UPDATE SET token_enc = excluded.token_enc, repo = excluded.repo, updated_at = excluded.updated_at",
            (user_id, token_enc, repo, _now()),
        )


# ---- Jobs ----

def add_job(user_id, run_type, os_type, customer, ami_name, ami_tags,
            aws_region, aws_account_name, inputs):
    with get_conn() as conn:
        cur = conn.execute(
            "INSERT INTO jobs (user_id, run_type, os_type, customer, ami_name, ami_tags, "
            "aws_region, aws_account_name, inputs, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                user_id, run_type, os_type, customer, ami_name, ami_tags,
                aws_region, aws_account_name, json_dumps(inputs), _now(), _now(),
            ),
        )
        return cur.lastrowid


def update_job_status(job_id, status, run_id=None, run_url=None, message=""):
    with get_conn() as conn:
        sets = ["status = ?", "updated_at = ?"]
        vals = [status, _now()]
        if run_id is not None:
            sets.append("run_id = ?")
            vals.append(run_id)
        if run_url is not None:
            sets.append("run_url = ?")
            vals.append(run_url)
        if message:
            sets.append("message = ?")
            vals.append(message)
        conn.execute(f"UPDATE jobs SET {', '.join(sets)} WHERE id = ?", (*vals, job_id))


def list_jobs(user_id, limit=50):
    with get_conn() as conn:
        return conn.execute(
            "SELECT * FROM jobs WHERE user_id = ? ORDER BY id DESC LIMIT ?",
            (user_id, limit),
        ).fetchall()


def get_job(job_id):
    with get_conn() as conn:
        return conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()


def json_dumps(obj):
    import json
    return json.dumps(obj)


def _now():
    return datetime.now(timezone.utc).isoformat()