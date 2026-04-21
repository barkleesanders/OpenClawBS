#!/bin/bash
# Sync beads JSONL from Mac to VPS via Tailscale SSH
# This is pure shell — runs in systemd timer, NOT openclaw cron
set -euo pipefail

MAC_USER="barkleesanders"
MAC_IP="100.105.234.86"
MAC_BEADS="/Users/barkleesanders/.beads"
VPS_BEADS="/root/.beads"
SSH_OPTS="-i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"

mkdir -p "$VPS_BEADS"
mkdir -p /root/records-monitor

# Sync primary issues DB
rsync -az -e "ssh $SSH_OPTS" \
    "${MAC_USER}@${MAC_IP}:${MAC_BEADS}/issues.jsonl" \
    "${VPS_BEADS}/issues.jsonl" 2>&1 && echo "[beads-sync] issues.jsonl synced OK"

# Sync secondary left/metadata files (best-effort)
rsync -az -e "ssh $SSH_OPTS" \
    "${MAC_USER}@${MAC_IP}:${MAC_BEADS}/beads.left.jsonl" \
    "${VPS_BEADS}/beads.left.jsonl" 2>/dev/null || true

rsync -az -e "ssh $SSH_OPTS" \
    "${MAC_USER}@${MAC_IP}:${MAC_BEADS}/metadata.json" \
    "${VPS_BEADS}/metadata.json" 2>/dev/null || true

# Sync NextRequest session cookie (best-effort — Mac may be asleep)
NR_COOKIE_SRC="/Users/barkleesanders/.cookies/nextrequest/cookies.txt"
NR_COOKIE_DST="/root/records-monitor/nr-cookies.txt"
if rsync -az -e "ssh $SSH_OPTS" \
    "${MAC_USER}@${MAC_IP}:${NR_COOKIE_SRC}" \
    "${NR_COOKIE_DST}" 2>/dev/null; then
    echo "[beads-sync] nr-cookies.txt synced OK"
else
    echo "[beads-sync] nr-cookies.txt sync failed (Mac may be asleep) — skipping" >&2
fi

echo "[beads-sync] Done at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Import synced JSONL into VPS beads Dolt DB (idempotent — upserts)
if [ -s "${VPS_BEADS}/issues.jsonl" ]; then
    bd import 2>/dev/null && echo "[beads-sync] bd import OK" || echo "[beads-sync] bd import failed" >&2
fi
