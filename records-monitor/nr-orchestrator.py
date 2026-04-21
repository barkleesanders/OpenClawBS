#!/usr/bin/env python3
"""
Records Request Orchestrator — fully autonomous pipeline.

For each active PRR:
  1. Poll NextRequest API for new documents
  2. Download new docs to /root/records-downloads/<prr_id>/
  3. Upload to Google Drive (dept folder → PRR subfolder)
  4. Update beads notes
  5. Send Telegram summary if anything new arrived or action needed

Runs silently unless there's something to report.
"""
import json
import os
import re
import sys
import time
import subprocess
import urllib.request
import urllib.parse
import urllib.error
from pathlib import Path
from datetime import datetime, timezone

# ─── Config ───────────────────────────────────────────────────────────────────
COOKIE_FILE  = "/root/records-monitor/nr-cookies.txt"
PRR_LIST     = "/opt/records-monitor/prr-list.json"
SEEN_DOCS    = "/opt/records-monitor/seen-docs.json"
DL_BASE      = "/root/records-downloads"
NR_BASE      = "https://sanfrancisco.nextrequest.com"
COMPOSIO_KEY = "YOUR_COMPOSIO_API_KEY"
DRIVE_SCRIPT = "/root/.openclaw/scripts/composio-drive.sh"

# Drive: "SF Records Requests" root folder ID
DRIVE_ROOT = "YOUR_DRIVE_ROOT_FOLDER_ID"

# Drive dept folder IDs (from Drive listing)
DEPT_FOLDER = {
    "Controller":        "YOUR_DRIVE_CONTROLLER_FOLDER_ID",
    "SFFD":              "YOUR_DRIVE_SFFD_FOLDER_ID",
    "SFPUC":             "YOUR_DRIVE_SFPUC_FOLDER_ID",
    "TIDA":              None,  # create on first use
    "City Administrator": None,  # create on first use
}

# Analysis output
NR_NEW_DOCS = "/tmp/nr-new-docs.json"

# Telegram
TG_TOKEN   = "YOUR_TELEGRAM_BOT_TOKEN"
TG_CHAT_ID = "YOUR_TELEGRAM_CHAT_ID"
TG_API     = f"https://api.telegram.org/bot{TG_TOKEN}"

# ─── Drive helpers ─────────────────────────────────────────────────────────────

def drive_token():
    """Get fresh OAuth token from Composio."""
    env = {**os.environ, "COMPOSIO_API_KEY": COMPOSIO_KEY}
    r = subprocess.run(
        ["bash", DRIVE_SCRIPT, "token"],
        capture_output=True, text=True, env=env, timeout=30
    )
    return r.stdout.strip()


def drive_list(folder_id, token):
    """List Drive folder contents → {name: id}."""
    env = {**os.environ, "COMPOSIO_API_KEY": COMPOSIO_KEY}
    r = subprocess.run(
        ["bash", DRIVE_SCRIPT, "list", folder_id],
        capture_output=True, text=True, env=env, timeout=30
    )
    result = {}
    for line in r.stdout.strip().splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            fid, name = parts[0], parts[1]
            result[name] = fid
    return result


def drive_create_folder(name, parent_id, token):
    """Create a Drive folder, return its ID."""
    url = "https://www.googleapis.com/drive/v3/files"
    body = json.dumps({
        "name": name,
        "mimeType": "application/vnd.google-apps.folder",
        "parents": [parent_id],
    }).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        d = json.loads(resp.read())
    return d["id"]


def drive_upload(file_path, filename, parent_id, token):
    """Upload file to Drive folder. Returns file ID or None."""
    env = {**os.environ, "COMPOSIO_API_KEY": COMPOSIO_KEY}
    r = subprocess.run(
        ["bash", DRIVE_SCRIPT, "upload", file_path, parent_id, filename],
        capture_output=True, text=True, env=env, timeout=120
    )
    # composio-drive.sh prints the file ID on success
    fid = r.stdout.strip().split("\n")[-1].strip()
    return fid if fid and not fid.startswith("Error") else None


def get_or_create_prr_folder(prr_id, dept, closed, token):
    """Get (or create) the Drive folder for a specific PRR."""
    dept_id = DEPT_FOLDER.get(dept)
    if not dept_id:
        # Create dept folder inside DRIVE_ROOT
        contents = drive_list(DRIVE_ROOT, token)
        if dept in contents:
            dept_id = contents[dept]
        else:
            dept_id = drive_create_folder(dept, DRIVE_ROOT, token)
        DEPT_FOLDER[dept] = dept_id

    # Look for PRR subfolder in dept folder
    dept_contents = drive_list(dept_id, token)
    suffix = " — Closed" if closed else ""
    folder_name = f"{prr_id}{suffix}"

    # Try exact name, then without suffix
    if folder_name in dept_contents:
        return dept_contents[folder_name]
    base_name = prr_id
    if base_name in dept_contents:
        return dept_contents[base_name]

    # Create it
    return drive_create_folder(folder_name, dept_id, token)


# ─── NR API helpers ────────────────────────────────────────────────────────────

def get_nr_cookie():
    if not os.path.exists(COOKIE_FILE):
        return None
    with open(COOKIE_FILE) as f:
        for line in f:
            if "_nextrequest_session" in line and not line.startswith("#"):
                parts = line.strip().split("\t")
                if len(parts) >= 2:
                    # URL-decode the cookie value
                    raw = parts[-1]
                    return urllib.parse.unquote(raw)
    return None


def fetch_documents(prr_id, cookie):
    page, all_docs = 1, []
    while True:
        params = urllib.parse.urlencode({
            "request_id": prr_id, "page_number": page,
            "visibility": "all", "folderless_docs": "false",
        })
        url = f"{NR_BASE}/client/request_documents?{params}"
        req = urllib.request.Request(url)
        req.add_header("Cookie", f"_nextrequest_session={cookie}")
        req.add_header("Accept", "application/json")
        req.add_header("X-Requested-With", "XMLHttpRequest")
        req.add_header("User-Agent", "Mozilla/5.0 records-monitor/2.0")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"HTTP {e.code}") from e
        docs = data if isinstance(data, list) else data.get("request_documents", data.get("documents", []))
        if not docs:
            break
        all_docs.extend(docs)
        if len(docs) < 25:
            break
        page += 1
        time.sleep(0.5)
    return all_docs


def download_doc(doc_id, filename, cookie, dest_dir):
    os.makedirs(dest_dir, exist_ok=True)
    safe = "".join(c if c.isalnum() or c in "._- " else "_" for c in filename).strip() or f"doc_{doc_id}"
    dest = os.path.join(dest_dir, safe)
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return True, dest
    url = f"{NR_BASE}/request_documents/{doc_id}/download"
    req = urllib.request.Request(url)
    req.add_header("Cookie", f"_nextrequest_session={cookie}")
    req.add_header("User-Agent", "Mozilla/5.0 records-monitor/2.0")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = resp.read()
        with open(dest, "wb") as f:
            f.write(data)
        return True, dest
    except Exception as e:
        return False, str(e)


# ─── Telegram ─────────────────────────────────────────────────────────────────

def tg_send(text, parse_mode="HTML"):
    body = json.dumps({"chat_id": TG_CHAT_ID, "text": text, "parse_mode": parse_mode}).encode()
    req = urllib.request.Request(f"{TG_API}/sendMessage", data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except Exception as e:
        print(f"[tg] send error: {e}", file=sys.stderr)
        return None


# ─── Beads ────────────────────────────────────────────────────────────────────

def beads_remember(text):
    """Store a note in beads memory."""
    subprocess.run(["bd", "remember", text], capture_output=True, timeout=15)


def beads_update_issue(issue_id, notes_addition):
    """Append notes to a beads issue."""
    # Get current notes
    r = subprocess.run(["bd", "show", issue_id], capture_output=True, text=True, timeout=15)
    subprocess.run(
        ["bd", "update", issue_id, f"--notes={notes_addition}"],
        capture_output=True, timeout=15
    )


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    log = lambda msg: print(f"[orchestrator] {msg}", file=sys.stderr)
    today = datetime.now(timezone.utc).strftime("%B %-d, %Y")

    cookie = get_nr_cookie()
    if not cookie:
        tg_send("⚠️ <b>Records Monitor</b>\n\nNR session cookie missing from VPS. Re-sync needed.")
        sys.exit(1)

    with open(PRR_LIST) as f:
        prr_config = json.load(f)
    with open(SEEN_DOCS) as f:
        seen = json.load(f)

    active_prrs = [p for p in prr_config["prrs"] if not p.get("closed", False)]

    # Get Drive token once
    token = drive_token()
    if not token:
        log("WARNING: Could not get Drive token — uploads will be skipped")

    all_new_docs = []
    errors = []

    for prr in active_prrs:
        pid   = prr["id"]
        dept  = prr.get("dept", "Unknown")
        subj  = prr.get("subject", pid)
        closed = prr.get("closed", False)
        log(f"Checking PRR {pid} ({dept})...")

        try:
            docs = fetch_documents(pid, cookie)
        except RuntimeError as e:
            errors.append(f"PRR {pid}: {e}")
            continue

        seen_ids = set(int(x) for x in seen.get(pid, []))
        newly_seen = []

        for doc in docs:
            doc_id = doc.get("id") or doc.get("document_id")
            if doc_id is None:
                continue
            doc_id = int(doc_id)
            if doc_id in seen_ids:
                continue

            filename = (
                doc.get("file_name") or doc.get("filename") or
                doc.get("name") or f"doc_{doc_id}"
            )
            dl_dir = os.path.join(DL_BASE, pid)
            ok, path_or_err = download_doc(doc_id, filename, cookie, dl_dir)

            drive_url = None
            if ok and token:
                try:
                    prr_folder_id = get_or_create_prr_folder(pid, dept, closed, token)
                    fid = drive_upload(path_or_err, filename, prr_folder_id, token)
                    if fid:
                        drive_url = f"https://drive.google.com/file/d/{fid}/view"
                        log(f"  Uploaded to Drive: {filename}")
                except Exception as e:
                    log(f"  Drive upload error for {filename}: {e}")

            entry = {
                "pid": pid, "dept": dept, "subject": subj,
                "id": doc_id, "filename": filename,
                "prr_url": prr.get("url", ""),
                "downloaded": ok,
                "local_path": path_or_err if ok else None,
                "drive_url": drive_url,
                "error": None if ok else path_or_err,
            }
            all_new_docs.append(entry)
            newly_seen.append(doc_id)
            log(f"  New doc: {filename} (id={doc_id}, uploaded={drive_url is not None})")

        seen[pid] = list(seen_ids | set(newly_seen))

    # Persist updated seen state
    with open(SEEN_DOCS, "w") as f:
        json.dump(seen, f, indent=2)

    log(f"Done. New docs: {len(all_new_docs)}, Errors: {len(errors)}")

    # Write JSON summary for analysis cron
    with open(NR_NEW_DOCS, "w") as f:
        json.dump({"timestamp": datetime.now(timezone.utc).isoformat(), "new_docs": all_new_docs}, f, indent=2)
    log(f"Wrote {len(all_new_docs)} new docs to {NR_NEW_DOCS}")

    # ─── Notify ───────────────────────────────────────────────────────────────
    if not all_new_docs and not errors:
        return  # silence is correct

    # Group by PRR
    by_prr = {}
    for d in all_new_docs:
        by_prr.setdefault(d["pid"], []).append(d)

    lines = [f"📥 <b>New Records Received — {today}</b>\n"]
    for pid, docs in by_prr.items():
        dept = docs[0]["dept"]
        subj = docs[0]["subject"]
        # Shorten subject
        short_subj = subj.split("(")[0].strip()[:60]
        uploaded = sum(1 for d in docs if d.get("drive_url"))
        lines.append(f"<b>{pid}</b> ({dept}) — {len(docs)} doc{'s' if len(docs)!=1 else ''}")
        lines.append(f"  📁 {short_subj}")
        lines.append(f"  ✅ {uploaded}/{len(docs)} uploaded to Drive")
        for d in docs[:5]:  # show first 5 filenames
            icon = "✅" if d["downloaded"] else "❌"
            lines.append(f"  {icon} {d['filename'][:55]}")
        if len(docs) > 5:
            lines.append(f"  … and {len(docs)-5} more")
        lines.append("")

    if errors:
        lines.append("⚠️ <b>Errors</b>")
        for e in errors[:3]:
            lines.append(f"  • {e}")

    lines.append("━━━━━━━━━━━━━━━━")
    lines.append("💬 Reply: <code>review {pid}</code> to get analysis, or just check Drive")

    tg_send("\n".join(lines))


if __name__ == "__main__":
    main()
