import os
import time
import requests

API_URL = "https://api.github.com/repos/%s"
DISPATCH_URL = API_URL + "/actions/workflows/build-image.yml/dispatches"
RUNS_URL = API_URL + "/actions/runs"
RUN_URL = API_URL + "/actions/runs/%s"
JOBS_URL = RUN_URL + "/jobs"


def _headers(token):
    return {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }


def verify_connection(token, repo):
    """Check token can read the repo and list the workflow."""
    url = f"https://api.github.com/repos/{repo}/actions/workflows/build-image.yml"
    try:
        resp = requests.get(url, headers=_headers(token), timeout=15)
        if resp.status_code == 200:
            return {"ok": True, "repo": repo}
        return {"ok": False, "error": f"GitHub API {resp.status_code}: {resp.json().get('message', resp.text[:200])}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def trigger_workflow_dispatch(token, repo, inputs, ref="main"):
    payload = {"ref": ref, "inputs": inputs}
    try:
        resp = requests.post(
            DISPATCH_URL % repo,
            json=payload,
            headers=_headers(token),
            timeout=15,
        )
        if resp.status_code in (204, 200, 201):
            dispatched_at = time.time()
            run = None
            for attempt in range(5):
                run = find_newest_dispatch_run(token, repo, since=dispatched_at)
                if run:
                    break
                time.sleep(2)
            if run:
                return {"ok": True, "run_id": run["id"], "run_url": run["html_url"]}
            return {"ok": True}
        return {"ok": False, "error": f"GitHub API {resp.status_code}: {resp.json().get('message', resp.text[:200])}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def find_newest_dispatch_run(token, repo, since=None, window_seconds=45):
    """Return the most recent workflow_dispatch run for build-image.yml created
    after `since` (a moment shortly before the dispatch POST returned)."""
    if since is None:
        since = time.time() - window_seconds
    try:
        resp = requests.get(
            RUNS_URL % repo,
            headers=_headers(token),
            params={"per_page": 50, "event": "workflow_dispatch"},
            timeout=15,
        )
        if resp.status_code != 200:
            return None
        now = time.time()
        runs = resp.json().get("workflow_runs", [])
        for run in runs:
            if run.get("path") != ".github/workflows/build-image.yml":
                continue
            epoch = _iso_to_epoch(run.get("created_at") or "")
            if epoch is None:
                continue
            # created after the dispatch we just issued; allow small clock skew
            if epoch >= since - 5 and epoch <= now + 15:
                return {
                    "id": run.get("id"),
                    "html_url": run.get("html_url"),
                    "created_at": run.get("created_at"),
                }
        return None
    except Exception:
        return None


def _iso_to_epoch(iso):
    """Parse a GitHub ISO-8601 UTC timestamp (e.g. 2026-09-11T16:06:55Z) to epoch."""
    try:
        from datetime import datetime, timezone

        s = iso.strip().replace("Z", "+00:00")
        return datetime.fromisoformat(s).astimezone(timezone.utc).timestamp()
    except Exception:
        return None


def list_runs(token, repo, per_page=20):
    """List recent workflow runs (all workflows in repo, newest first)."""
    try:
        resp = requests.get(
            RUNS_URL % repo,
            headers=_headers(token),
            params={"per_page": per_page},
            timeout=15,
        )
        if resp.status_code != 200:
            return [], resp.json().get("message", f"HTTP {resp.status_code}")
        return resp.json().get("workflow_runs", []), None
    except Exception as e:
        return [], str(e)


def run_status(token, repo, run_id):
    """Fetch a single run's live status."""
    try:
        resp = requests.get(RUN_URL % (repo, run_id), headers=_headers(token), timeout=15)
        if resp.status_code != 200:
            return None, resp.json().get("message", f"HTTP {resp.status_code}")
        run = resp.json()
        return {
            "run_id": run.get("id"),
            "status": run.get("status"),
            "conclusion": run.get("conclusion"),
            "run_url": run.get("html_url"),
            "created_at": run.get("created_at"),
            "updated_at": run.get("updated_at"),
        }, None
    except Exception as e:
        return None, str(e)