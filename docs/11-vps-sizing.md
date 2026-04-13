# 11 — VPS Sizing: Where to Buy, When to Upgrade, When to Switch to a Mac Mini

> **A reference architecture for running a long-lived personal AI agent that remembers things, doesn't lie, doesn't silently break, and fits on a $5 VPS.**

This whole setup assumes a small always-on machine. You don't need much — but what you pick, and when you outgrow it, matters.

## Where I buy VPS: Hetzner Cloud

[**hetzner.com/cloud**](https://www.hetzner.com/cloud/) — German hosting provider. Best price-to-performance in the market, straightforward billing, reliable network, EU and US regions, no bandwidth surprises. Not sponsored; just what I use.

Alternatives:

| Provider | Why you'd pick them instead |
|---|---|
| [Hetzner](https://www.hetzner.com/cloud/) | **Default.** Cheapest for the RAM you get, includes 20 TB traffic on every plan |
| [OVH](https://www.ovhcloud.com/en/vps/) | Slightly higher price, broader regional coverage (Canada, Australia) |
| [DigitalOcean](https://www.digitalocean.com/pricing/droplets) | Better UX, ~2× the price for equivalent specs |
| [Linode / Akamai](https://www.linode.com/pricing/) | Same rough bucket as DO |
| [AWS Lightsail](https://aws.amazon.com/lightsail/pricing/) | Only if you're already deep in AWS |

**Don't use:** raw AWS EC2 / GCP Compute Engine / Azure VMs for a personal agent. You'll pay 3-5× what Hetzner costs for the same workload, and the billing complexity will eat your weekends.

## Full Hetzner Cloud pricing (as of April 2026)

All plans include **20 TB traffic**, **1 IPv4 + IPv6**, **DDoS protection**, and **snapshots/backups available as paid add-ons** (~20% of plan price for backups).

Check [**hetzner.com/cloud**](https://www.hetzner.com/cloud/) for live prices — they adjusted April 2026.

### Shared vCPU (CX series) — "Cost-Optimized"

This is what you want for an agent. Shared vCPU is perfectly adequate — the workload is I/O-bound, not CPU-bound.

| Plan | vCPU | RAM | SSD | Traffic | EUR/mo | USD/mo (~) | USD/year |
|------|------|-----|-----|---------|--------|------------|----------|
| **CX23** | 2 | **4 GB** | 40 GB | 20 TB | **€3.99** | ~$4.50 | ~$54 |
| **CX33** | 4 | **8 GB** | 80 GB | 20 TB | **€6.49** | ~$7.30 | ~$88 |
| **CX43** | 8 | **16 GB** | 160 GB | 20 TB | **€11.99** | ~$13.50 | ~$162 |
| **CX53** | 16 | **32 GB** | 320 GB | 20 TB | **€22.49** | ~$25.50 | ~$306 |

### Dedicated vCPU (CCX series) — "General Purpose"

Pick this only if you've proven the workload is CPU-bound. For an AI agent it almost never is. Listed for completeness.

| Plan | vCPU | RAM | SSD | Traffic | EUR/mo | USD/mo (~) | USD/year |
|------|------|-----|-----|---------|--------|------------|----------|
| **CCX13** | 2 dedicated | 8 GB | 80 GB | 20 TB | **€15.99** | ~$18 | ~$216 |
| **CCX23** | 4 dedicated | 16 GB | 160 GB | 20 TB | **€31.49** | ~$36 | ~$432 |
| **CCX33** | 8 dedicated | 32 GB | 240 GB | 30 TB | **€62.49** | ~$71 | ~$852 |
| **CCX43** | 16 dedicated | 64 GB | 360 GB | 40 TB | **€124.99** | ~$141 | ~$1,692 |
| **CCX53** | 32 dedicated | 128 GB | 600 GB | 50 TB | **€249.99** | ~$283 | ~$3,396 |
| **CCX63** | 48 dedicated | 192 GB | 960 GB | 60 TB | **€374.49** | ~$424 | ~$5,088 |

> Source: [costgoat.com/pricing/hetzner](https://costgoat.com/pricing/hetzner), [hetzner.com/cloud](https://www.hetzner.com/cloud/).
> Check live for current pricing — Hetzner adjusts periodically.

## Who each tier is for (and when to move up)

### CX23 — **4 GB RAM, ~$4.50/mo** — START HERE

**What fits comfortably:**
- OpenClaw gateway (~1.5 GB steady state)
- ~18 cron jobs (mix of shell + light-context AI)
- Telegram bot, Cloudflare tunnel, daily backups
- One active browser automation session
- memory-guardian keeping everything honest

**Upgrade signal:** memory-guardian triggers restarts more than **2× per week**, or system `MemAvailable` regularly drops below 300 MB during normal operation.

**This is what I actually run.** Two years, zero regrets. If you're starting from scratch — start here.

### CX33 — **8 GB RAM, ~$7.30/mo** — Comfortable Middle Ground

**What fits comfortably (in addition to CX23 workload):**
- Multiple concurrent browser automation sessions (each Chrome is ~300-500 MB)
- Small Postgres / MySQL / SQLite with meaningful data
- More AI cron jobs running concurrently
- A small Next.js / FastAPI web app alongside the agent

**Upgrade signal:** you're trying to run a local LLM (even a 3B model feels cramped on 8 GB). Or you're regularly storing >40 GB of data locally.

### CX43 — **16 GB RAM, ~$13.50/mo** — Real Workloads

**What fits:**
- 7-8B parameter local LLM (quantized) via llama.cpp or ollama
- Database with tens of GB of data
- Hot-standby copies of services
- Real web app with persistent traffic

**Upgrade signal:** this is the "maybe Mac Mini?" tier. See the crossover math below.

### CX53 — **32 GB RAM, ~$25.50/mo** — Probably Overkill

For multiple agents, substantial hosted apps, serious on-device inference. At this price, a Mac Mini at home starts winning — see below.

**Upgrade signal:** don't. If you need more than 32 GB in the cloud, either switch to CCX dedicated (workload is CPU-bound) or move to a Mac Mini at home (workload is I/O- and memory-bound).

### CCX tier (dedicated CPU)

Only worth it if you have a proven CPU-bound workload: video encoding, massive data pipelines, on-demand builds. **Not for agent workloads** — they're almost entirely I/O-bound and will not notice the difference between shared and dedicated vCPU.

## Upgrade decision tree (evidence-based, not vibes)

```
                Is memory-guardian restarting
                 the gateway more than 2×/week?
                        │
              ┌─────── yes ───────┐    no
              │                   │     │
              ▼                   │     ▼
   Upgrade one CX tier.           │   Current tier is fine.
   Re-measure after 2 weeks.      │   Don't upgrade yet.
                                  │
                                  └──► Is disk > 80% full after cleanup?
                                              │
                                     ┌─── yes ───┐    no
                                     │           │     │
                                     ▼           │     ▼
                               Upgrade one tier. │   Stay put.
                                                 │
                                                 └──► Planning to add local LLM?
                                                              │
                                                     ┌─── yes ───┐    no
                                                     │           │     │
                                                     ▼           │     ▼
                                          Skip past CX. Go Mac   │   Stay put.
                                          Mini (see below).       │
```

**Do not upgrade because:**
- "I want more headroom" — measure first, upgrade on evidence
- "CPU shows 80%" — that's fine, you're using what you paid for
- "I might need it in six months" — upgrade in six months, not now

**Do upgrade because:**
- Memory guardian is triggering frequently
- Disk is filling after cleanup
- You're about to add a workload you've verified won't fit

## Mac Mini alternative — full pricing & when it wins

A Mac Mini at home can replace or supplement your VPS. Apple Silicon's unified memory makes it especially compelling for local LLM inference.

### Current Mac Mini configurations

| Config | Chip | RAM | SSD | Apple price | Deal price (seen) | Ideal use case |
|--------|------|-----|-----|-------------|-------------------|----------------|
| **Mac Mini M4 base** | M4 (10-core CPU / 10-core GPU) | **16 GB** | 256 GB | **$599** | ~$499 on sale | Agent host + occasional 3B LLM |
| **Mac Mini M4 mid** | M4 | **24 GB** | 512 GB | **$799** | ~$699 on sale | Agent host + 7-8B LLM comfortable |
| **Mac Mini M4 Pro base** | M4 Pro (12-core CPU / 16-core GPU) | **24 GB** | 512 GB | **$1,399** | — | Serious local inference |
| **Mac Mini M4 Pro max** | M4 Pro | **64 GB** | 8 TB | ~**$4,000** | — | 70B LLM at 4-bit, full local AI stack |

> Sources: [apple.com/shop/buy-mac/mac-mini](https://www.apple.com/shop/buy-mac/mac-mini), [appleinsider.com](https://prices.appleinsider.com/mac-mini-m4).

Plus ongoing costs:
- **Electricity**: ~$2-5/mo at idle, up to ~$10/mo under heavy LLM load (~5-30 W)
- **UPS** (recommended): $80 one-time
- **Internet** (assumed: you already have it)

### Economic crossover with Hetzner

```
3 years of Hetzner CX23 = $54 × 3 = $162     (Mac Mini dwarfs this)
3 years of Hetzner CX33 = $88 × 3 = $264     (Mac Mini still dwarfs)
3 years of Hetzner CX43 = $162 × 3 = $486    (Base Mac Mini $599 — close)
3 years of Hetzner CX53 = $306 × 3 = $918    (Mac Mini $599 wins; M4 Pro $1,399 breaks even)
3 years of Hetzner CCX23 = $432 × 3 = $1,296 (M4 Pro $1,399 breaks even at 3 years)
5 years of Hetzner CX43 = $162 × 5 = $810    (Mac Mini $599 wins comfortably)
5 years of Hetzner CX53 = $306 × 5 = $1,530  (M4 Pro $1,399 wins)
```

**Pure dollar rule of thumb:**
- Still at CX23/CX33? Stay on Hetzner. Mac Mini economics don't make sense.
- At CX43 with a 3+ year horizon? Mac Mini M4 base wins.
- At CX53 or CCX23 with a 3+ year horizon? Mac Mini M4 Pro wins.

### The non-economic reasons to switch

Money is only part of it. The real reasons:

1. **Local LLM inference.** Apple Silicon's unified memory runs 7-13B models at usable speeds on the base M4. The M4 Pro with 64 GB runs Llama 3.3 70B at 4-bit quantization at ~8 tok/sec. A VPS at any price can't match this — you'd have to rent a GPU instance at $0.50-$4/hour.
2. **Data locality.** Agent memory files, browser state, chat history never leave your home network. Cloudflare Tunnel gives you outside reachability without compromising this.
3. **Predictable cost.** Your electric bill doesn't fluctuate like cloud bandwidth overage charges.
4. **Hardware you can touch.** Disk dying? Swap it (M4 Mac Mini has user-accessible SSD). Network weird? Power-cycle the router.
5. **M4 Mac Mini has user-replaceable SSD** — a big change from previous generations. Means you can upgrade storage without buying a whole new machine.

### The reasons not to switch

1. **Home power reliability.** A 2-hour outage is a 2-hour agent outage. Real-time surfaces (Telegram bot) go dark.
2. **Home ISP reliability.** Consumer ISPs have worse uptime than data centers.
3. **Physical presence.** You need a spot for the Mac Mini, a UPS, good ventilation (runs cool but not zero heat).
4. **Migration cost.** Moving a live agent is a weekend of work — don't do it on a whim.
5. **RAM is soldered.** If you buy the 16 GB base, you're stuck at 16 GB forever. Unlike the SSD, which is now slottable, RAM is permanent. **Buy more than you think you need.**

### The hybrid approach (what I'll probably do)

Keep the cheap VPS ($5/mo CX23) as the always-on public-facing brain — Telegram bot, scheduled crons, reliable. Put a Mac Mini at home for:

- Local LLM inference (called from the VPS via Tailscale)
- Heavy data processing (embeddings, large builds)
- Anything that benefits from hardware you own

VPS dispatches work to Mac Mini via Tailscale when it needs horsepower. Mac Mini sleeps when idle. You get reliability + data locality + local inference for the cost of one cheap VPS.

**Cost of hybrid:**
- Hetzner CX23: $54/year
- Mac Mini M4 (24 GB / 512 GB, once): $799
- Electricity: ~$60/year
- **Total year 1: ~$913. Years 2+: ~$114/year.**

Vs. trying to do everything on a Hetzner CX53: $306/year forever, and still no local LLM.

### Decision checklist for Mac Mini

Pick Mac Mini over bigger VPS if **3+ of these are true**:

- [ ] You're already on Hetzner CX43 or larger (€12+/mo)
- [ ] You'll run this for 3+ years
- [ ] You want to run local LLM inference
- [ ] You care about data locality (agent memory doesn't leave home)
- [ ] You have reliable home power (or a UPS)
- [ ] You have reliable home internet (or a fallback — cell modem, etc.)
- [ ] You have physical space (Mac Mini is tiny — 5" × 5" × 2")
- [ ] You're comfortable with ~1 hr/month of physical maintenance

Otherwise: stay on Hetzner, upgrade CX tiers on evidence.

## Networking setup for home Mac Mini

Same Tailscale-first pattern as the VPS:

1. Install Tailscale on the Mac Mini, join your tailnet
2. SSH via `100.x.y.z` (Tailscale IP), never via home public IP
3. Public-facing needs (webhooks, status pages) → Cloudflare Tunnel — same as VPS in [`docs/00-security.md`](00-security.md)
4. Home router never needs port forwarding
5. ISP rotates your public IP daily? Doesn't matter — traffic flows via Tailscale + Cloudflare

Security model is identical to the VPS model. Follow [`docs/00-security.md`](00-security.md) for both.

## What I actually run today

Small always-on Hetzner VPS (CX23, ~$4.50/mo) running OpenClaw + all crons. Everything in this repo is tuned for that size of machine. It's been enough for two years.

When I eventually want local LLM inference, I'll add a Mac Mini at home and have the VPS dispatch heavy work to it via Tailscale. Add, don't replace.

## TL;DR

- **Start here:** Hetzner **CX23** (€3.99/mo, 4 GB RAM)
- **Upgrade on evidence**, not vibes — memory-guardian restarts >2×/week, or disk >80% full
- **Stop climbing the Hetzner tier ladder at CX43**. Past that, evaluate Mac Mini.
- **Pick Mac Mini if:** 3+ year horizon + local LLM ambitions + reliable home power + data locality matters
- **Hybrid (cheap VPS + home Mac Mini) if:** you want both reliability and local horsepower

---

Sources: [hetzner.com/cloud](https://www.hetzner.com/cloud/) · [costgoat.com/pricing/hetzner](https://costgoat.com/pricing/hetzner) · [apple.com/mac-mini](https://www.apple.com/mac-mini/) · [appleinsider.com/mac-mini-m4](https://prices.appleinsider.com/mac-mini-m4)
