#!/bin/bash
# Sync beads JSONL between hosts via Tailscale SSH.
#
# Direction is configurable via env. The reference deployment was Mac (source) → VPS (target),
# but the script is host-agnostic — fill in your own SOURCE_* / TARGET_* values.
#
# Run from the *target* host (the one importing the JSONL). Pure shell — schedule with
# launchd / systemd timer / cron, NOT openclaw cron (deterministic shell jobs are wasted on AI tokens).
set -euo pipefail

# --- Required: fill in your hosts (or set as environment variables before invocation) ---
SOURCE_USER="${SOURCE_USER:-YOUR_USERNAME}"            # e.g. your-mac-username
SOURCE_HOST="${SOURCE_HOST:-YOUR_TAILSCALE_IP}"        # e.g. 100.x.y.z (run `tailscale ip -4` on source)
SOURCE_BEADS="${SOURCE_BEADS:-/Users/${SOURCE_USER}/.beads}"
TARGET_BEADS="${TARGET_BEADS:-${HOME}/.beads}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"

# Optional: NextRequest cookie sync (set NR_COOKIE_SRC empty to skip)
NR_COOKIE_SRC="${NR_COOKIE_SRC:-/Users/${SOURCE_USER}/.cookies/nextrequest/cookies.txt}"
NR_COOKIE_DST="${NR_COOKIE_DST:-${HOME}/records-monitor/nr-cookies.txt}"

if [ "${SOURCE_HOST}" = "YOUR_TAILSCALE_IP" ] || [ "${SOURCE_USER}" = "YOUR_USERNAME" ]; then
    echo "[beads-sync] ERROR: SOURCE_HOST and SOURCE_USER must be set." >&2
    echo "[beads-sync]        Edit this script or export them before running." >&2
    exit 1
fi

mkdir -p "${TARGET_BEADS}"

# Sync primary issues DB
rsync -az -e "ssh ${SSH_OPTS}" \
    "${SOURCE_USER}@${SOURCE_HOST}:${SOURCE_BEADS}/issues.jsonl" \
    "${TARGET_BEADS}/issues.jsonl" 2>&1 && echo "[beads-sync] issues.jsonl synced OK"

# Sync secondary left/metadata files (best-effort)
rsync -az -e "ssh ${SSH_OPTS}" \
    "${SOURCE_USER}@${SOURCE_HOST}:${SOURCE_BEADS}/beads.left.jsonl" \
    "${TARGET_BEADS}/beads.left.jsonl" 2>/dev/null || true

rsync -az -e "ssh ${SSH_OPTS}" \
    "${SOURCE_USER}@${SOURCE_HOST}:${SOURCE_BEADS}/metadata.json" \
    "${TARGET_BEADS}/metadata.json" 2>/dev/null || true

# Optional NextRequest session cookie (best-effort — source may be asleep)
if [ -n "${NR_COOKIE_SRC}" ]; then
    mkdir -p "$(dirname "${NR_COOKIE_DST}")"
    if rsync -az -e "ssh ${SSH_OPTS}" \
        "${SOURCE_USER}@${SOURCE_HOST}:${NR_COOKIE_SRC}" \
        "${NR_COOKIE_DST}" 2>/dev/null; then
        echo "[beads-sync] nr-cookies.txt synced OK"
    else
        echo "[beads-sync] nr-cookies.txt sync failed (source may be asleep) — skipping" >&2
    fi
fi

echo "[beads-sync] Done at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Import synced JSONL into target beads DB (idempotent — upserts)
if [ -s "${TARGET_BEADS}/issues.jsonl" ]; then
    bd import 2>/dev/null && echo "[beads-sync] bd import OK" || echo "[beads-sync] bd import failed" >&2
fi
