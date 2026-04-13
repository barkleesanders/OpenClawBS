# 00 — Security Setup (Do This First)

An AI agent with tool access is a privileged process. Before you install anything from this repo, the VPS needs to be hardened. This doc walks through the exact steps I do on every new VPS before anything else touches the box.

Order matters. Do these top-to-bottom. Skipping ahead means the box is exposed during setup.

## Threat model

What you're defending against:

- **Drive-by SSH brute-force bots.** Constant, automated, stupid. Easy to block.
- **Your own secrets leaking.** API keys in git history, tokens in chat logs, env files with world-readable perms. High impact if it happens.
- **Chat-surface prompt injection.** If your Telegram/Discord bot accepts public messages, any message is a potential prompt injection into your agent. Needs rate limits + input isolation.
- **Compromised dependencies.** Supply-chain attacks on npm / pip / homebrew. Lower frequency, higher impact.

What you're NOT defending against (explicitly out of scope):

- **Nation-state adversaries.** If you're worried about those, this is not the setup for you.
- **Physical access.** Full-disk encryption + secure boot is a different doc.
- **Cross-tenant cloud attacks.** Out of scope; you're running on a VPS, not inside a regulated multi-tenant environment.

## Step 1 — Tailscale before you do anything else

[Tailscale](https://tailscale.com) is a mesh VPN over WireGuard. Free for up to 3 users / 100 devices. Install takes 5 minutes. End result: your VPS has a private IP `100.x.y.z` only reachable from devices on your tailnet.

**On the VPS:**

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh    # --ssh is optional but useful; lets Tailscale handle SSH auth too
```

Copy the Tailscale URL it prints, open it in a browser, authenticate.

**On your laptop:**

Install the Tailscale app from [tailscale.com/download](https://tailscale.com/download). Log into the same tailnet.

**Get the VPS's Tailscale IP:**

```bash
tailscale ip -4     # prints 100.x.y.z
```

Add to your SSH config:

```bash
cat >> ~/.ssh/config <<'EOF'
Host my-vps
  HostName 100.x.y.z      # your Tailscale IP
  User root               # or a non-root user (see Step 7)
  Port 2222               # after Step 2
  IdentityFile ~/.ssh/id_ed25519
EOF
```

From here on, `ssh my-vps` uses the encrypted Tailscale tunnel. The VPS's public IP never needs to accept SSH traffic again.

## Step 2 — Move SSH off port 22

Not security-through-obscurity (sophisticated attackers scan all ports). But port 22 gets ~10,000 brute-force attempts per day on any public VPS. Moving it drops that to ~0 and makes real attacks visible in logs.

```bash
sudo sed -i 's/^#*Port 22$/Port 2222/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

Verify you can still log in (keep your current session open while testing a new one!):

```bash
# From your laptop, in a new terminal:
ssh -p 2222 my-vps     # should work
```

Update `~/.ssh/config` Port 2222 (shown in Step 1).

## Step 3 — Disable password auth, enforce keys only

Edit `/etc/ssh/sshd_config`:

```
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
ChallengeResponseAuthentication no
UsePAM no
```

Then:

```bash
sudo systemctl restart ssh
```

Now SSH requires a key. If you lose your key, you lose the server (unless you still have console access via your VPS provider's web UI). Make sure your private key is backed up somewhere safe.

## Step 4 — UFW firewall, default-deny inbound

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH on 2222, but ONLY via the Tailscale interface
sudo ufw allow in on tailscale0 to any port 2222 proto tcp

# Allow Tailscale itself to connect
sudo ufw allow in on tailscale0

# Enable
sudo ufw enable
sudo ufw status verbose
```

Port 22 is closed. Port 2222 is only open on the Tailscale interface. Your public IP accepts zero SSH traffic.

If you need *any* public-facing port: don't open it here. Use a Cloudflare Tunnel (Step 5) instead.

## Step 5 — No public IPs; Cloudflare Tunnel for anything outside Tailscale

If your agent runs a web service that needs to be reachable from outside your tailnet (a Telegram webhook callback, a public OAuth callback, a small status page), don't open a port on the VPS. Use a Cloudflare Tunnel.

Why: the tunnel establishes an outbound connection to Cloudflare. Cloudflare serves your domain. Your VPS's public IP never accepts inbound traffic for that service. Zero attack surface from the internet.

```bash
# Install cloudflared
curl -fsSL https://pkg.cloudflare.com/install-cloudflared.sh | sudo bash

# Auth with your Cloudflare account (opens a browser link)
sudo cloudflared tunnel login

# Create a named tunnel
sudo cloudflared tunnel create my-agent

# Configure what it exposes
sudo tee /etc/cloudflared/config.yml <<'EOF'
tunnel: my-agent
credentials-file: /root/.cloudflared/<TUNNEL-ID>.json
ingress:
  - hostname: bot.example.com
    service: http://127.0.0.1:18789
  - service: http_status:404
EOF

# Route a hostname through it
sudo cloudflared tunnel route dns my-agent bot.example.com

# Install as systemd service
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

Now `https://bot.example.com` reaches your gateway on `127.0.0.1:18789` via an outbound-only tunnel. Your VPS's public firewall never accepts port 443.

## Step 6 — Secrets discipline

Every file containing an API key, OAuth token, or Telegram credential:

- Mode 600 (`chmod 600`)
- Owned by root (or the service user that needs it)
- In `/etc/openclaw/env.sh` or a similar out-of-git location
- Listed in `.gitignore` in every repo you work in
- **Never logged** — scripts that dump environment variables should explicitly `unset COMPOSIO_API_KEY; unset TG_TOKEN` before dumping

The two secrets that hurt most if leaked:

- **`COMPOSIO_API_KEY`** — grants access to all 24+ connected services. Rotate immediately if any doubt.
- **`TG_TOKEN`** (Telegram bot) — allows anyone to impersonate your bot. Rotate via BotFather if leaked.

Pre-commit hook for git repos containing scripts:

```bash
# ~/.git/hooks/pre-commit (or use husky / pre-commit)
if git diff --cached | grep -iE "(api[_-]?key|token|secret|password)[[:space:]]*[:=][[:space:]]*['\"][A-Za-z0-9_-]{16,}"; then
  echo "Possible secret in staged diff — aborting commit"
  exit 1
fi
```

For a bigger net, use [gitleaks](https://github.com/gitleaks/gitleaks): `gitleaks detect --source . --verbose`.

## Step 7 — Consider running as a non-root user

The systemd unit in this repo has `User=root`. That's a deliberate trade-off (simplicity + full systemd control) that's fine on a single-purpose VPS but not great for broader use.

To run as a dedicated user:

```bash
sudo useradd -r -s /bin/false -d /var/lib/openclaw openclaw
sudo mkdir -p /var/lib/openclaw
sudo chown openclaw:openclaw /var/lib/openclaw
```

Then in the systemd drop-in (`env.conf`):

```
[Service]
User=openclaw
Group=openclaw
```

And add hardening directives (see Step 8).

The guardian script will also need its cron moved to the `openclaw` user's crontab, or run with `sudo -u openclaw`.

## Step 8 — systemd service hardening

Regardless of whether you run as root or a dedicated user, add these to your drop-in (`env.conf`):

```ini
[Service]
# Filesystem isolation
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/openclaw /var/log

# Privilege restrictions
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

# Networking
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

# Syscall filtering
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
```

Verify with `systemd-analyze security openclaw-gateway.service` — lower numbers are better.

Test carefully: some of these restrictions can break Chrome/Puppeteer if you use browser automation. Relax specifically what you need, not everything.

## Step 9 — Input isolation for chat surfaces

Your Telegram/Discord/WhatsApp bot will receive messages from humans. If your agent is wired to obey every message, a randomly-scraped message is a prompt injection.

Mitigations:

- **Allowlist** — only respond to messages from specific Telegram user IDs. Drop everything else silently.
- **Rate limit** — no more than N messages per user per minute. Prevents DoS and reduces blast radius if an allowed account is compromised.
- **Escape chat content** — when piping message content into shell, use `printf '%s' "$msg"` not `echo "$msg"`, and never interpolate message text into shell code (`eval`, `bash -c`).
- **Sensitive tool gate** — certain actions (running `bash`, sending email, calling payment APIs) require an out-of-band confirmation, not just "the agent decided to."

## Step 10 — Automatic security patches

On Debian/Ubuntu:

```bash
sudo apt install unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades  # enable, accept defaults
```

This applies security updates automatically. Review `/etc/apt/apt.conf.d/50unattended-upgrades` to confirm behavior.

Reboot the VPS weekly (cron or manually) to ensure kernel updates take effect. Uptime-as-badge-of-honor is a security anti-pattern.

## Step 11 — Backup verification

A backup that silently stops working is worse than no backup (because you *think* you have one). The backup template in this repo (`scripts/templates/backup-template.sh`) includes:

- Preflight check (fails fast if auth is broken)
- Status file written on success (mtime tells you when last backup actually ran)
- Telegram alert on every failure with specific step + detail
- Old-copy cleanup after N days

Add to your weekly review: `stat /var/lib/<backup-name>/status.txt`. Is it recent? Is the size consistent with prior days? If not, investigate.

## Step 12 — Audit log

Enable auditd to track privileged commands:

```bash
sudo apt install auditd
sudo systemctl enable --now auditd
```

Watch for: new SSH keys added, sudo invocations, changes to `/etc/ssh/sshd_config`, writes to `/etc/passwd`. If the box is compromised, these logs are your forensics.

## Recovery: what to do if something does leak

1. **Composio API key leaked?** → Rotate immediately at [app.composio.dev](https://app.composio.dev) → Developer → API Keys → Regenerate. Update `/etc/openclaw/env.sh`. Restart crons.
2. **Telegram bot token leaked?** → Message `@BotFather`, `/revoke`, get a new token, update env.
3. **SSH key compromised?** → Remove from `~/.ssh/authorized_keys` on the VPS, generate a new keypair, add the new one. Audit logs for anything done by the old key.
4. **VPS itself compromised?** → Snapshot it (for forensics), spin up a clean VPS, restore only your data (not your configs), rotate *every* secret. Consider what the attacker had access to for the compromise window.

## Checklist summary

Before running the OpenClawBS installer, you should be able to tick every one of these:

- [ ] Tailscale installed, VPS on my tailnet, laptop can reach via `100.x.y.z`
- [ ] SSH moved to port 2222
- [ ] Password auth disabled, keys only
- [ ] UFW enabled, inbound only allowed on Tailscale interface
- [ ] No public-facing ports on the VPS (Cloudflare Tunnel for anything outside Tailscale)
- [ ] All env/secret files are mode 600, owned by root, in `.gitignore`
- [ ] `unattended-upgrades` enabled
- [ ] (Nice-to-have) auditd running
- [ ] (Nice-to-have) systemd hardening directives added
- [ ] (Nice-to-have) dedicated non-root user for the agent

If any of those aren't true, fix them before installing the agent. The setup only gets harder the longer you delay this, and "I'll harden it tomorrow" is how boxes get compromised.
