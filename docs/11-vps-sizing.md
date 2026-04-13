# 11 — VPS Sizing: Where to Buy, When to Upgrade, When to Switch to a Mac Mini

> **A reference architecture for running a long-lived personal AI agent that remembers things, doesn't lie, doesn't silently break, and fits on a $5 VPS.**

This whole setup assumes a small always-on machine. You don't need much — but what you pick, and when you outgrow it, matters.

## Where I buy VPS: Hetzner Cloud

[**hetzner.com/cloud**](https://www.hetzner.com/cloud/) — German hosting provider. Best price-to-performance in the market, straightforward billing, reliable network. Not sponsored; just what I use.

Alternatives worth considering:

| Provider | Why you'd pick them instead |
|---|---|
| [Hetzner](https://www.hetzner.com/cloud/) | **Default.** Cheapest for the RAM you get; EU data centers |
| [OVH](https://www.ovhcloud.com/en/vps/) | Slightly higher price, but US data centers without the AWS premium |
| [DigitalOcean](https://www.digitalocean.com/pricing/droplets) | Better UX, worse price (~2x Hetzner for equivalent specs) |
| [Linode / Akamai](https://www.linode.com/pricing/) | Same rough bucket as DO |
| [AWS Lightsail](https://aws.amazon.com/lightsail/pricing/) | Only if you're already deep in AWS |

**Don't use:** raw AWS EC2 / GCP Compute Engine / Azure VMs for a personal agent — you'll pay 3-5x what Hetzner costs for the same workload, and the billing complexity will eat your weekends.

## Hetzner tiers & when each makes sense

Check [**hetzner.com/cloud**](https://www.hetzner.com/cloud/) for exact current pricing. These are the tiers and approximate prices as of April 2026:

### CX22 — ~€4.30/mo (~$5)

- 2 vCPU (shared), 4 GB RAM, 40 GB SSD, 20 TB traffic

**Who this is for:** this is the one I started on. OpenClaw gateway runs comfortably here with the memory-guardian cron keeping it in check. Telegram bot + ~18 crons + daily backups + Cloudflare tunnel + a few other services fit in 4 GB if you're disciplined.

**Upgrade signal:** when you see memory-guardian triggering restarts more than twice a week, or when your workload wants to run multiple headless Chrome instances simultaneously. RAM is what runs out first, not CPU.

### CX32 — ~€6.90/mo (~$8)

- 4 vCPU, 8 GB RAM, 80 GB SSD

**Who this is for:** comfortable middle ground. Double the RAM means you can run browser automation freely (each Chrome is ~300-500 MB), host a small Postgres or SQLite with sizable data, run more AI cron jobs concurrently, and keep ~2 GB of headroom.

**Upgrade signal:** you're running a local LLM (Ollama, llama.cpp) and even a 3B model feels cramped. Or you're storing real data locally and disk is filling.

### CX42 — ~€13/mo (~$15)

- 8 vCPU, 16 GB RAM, 160 GB SSD

**Who this is for:** you're running real workloads. Probably hosting a web app or two alongside the agent, possibly running a 7-8B local LLM for specific tasks (embedding, classification), maintaining a database with tens of GB of data, and running hot standby copies of services.

**Upgrade signal:** this is where the "maybe Mac Mini?" calculation flips — see below.

### CX52 — ~€25/mo (~$28)

- 16 vCPU, 32 GB RAM, 320 GB SSD

**Who this is for:** probably overkill for an agent unless you're running multiple agents, hosting a substantial web app, or doing on-device inference at scale.

**Upgrade signal:** don't. If you need more than this, you want dedicated hardware — either Hetzner's CCX tier (dedicated CPU) or a Mac Mini at home.

### CCX series (dedicated CPU)

Starts ~€13/mo for 2 dedicated vCPU. Worth it if you're running CPU-bound workloads (video processing, large builds, heavy data munging). Not worth it for agent workloads, which are almost entirely I/O-bound.

## When to upgrade (decision tree)

```
                  Is memory-guardian restarting
                   the gateway more than 2x/week?
                          │
                ┌─────── yes ───────┐    no
                │                   │     │
                ▼                   │     ▼
         Upgrade one tier.          │   Current tier is fine.
         Re-measure after 2 weeks.  │   Don't upgrade yet.
                                    │
                                    └───► Or: is your disk > 80% full?
                                                │
                                        ┌─── yes ───┐    no
                                        │           │     │
                                        ▼           │     ▼
                                  Upgrade one tier. │   Current tier is fine.
                                  Or: clean up.     │
```

**Do not upgrade because:**

- "I want more headroom" — measure first, upgrade on evidence
- "The CPU utilization shows 80%" — that's fine, it means you're using what you paid for
- "I might need it in six months" — upgrade in six months, then, not now

**Do upgrade because:**

- Memory guardian is triggering frequently (evidence of actual constraint)
- Disk is filling (growth you can't trim)
- You're about to add a workload you know won't fit

## When to switch to a Mac Mini (or other dedicated home machine)

At some point, a $25/mo VPS × 12 months × 3 years = ~$900 starts competing with a **Mac Mini** at ~$599-$799 that you own forever. And for AI workloads, Apple Silicon has become genuinely compelling for local inference.

### The economic crossover

```
Break-even calculation (very rough):

  Hetzner CX42 at ~€13/mo × 36 months = €468 (~$520)
  Hetzner CX52 at ~€25/mo × 36 months = €900 (~$1000)

  Mac Mini M4 base (16 GB unified memory, 256 GB SSD): $599
  Mac Mini M4 Pro (24 GB unified, 512 GB SSD):         $1,399
  + home electricity: ~$2-5/month (idle)

  So: 3 years of CX42 ≈ cost of base Mac Mini
      3 years of CX52 ≈ cost of Mac Mini M4 Pro
```

If you'll run the agent for 3+ years and you're already on a CX42+ tier, Mac Mini breaks even on a pure cost basis.

### The real reasons to switch

Money is only part of it. The actual arguments for Mac Mini:

1. **Local LLM inference.** Apple Silicon's unified memory architecture runs 7-13B models at usable speeds. A Mac Mini M4 Pro with 24 GB can fit Llama 3.3 70B at 4-bit quantization. A VPS cannot touch this at any price.
2. **Data locality.** Your agent's memory files, browser state, and chat history never leave your home network. Cloudflare Tunnel gives you outside reachability without losing this.
3. **Predictable cost.** Your electric bill doesn't fluctuate like cloud bandwidth charges can.
4. **Hardware you can touch.** Disk dying? Swap it. Network weird? Power-cycle the router. Not possible in a data center.

### The reasons not to switch

1. **Home power reliability.** A 2-hour power outage means a 2-hour agent outage. If your agent handles anything real-time, this matters.
2. **Home ISP reliability.** Consumer ISPs have worse uptime than data centers. Your agent will be unreachable during outages.
3. **Physical presence.** You have to have a spot for the Mac Mini, a UPS, cooling. Not huge, but not zero.
4. **Migration cost.** Moving a live agent from VPS to Mac Mini is a weekend of work. Don't do it on a whim.

### The hybrid approach (what I'll probably do)

Keep the cheap VPS ($5/mo CX22) as the always-on public-facing brain — it's the Telegram bot, it holds the scheduled crons, it's reliable. Put a Mac Mini at home for:

- Local LLM inference (called from the VPS via Tailscale)
- Heavy data processing (training embeddings, running large builds)
- Anything that benefits from hardware you own

The VPS dispatches work to the Mac Mini via Tailscale when it needs horsepower. The Mac Mini hibernates when idle. You get reliability + data-locality + local inference for the cost of one cheap VPS.

### Decision checklist

Pick Mac Mini over bigger VPS if 3+ of these are true:

- [ ] You're already on Hetzner CX42 or larger (€13+/mo)
- [ ] You'll run this for 3+ years
- [ ] You want to run local LLM inference
- [ ] You care about data locality (agent memory doesn't leave home network)
- [ ] You have reliable home power (or a UPS)
- [ ] You have reliable home internet (or a fallback)
- [ ] You have physical space for the machine
- [ ] You're comfortable with ~1 hr/month of maintenance

Otherwise: stay on Hetzner and upgrade tiers as needed.

## The networking setup for a home Mac Mini

Same Tailscale-first pattern as the VPS:

1. Install Tailscale on the Mac Mini, join your tailnet
2. SSH to it via `100.x.y.z` (Tailscale IP), never via your home public IP
3. Anything public-facing (Telegram webhook, status page) goes through Cloudflare Tunnel — exactly like the VPS pattern in [`docs/00-security.md`](00-security.md)
4. Your home router never needs port forwarding
5. Your home ISP can rotate your public IP daily — doesn't matter, traffic flows via Tailscale + Cloudflare

The security model is identical to the VPS model. Follow [`docs/00-security.md`](00-security.md) for both.

## What I actually use today

Small always-on VPS (Hetzner CX22, ~$5/mo) running the OpenClaw gateway + all crons. Everything in this repo is tuned for that size of machine. It's been enough for two years.

When I eventually want local LLM inference, I'll add a Mac Mini at home and have the VPS dispatch to it. No need to switch wholesale — add, don't replace.

## TL;DR

- **Start here:** Hetzner CX22 (~$5/mo)
- **Upgrade on evidence:** memory-guardian restarts > 2x/week, or disk > 80% full
- **Stop climbing the tier ladder at CX42.** Past that, ask whether a Mac Mini makes more sense.
- **Mac Mini if:** 3-year horizon + local LLM ambitions + reliable home power + data locality matters
- **Hybrid (cheap VPS + home Mac Mini) if:** you want the best of both
