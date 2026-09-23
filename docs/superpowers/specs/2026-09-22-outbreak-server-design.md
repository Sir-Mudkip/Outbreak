# Outbreak — headless server image design

Date: 2026-09-22
Status: approved in brainstorming, awaiting written-spec review

## Purpose

Outbreak is a headless bootc server image for a single home server. It is the
server counterpart to Sivablue (the desktop image) and reuses Sivablue's build
patterns. The server provides compute; bulk storage lives on a separate NAS.

What the server does:

- GPU compute: hashcat and a local LLM on an AMD RX 7900 XTX.
- Self-hosted services: Jellyfin (public, via Cloudflare), the *arr stack, a
  torrent client routed through AirVPN, Caddy, a LAN container registry.
- Security labs: GOAD and a Kubernetes lab, attacked only from the owner's
  laptop/PC over Tailscale.
- Remote administration over SSH and Cockpit, via Tailscale.

## Hardware

| Part | Detail | Design consequence |
|---|---|---|
| CPU | Intel Core Ultra 7 265K (20 cores, Arc Xe iGPU) | iGPU does Jellyfin transcoding (Quick Sync); must be enabled in BIOS alongside the dGPU |
| RAM | 64 GB DDR5-6000 | Everything fits, but GOAD full + Kubernetes lab + a large LLM at full load together is tight |
| GPU | AMD RX 7900 XTX (gfx1100, 24 GB VRAM) | Officially supported by ROCm; reserved for hashcat and LLMs. A second 7900 XTX is a possible later addition |
| Disk 1 | Samsung 990 Pro 2 TB | OS, container images, service state, LLM models |
| Disk 2 | 1 TB SSD (planned) | libvirt storage pool for lab VM images |

## Repositories

Two repositories, deliberately split:

- **`Outbreak` (public)** — the OS image only: packages, drivers, firewall
  defaults, systemd units and the rootless service account. It does not
  describe which services run.
- **`outbreak-services` (private)** — Quadlet files, Caddy configuration and
  per-service settings. Hosted on the NAS or as a private GitHub repo.

Neither repository contains secrets or TLS material. Secrets are Podman secrets
on the server; Caddy obtains and stores its own certificates.

## Layer 1 — the Outbreak image

Base: `quay.io/fedora/fedora-bootc:44`. Chosen over CentOS Stream 10 for a
current kernel (amdgpu/ROCm maturity on RDNA3) and Fedora's package set. The
cost is a Fedora version bump roughly every 6–12 months; bootc rollback makes
that low-risk.

Structure follows Sivablue: `Containerfile`, numbered `build/NN-*.sh` stages
called by name from `build/build.sh`, a `system/` tree mirrored into the image,
and `build/99-tests.sh` as the build's own gate.

Contents:

- **Access** — OpenSSH (key-only), Cockpit (Podman, Machines, Storage, PCP
  metrics pages), Tailscale. Admin access permitted only on the Tailscale
  interface.
- **Containers** — Podman with Quadlet. No Docker.
- **Virtualization** — `libvirt-daemon-kvm`, `qemu-kvm`, `virt-install`,
  `swtpm`, `vagrant`, `vagrant-libvirt`.
- **GPU compute** — `hashcat`, `rocm-hip`, `rocm-runtime`, `rocm-opencl`
  installed on the host. hashcat uses its HIP backend directly on the host
  (no container passthrough layer). `amdgpu` and Intel `xe` drivers come from
  the Fedora kernel.
- **Storage** — NFS client for the NAS share.
- **Firewall** — firewalld; nothing open on the LAN by default beyond what
  Caddy needs; Tailscale interface trusted; lab network rules (Layer 3).
- **Monitoring** — Cockpit + PCP only. No dashboards, no alerting.
- **Updates** — a daily timer stages new images (`bootc upgrade` download
  only). Reboots are manual. Staged updates are checked with
  `ujust update-status` (no login notice; headless server).

Not in the image: services, GOAD and its Ansible, Kubernetes, LLM models,
Ollama's ROCm libraries (bundled in its container).

## Layer 2 — services (private repo)

Run as rootless Podman Quadlets under a dedicated service account (in the
`render` and `video` groups). Quadlets for that account live in
`/etc/containers/systemd/users/<uid>/`; how they are deployed from the private
repo is decided in the services plan. Updated daily by `podman auto-update` with automatic
rollback on failed health checks.

| Group | Services | Reachable from |
|---|---|---|
| Public | `cloudflared` → Jellyfin | Internet, via Cloudflare Tunnel only |
| Media | *arr stack; torrent client inside Gluetun | LAN + tailnet, via Caddy |
| LLM | LiteLLM → Ollama | LAN + tailnet, via Caddy, API key required |
| Registry | LAN container registry | LAN + tailnet, via Caddy |
| Edge | Caddy | LAN + tailnet |

Each group has its own Podman network; the public group cannot reach the
others.

### Jellyfin and Cloudflare

- Published through a **Cloudflare Tunnel**: outbound-only, no router port
  forward, home IP never in DNS. Chosen for DoS protection and to guarantee
  that only Cloudflare-originated traffic reaches Jellyfin.
- Known risk, accepted by the owner: Cloudflare's CDN terms restrict proxying
  video. Fallback if Cloudflare objects: DNS-only record + port forward to
  Caddy.
- Cloudflare cache rule bypasses caching for the Jellyfin hostname;
  WebSockets enabled.
- Transcoding on the Intel iGPU (`/dev/dri` of the iGPU only). Media mounted
  read-only.

### Torrent client and AirVPN

- The torrent client uses `Network=container:gluetun` — it has no network of
  its own.
- Kill switch: Gluetun's firewall drops all non-tunnel traffic; the client is
  also bound to the tunnel interface. DNS goes through the tunnel.
- AirVPN forwarded port configured in Gluetun and passed to the client.
- Web UI published on Gluetun, reachable from LAN/tailnet via Caddy.

### LLM access

- **LiteLLM** sits in front of Ollama: per-client virtual keys, per-key rate
  limits and budgets, usage logs, OpenAI- and Anthropic-format endpoints.
  Backed by a small Postgres.
- Every client needs a key: OpenCode, Claude Code, Burp MCP's AI client,
  future custom tooling.
- Ollama runs the ROCm container with `/dev/kfd` and `/dev/dri` and is never
  published directly.
- No separate identity provider. Web UIs rely on their own logins plus
  LAN/tailnet-only exposure. Authelia can be added later for single sign-on.

### Registry

- Pushes require credentials; pulls on LAN/tailnet may be anonymous.
- Pushes come only from CI on `main` (see Layer 4).

### TLS on the LAN

Caddy obtains real certificates for LAN-only hostnames via the Cloudflare DNS
API (DNS-01). Required for the registry (Podman and bootc refuse invalid TLS by
default) and avoids self-signed warnings elsewhere.

### Storage

- NFS: one share, `/mnt/nas/data`, containing `downloads/` and `media/`, so
  the *arr apps can hardlink rather than copy.
- Local SSD: service config and databases under `/var/lib/outbreak/<service>`;
  Ollama models under `/var/lib/outbreak/ollama`.

## Layer 3 — labs

- **GOAD** runs on libvirt via the `vagrant-libvirt` provider from GOAD PR
  #475 (open and mergeable; tested by others with full GOAD on libvirt 10.9).
  GOAD is a Git checkout of the PR branch in the owner's home directory with its
  own Python venv. The PR uses jborean93's Windows Server 2016/2019 Vagrant
  boxes.
- **Kubernetes lab** — K3s or minikube VMs on libvirt; chosen later.
- VM images live in a libvirt pool on the second SSD once fitted.
  Snapshots are used to reset labs.
- **Networks** — `goad-lab` and `k8s-lab` libvirt networks:
  - outbound internet allowed (NAT) for provisioning; can be switched to
    isolated afterwards;
  - lab → LAN blocked;
  - lab → server services (Caddy, LiteLLM, registry, Cockpit) blocked;
  - inbound only from the owner's laptop/PC via a Tailscale subnet route
    restricted by tailnet ACLs.
- **No attack tooling or attack VM on the server.** Labs are attacked only from
  the owner's own machines.

## Layer 4 — build, CI and signing

- GitHub Actions builds on push to `main` only, plus a scheduled rebuild. No
  workflows run on fork pull requests. Branch protection limits `main` to the
  owner.
- Published to GHCR (public) as the `bootc upgrade` source.
- Experimental images pushed to the LAN registry by a CI job that joins the
  tailnet with an ephemeral, tagged Tailscale key whose ACL allows only the
  registry port.
- Signed with cosign using a **new Outbreak keypair**. The image's
  `policy.json` requires that signature.
- `99-tests.sh` checks: hashcat and ROCm installed and start; required
  packages present; unwanted packages absent; sshd, cockpit, tailscaled and
  libvirtd enabled; firewall defaults present. GPU function is verified on the
  hardware after first boot (CI runners have no GPU).

## Layer 5 — installation

- `image-builder` (osbuild; formerly `bootc-image-builder`) builds an Anaconda
  ISO from the signed image. Starting point: Sivablue's `iso/disk.toml`.
- Config: owner user with SSH key, groups `wheel`, `libvirt`, `render`,
  `video`; disk layout on the 990 Pro; signed-image source set so the first
  `bootc upgrade` verifies the signature.
- Ignition is not used: `fedora-bootc` does not ship it.

First-boot checklist:

1. `tailscale up`
2. Create Podman secrets (Cloudflare tunnel token, AirVPN WireGuard keys,
   LiteLLM master key, registry credentials, Cloudflare DNS API token).
3. Deploy the Quadlets from `outbreak-services` (method set by the services plan).
4. GPU checks: `rocm-smi`, `hashcat -I`, `hashcat -b`.
5. Mount the NAS; do a test *arr import to confirm hardlinks work.
6. Create the libvirt storage pool once the second SSD is fitted.

## Open items (decide during implementation)

- Registry software: Zot or `registry:2`.
- Torrent client: qBittorrent assumed.
- Kubernetes lab form: K3s VMs or minikube.
- GOAD: track PR #475 and move to upstream once merged.

## Out of scope

- File serving and Git hosting (the NAS does these).
- Dashboards, alerting, SSO.
- Any attack VM or attack tooling on the server.
