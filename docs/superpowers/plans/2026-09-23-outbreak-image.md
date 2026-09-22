# Outbreak Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, sign, publish and install `ghcr.io/sir-mudkip/outbreak`, a headless Fedora bootc server image, so the physical server can be installed from an ISO and kept up to date with `bootc`.

**Architecture:** A `Containerfile` layers numbered shell stages (`build/NN-*.sh`, called by name from `build/build.sh`) and a `system/` tree over `quay.io/fedora/fedora-bootc:44`. `build/99-tests.sh` is the build's own test gate: every task adds its assertions there first, runs a build to watch them fail, then implements. GitHub Actions builds, rechunks, pushes and cosign-signs on push to `master`; `bootc-image-builder` turns the published image into an installer ISO.

**Tech Stack:** Fedora bootc 44, dnf5, systemd (units, sysusers.d, tmpfiles.d), firewalld, nftables, Podman, just, cosign, GitHub Actions, `ghcr.io/osbuild/bootc-image-builder`.

**Spec:** `docs/superpowers/specs/2026-09-22-outbreak-server-design.md`

**Scope:** This plan implements spec Layer 1 (the image), Layer 4 (CI and signing) and Layer 5 (installation). Layer 2 (services, in the private `outbreak-services` repo) and Layer 3 (GOAD and Kubernetes lab setup on the running server) get their own plans later. The image-side prerequisites for those layers (the rootless service account and lab network containment) are in this plan; how Quadlets get deployed is decided in the services plan.

## Global Constraints

- Base image: `quay.io/fedora/fedora-bootc:44`. Fedora version lives in one place: `ARG FEDORA_VERSION=44` in `Containerfile`.
- Image name `outbreak`; registry path `ghcr.io/sir-mudkip/outbreak` (GHCR paths must be lowercase). Default tag `stable`.
- Package installs use `dnf5` only (never `dnf`, `yum` or `rpm-ostree`), always as `dnf5 -y install --setopt=install_weak_deps=False …`.
- Every build stage: `#!/usr/bin/bash`, `set -eoux pipefail`, wrapped in `echo "::group:: ===$(basename "$0")==="` / `echo "::endgroup::"`, file mode `0755`, and called **by name** from `build/build.sh` (it does not glob).
- Static files go in `system/` (mirrored into `/usr` and `/etc`); anything that runs goes in a `build/` stage. Nothing installs under `/opt`.
- `build/99-tests.sh` runs **after** `build/98-clean-stage.sh`, so tests must not write under `/var` or `$HOME`; use `HOME=/tmp/…` for tools that create state.
- No services, secrets, TLS material or personal data in this public repo. `cosign.key` and `iso/config.toml` are gitignored.
- Admin access (SSH, Cockpit on 9090) is Tailscale-only; the LAN zone exposes only HTTP/HTTPS (for Caddy) and Tailscale's UDP port.
- OS updates are downloaded and staged automatically; reboots are always manual.
- Default branch is `master`. Commits follow Conventional Commits (`<type>(<scope>): <description>`) and end with:

  ```
  Assisted-by: Claude Opus 5.5 via Claude Code
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```

- Tooling on the development machine: `podman`, `just`, `shellcheck`, `cosign`, `gh`, `jq`, `skopeo`, `virt-install`. `just lint` only sees files tracked by git, so `git add` new scripts before linting.
- Clean up after every local build: `just clean-images` removes the images this repo builds.
- In `99-tests.sh`, never pipe into `grep -q`: under `pipefail` its early exit can SIGPIPE the producer and flip the result. Use `grep -c … >/dev/null` instead.

## Deviations from the spec (flag to the owner at hand-off)

1. **ISO disk selection is interactive.** The spec said the ISO config sets the disk layout on the 990 Pro. With a second SSD planned, an unattended `clearpart` could wipe the wrong disk, so the ISO sets up the user and SSH key but lets Anaconda ask which disk to use.
2. **Pending-update notice:** implemented as a login message (`/run/motd.d`) plus `ujust update-status`. Whether Cockpit's Overview page shows it is checked on the hardware (Task 9); the spec assumed it would.
3. **CI → LAN registry push is deferred** to the services plan, because the registry does not exist yet.
4. **Tailnet → lab routing:** libvirt NAT networks reject new inbound connections from outside the host, so reaching lab VMs over a Tailscale subnet route needs route-mode (or `open`) libvirt networks. That is lab configuration, not image content, and belongs to the labs plan. This plan ships the containment rules and IP forwarding those networks will rely on.
5. **Tailscale comes from Fedora's own repo** (1.98.x), not `pkgs.tailscale.com`, so the image adds no third-party repositories.

## File Structure

```
Containerfile                         base image, ctx stage, runs build.sh, bootc lint
Justfile                              check / fix / lint / build / test-image / clean-images / tag-images / verify / build-iso / test-install
CLAUDE.md, AGENTS.md -> CLAUDE.md     rules for agents working in this repo
.gitignore, .hadolint.yaml
cosign.pub                            public signing key (Task 7)
build/
  build.sh                            copies system/, calls every stage by name
  00-image-info.sh                    image-info.json + os-release fields
  10-admin.sh                         Cockpit, PCP, Tailscale, firewalld, sshd policy (Task 2)
  20-virt.sh                          libvirt/KVM, vagrant-libvirt, swtpm SELinux, lab firewall unit (Task 3)
  30-gpu.sh                           hashcat + ROCm runtime (Task 4)
  40-services.sh                      just, service account prerequisites (Task 5)
  50-updates.sh                       stage-only update timer (Task 6)
  98-clean-stage.sh                   strip build residue
  99-tests.sh                         build test gate
system/
  etc/firewalld/zones/outbreak.xml
  etc/ssh/sshd_config.d/40-outbreak.conf
  etc/containers/policy.json, etc/containers/registries.d/outbreak.yaml
  etc/subuid, etc/subgid
  usr/bin/ujust
  usr/libexec/outbreak/update-motd
  usr/lib/pki/containers/outbreak.pub
  usr/lib/sysctl.d/60-outbreak-forwarding.conf, 61-outbreak-unprivileged-ports.conf
  usr/lib/sysusers.d/outbreak-svc.conf
  usr/lib/tmpfiles.d/outbreak-svc.conf, libvirt-workaround.conf, swtpm-workaround.conf
  usr/lib/systemd/system/outbreak-lab-firewall.service, outbreak-stage-update.{service,timer},
                         libvirt-workaround.service, swtpm-workaround.service
  usr/share/outbreak/lab-firewall.nft
  usr/share/outbreak/just/{main,updates,system}.just
iso/config.example.toml               template; iso/config.toml is local-only
.github/workflows/{build,validate,clean}.yml
docs/README.md, docs/build-stages.md, docs/networking.md, docs/updates.md, docs/signing.md, docs/install.md
```

---

### Task 1: Scaffold a minimal image that builds and passes `bootc container lint`

**Files:**
- Create: `Containerfile`, `Justfile`, `.gitignore`, `.hadolint.yaml`, `CLAUDE.md`, `AGENTS.md` (symlink), `build/build.sh`, `build/00-image-info.sh`, `build/98-clean-stage.sh`, `build/99-tests.sh`, `docs/README.md`, `docs/build-stages.md`

**Interfaces:**
- Produces: build ARGs/env vars `FEDORA_VERSION`, `IMAGE_NAME`, `IMAGE_VENDOR`, `VERSION` available to every stage; `/usr/share/outbreak/` as the image's data directory; recipes `just build`, `just lint`, `just check`, `just clean-images` (Task 2 adds `just test-image`); local image tag `localhost/outbreak:stable`.

- [ ] **Step 1: Write the test gate first**

Create `build/99-tests.sh` (mode 0755):

```bash
#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# Runs after 98-clean-stage.sh: never write under /var or $HOME here.

# --- Image identity (Task 1) ---
test -f /usr/share/outbreak/image-info.json
jq -e '."image-name" == "outbreak"' /usr/share/outbreak/image-info.json
grep -q '^VARIANT_ID="outbreak"$' /usr/lib/os-release
grep -q '^IMAGE_ID="outbreak"$' /usr/lib/os-release

echo "::endgroup::"
```

- [ ] **Step 2: Write the Containerfile, build.sh and clean stage (no image-info stage yet)**

`Containerfile`:

```dockerfile
# Outbreak — see docs/build-stages.md
ARG FEDORA_VERSION=44

FROM scratch AS ctx
COPY build /build
COPY system /system

FROM quay.io/fedora/fedora-bootc:${FEDORA_VERSION}

ARG FEDORA_VERSION=44
ARG IMAGE_NAME="outbreak"
ARG IMAGE_VENDOR="sir-mudkip"
ARG VERSION="local"

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/build.sh

RUN bootc container lint
```

`build/build.sh` (mode 0755):

```bash
#!/usr/bin/bash

set -eoux pipefail

echo "::group:: Copy system files"
# git does not track empty directories, so either half may be absent early on.
if [[ -d /ctx/system/usr ]]; then
    cp -rT /ctx/system/usr/ /usr/
fi
if [[ -d /ctx/system/etc ]]; then
    cp -rT /ctx/system/etc/ /etc/
fi
echo "::endgroup::"

# Stages are called by name, in order. A new stage must be added here.
/ctx/build/98-clean-stage.sh
/ctx/build/99-tests.sh
```

`build/98-clean-stage.sh` (mode 0755):

```bash
#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

dnf5 clean all

rm -rf /.gitkeep
# /var/cache and /var/log are build cache mounts and /tmp is a tmpfs; removing
# the mount points themselves fails harmlessly (find ignores -exec failures,
# and a failing `rm` on the left of && does not trip set -e).
find /var/* -maxdepth 0 -type d \! -name cache -exec rm -fr {} \;
find /var/cache/* -maxdepth 0 -type d \! -name libdnf5 -exec rm -fr {} \;
rm -rf /tmp && mkdir -p /tmp
# /run is a tmpfs at runtime; podman bind-mounts some files there during RUN.
find /run -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
# /boot is populated by the bootc install.
# shellcheck disable=SC2114
rm -rf /boot && mkdir -p /boot

echo "::endgroup::"
```

`.gitignore`:

```
cosign.key
iso/config.toml
output/
.claude/
```

`.hadolint.yaml`:

```yaml
ignored:
  - DL3059 # Consecutive RUN instructions are intentional
```

- [ ] **Step 3: Write the Justfile**

```just
export image_name := env("IMAGE_NAME", "outbreak")
export default_tag := env("DEFAULT_TAG", "stable")
export PODMAN := env("PODMAN", "podman")
export REPO_ORG := env("GITHUB_REPOSITORY_OWNER", "sir-mudkip")

[private]
default:
    @just --list

# Check Justfile and ujust syntax
[group('Just')]
check:
    #!/usr/bin/bash
    set -euo pipefail
    find . -type f -name "*.just" | while read -r file; do
        echo "Checking syntax: $file"
        just --unstable --fmt --check -f "$file"
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Fix Justfile and ujust formatting
[group('Just')]
fix:
    #!/usr/bin/bash
    set -euo pipefail
    find . -type f -name "*.just" | while read -r file; do
        just --unstable --fmt -f "$file"
    done
    just --unstable --fmt -f Justfile

# Shellcheck every tracked shell script (by .sh suffix or shebang)
[group('Lint')]
lint:
    #!/usr/bin/env bash
    set -eou pipefail
    command -v shellcheck >/dev/null || { echo "shellcheck is not installed"; exit 1; }
    mapfile -t scripts < <(
        git ls-files | while read -r f; do
            [ -f "$f" ] || continue
            case "$f" in
                *.sh) echo "$f" ;;
                *) head -c2 "$f" 2>/dev/null | grep -q '#!' && echo "$f" ;;
            esac
        done
    )
    if [ "${#scripts[@]}" -eq 0 ]; then
        echo "No shell scripts found to lint."
        exit 1
    fi
    echo "Linting ${#scripts[@]} shell scripts..."
    shellcheck "${scripts[@]}"

# Build the image
[group('Image')]
build $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail
    fedora_version=$(grep -E '^ARG FEDORA_VERSION=' Containerfile | head -n1 | grep -oE '[0-9]+')
    ver="${fedora_version}.$(date -u +%Y%m%d)"
    BUILD_ARGS=(
        --build-arg "VERSION=${ver}"
        --build-arg "IMAGE_NAME=${target_image}"
        --build-arg "IMAGE_VENDOR=${REPO_ORG,,}"
    )
    LABELS=(
        --label "containers.bootc=1"
        --label "org.opencontainers.image.title=${target_image}"
        --label "org.opencontainers.image.version=${ver}"
        --label "org.opencontainers.image.description=Outbreak headless server"
        --label "org.opencontainers.image.source=https://github.com/Sir-Mudkip/Outbreak"
        --label "org.opencontainers.image.licenses=Apache-2.0"
        --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    )
    ${PODMAN} build "${BUILD_ARGS[@]}" "${LABELS[@]}" --pull=newer --tag "${target_image}:${tag}" .

# Remove images this repo builds (run at the end of every session)
[group('Image')]
clean-images:
    #!/usr/bin/bash
    set -uo pipefail
    ${PODMAN} rmi -f "localhost/${image_name}:${default_tag}" 2>/dev/null || true
    ${PODMAN} image prune -f --filter "label=org.opencontainers.image.title=${image_name}" || true
    ${PODMAN} rmi -f "quay.io/fedora/fedora-bootc:44" 2>/dev/null || true
    echo "Remaining images:"
    ${PODMAN} images
```

- [ ] **Step 4: Run the build to verify the test fails**

Run: `git add -A && just build`
Expected: FAIL in `99-tests.sh` at `test -f /usr/share/outbreak/image-info.json`.

- [ ] **Step 5: Implement the image-info stage**

`build/00-image-info.sh` (mode 0755):

```bash
#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -euox pipefail

IMAGE_INFO="/usr/share/outbreak/image-info.json"
OS_RELEASE="/usr/lib/os-release"
IMAGE_REF="ostree-image-signed:docker://ghcr.io/${IMAGE_VENDOR}/${IMAGE_NAME}"

mkdir -p /usr/share/outbreak
cat >"${IMAGE_INFO}" <<EOF
{
  "image-name": "${IMAGE_NAME}",
  "image-vendor": "${IMAGE_VENDOR}",
  "image-ref": "${IMAGE_REF}",
  "fedora-version": "${FEDORA_VERSION}",
  "version": "${VERSION}"
}
EOF

# Upsert KEY="value" in os-release. ID stays "fedora" so tooling keeps working.
set_os_release_field() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "${OS_RELEASE}"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "${OS_RELEASE}"
    else
        echo "${key}=\"${value}\"" >>"${OS_RELEASE}"
    fi
}

set_os_release_field "PRETTY_NAME" "Outbreak (${VERSION})"
set_os_release_field "VARIANT" "Outbreak"
set_os_release_field "VARIANT_ID" "outbreak"
set_os_release_field "IMAGE_ID" "${IMAGE_NAME}"
set_os_release_field "IMAGE_VERSION" "${VERSION}"
set_os_release_field "HOME_URL" "https://github.com/Sir-Mudkip/Outbreak"
set_os_release_field "BUG_REPORT_URL" "https://github.com/Sir-Mudkip/Outbreak/issues"

echo "::endgroup::"
```

Add it to `build/build.sh`, before the clean stage:

```bash
# Stages are called by name, in order. A new stage must be added here.
/ctx/build/00-image-info.sh
/ctx/build/98-clean-stage.sh
/ctx/build/99-tests.sh
```

- [ ] **Step 6: Run the build to verify it passes**

Run: `git add -A && just build`
Expected: PASS, ending with `bootc container lint` reporting no errors (warnings are acceptable; read them).

- [ ] **Step 7: Lint and syntax-check**

Run: `just lint && just check`
Expected: both exit 0.

- [ ] **Step 8: Write the agent rules and docs**

`CLAUDE.md`:

```markdown
# Outbreak

A headless bootc server image built on `quay.io/fedora/fedora-bootc:44`.
Design: `docs/superpowers/specs/2026-09-22-outbreak-server-design.md`.
Rules live here; the reasoning behind them lives in `docs/` (index: `docs/README.md`).

## Rules

- Static files go in `system/` (mirrored into `/usr` and `/etc`). Anything that runs goes in a `build/NN-name.sh` stage.
- `build/build.sh` calls stages **by name**. A new stage must be added there or it never runs.
- Stage boilerplate: `#!/usr/bin/bash`, `set -eoux pipefail`, `::group::`/`::endgroup::` markers, mode 0755.
- `dnf5 -y install --setopt=install_weak_deps=False …` only. Never `dnf`, `yum` or `rpm-ostree`.
- Add a check to `build/99-tests.sh` for everything you add. It runs after the clean stage: never write under `/var` or `$HOME` there.
- This repo is public. No service definitions, secrets, TLS material or personal data. Services live in the private `outbreak-services` repo.
- Never commit `cosign.key` or `iso/config.toml`.
- Conventional commits (`<type>(<scope>): <description>`), with `Assisted-by: <Model> via <Tool>` in the footer for AI-assisted commits.
- Run `just clean-images` at the end of every session that built images.

## Validation

    just check   # just syntax
    just lint    # shellcheck (tracked files only: git add first)
    just build   # full image build, including 99-tests.sh and bootc container lint
```

Then: `ln -s CLAUDE.md AGENTS.md`

`docs/README.md`:

```markdown
# Outbreak documentation

| Topic | Page |
|---|---|
| Build stages and ordering | [build-stages.md](build-stages.md) |
| Firewall, Tailscale-only admin, lab containment | [networking.md](networking.md) |
| Update staging and manual reboots | [updates.md](updates.md) |
| Image signing and key rotation | [signing.md](signing.md) |
| Building the ISO and first boot | [install.md](install.md) |

When a design decision changes, update the relevant page in the same commit.
```

`docs/build-stages.md`:

```markdown
# Build stages

`build/build.sh` copies `system/usr` and `system/etc` into the image, then runs
each stage by name. Numbers set the order.

| Stage | Purpose |
|---|---|
| `00-image-info.sh` | Writes `/usr/share/outbreak/image-info.json` and sets `VARIANT_ID`, `IMAGE_ID`, `IMAGE_VERSION` and `PRETTY_NAME` in os-release. `ID` stays `fedora` so Fedora tooling keeps recognising the system. |
| `98-clean-stage.sh` | Removes dnf caches and build residue from `/var`, `/tmp`, `/run` and `/boot` so `bootc container lint` passes. |
| `99-tests.sh` | The build's own test gate. Runs last; a failing check fails the build. |

`99-tests.sh` runs after the clean stage, so anything it writes would ship in
the image. Tools that create state run with `HOME=/tmp/…`.
```

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "build: scaffold the Outbreak bootc image

Assisted-by: Claude Opus 5.5 via Claude Code
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 10: Clean up**

Run: `just clean-images`
Expected: `localhost/outbreak:stable` and the fedora-bootc base are gone from `podman images`.

---

### Task 2: Admin access — SSH, Cockpit, PCP, Tailscale and the firewall

**Files:**
- Create: `build/10-admin.sh`, `system/etc/ssh/sshd_config.d/40-outbreak.conf`, `system/etc/firewalld/zones/outbreak.xml`, `docs/networking.md`
- Modify: `build/build.sh`, `build/99-tests.sh`, `docs/build-stages.md`, `Justfile` (add `test-image`)

**Interfaces:**
- Consumes: Task 1 build pipeline.
- Produces: firewalld default zone `outbreak` (LAN) and `tailscale0` in zone `trusted`; enabled units `sshd.service`, `cockpit.socket`, `tailscaled.service`, `firewalld.service`, `pmcd.service`, `pmlogger.service`; recipe `just test-image` that later tasks extend.

- [ ] **Step 1: Add the failing tests**

In `build/99-tests.sh`, insert before the final `echo "::endgroup::"`:

```bash
# --- Admin access (Task 2) ---
for package in cockpit-ws cockpit-system cockpit-podman cockpit-storaged cockpit-files \
    cockpit-networkmanager cockpit-selinux pcp pcp-zeroconf python3-pcp tailscale firewalld tmux htop; do
    rpm -q "${package}" >/dev/null || { echo "Missing package: ${package}"; exit 1; }
done
for unit in sshd.service cockpit.socket tailscaled.service firewalld.service pmcd.service pmlogger.service; do
    systemctl is-enabled --quiet "${unit}" || { echo "Not enabled: ${unit}"; exit 1; }
done
grep -qx 'PasswordAuthentication no' /etc/ssh/sshd_config.d/40-outbreak.conf
grep -qx 'PermitRootLogin no' /etc/ssh/sshd_config.d/40-outbreak.conf
[[ "$(firewall-offline-cmd --get-default-zone)" == "outbreak" ]]
firewall-offline-cmd --zone=trusted --list-interfaces | grep -cw tailscale0 >/dev/null
if firewall-offline-cmd --zone=outbreak --list-services | grep -cwE 'ssh|cockpit' >/dev/null; then
    echo "SSH/Cockpit must not be open on the LAN zone"; exit 1
fi
firewall-offline-cmd --zone=outbreak --list-services | grep -cw https >/dev/null
```

- [ ] **Step 2: Run the build to verify the tests fail**

Run: `git add -A && just build`
Expected: FAIL at `Missing package: cockpit-ws`.

- [ ] **Step 3: Add the static configuration**

`system/etc/ssh/sshd_config.d/40-outbreak.conf` (sorts before Fedora's `50-redhat.conf`, and sshd uses the first value it reads):

```
# Key-only SSH. See docs/networking.md.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
```

`system/etc/firewalld/zones/outbreak.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<zone target="default">
  <short>Outbreak LAN</short>
  <description>LAN-facing zone. Only Caddy (HTTP/HTTPS) and Tailscale's peer port are open. SSH and Cockpit are reachable over Tailscale only (tailscale0 is in the trusted zone). See docs/networking.md.</description>
  <service name="http"/>
  <service name="https"/>
  <service name="dhcpv6-client"/>
  <port port="41641" protocol="udp"/>
</zone>
```

- [ ] **Step 4: Write the stage**

`build/10-admin.sh` (mode 0755):

```bash
#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

ADMIN_PACKAGES=(
    cockpit-files
    cockpit-networkmanager
    cockpit-podman
    cockpit-selinux
    cockpit-storaged
    cockpit-system
    cockpit-ws
    firewalld
    htop
    pcp
    pcp-zeroconf
    python3-pcp
    tailscale
    tmux
)

dnf5 -y install --setopt=install_weak_deps=False "${ADMIN_PACKAGES[@]}"

systemctl enable \
    sshd.service \
    cockpit.socket \
    tailscaled.service \
    firewalld.service \
    pmcd.service \
    pmlogger.service

# system/etc/firewalld/zones/outbreak.xml is already in place (build.sh copies
# system/ first). Make it the default zone and trust the tailnet interface.
firewall-offline-cmd --set-default-zone=outbreak
firewall-offline-cmd --zone=trusted --add-interface=tailscale0

echo "::endgroup::"
```

Add to `build/build.sh` after `00-image-info.sh`:

```bash
/ctx/build/10-admin.sh
```

- [ ] **Step 5: Run the build to verify it passes**

Run: `git add -A && just build`
Expected: PASS.

- [ ] **Step 6: Add `just test-image` (post-build checks that need a running container)**

Append to `Justfile`:

```just
# Post-build checks that need capabilities the build sandbox lacks
[group('Image')]
test-image $target_image=image_name $tag=default_tag:
    #!/usr/bin/bash
    set -euo pipefail
    img="localhost/${target_image}:${tag}"
    echo "sshd config parses:"
    ${PODMAN} run --rm "${img}" bash -c 'ssh-keygen -A >/dev/null && /usr/sbin/sshd -t'
```

Run: `just test-image`
Expected: exits 0 (`sshd -t` prints nothing on success).

- [ ] **Step 7: Document**

`docs/networking.md`:

```markdown
# Networking and firewall

## Zones

| Interface | Zone | Open |
|---|---|---|
| LAN NIC (default) | `outbreak` | HTTP/HTTPS (Caddy), DHCPv6 client, UDP 41641 (Tailscale direct peer connections) |
| `tailscale0` | `trusted` | Everything: SSH, Cockpit (9090), services |

SSH and Cockpit are deliberately **not** open on the LAN. If Tailscale is down,
admin access is via the physical console.

## SSH

`/etc/ssh/sshd_config.d/40-outbreak.conf` disables passwords, keyboard-interactive
auth and root login. It sorts before Fedora's `50-redhat.conf`, and sshd keeps
the first value it reads for each option.

## Cockpit

`cockpit.socket` listens on 9090, reachable only through `tailscale0`. Metrics
history comes from PCP (`pcp-zeroconf` sets up `pmcd`/`pmlogger`); Cockpit reads
it through `python3-pcp` (there is no separate `cockpit-pcp` package any more).

## Tailscale

From Fedora's own repository, so the image carries no third-party repos.
Authenticate once after install with `sudo tailscale up`.
```

Add a row to the table in `docs/build-stages.md`:

```markdown
| `10-admin.sh` | Cockpit (+ Podman, storage, files, network, SELinux pages), PCP, Tailscale, firewalld, tmux, htop. Sets the `outbreak` zone as default and puts `tailscale0` in `trusted`. See networking.md. |
```

- [ ] **Step 8: Lint and commit**

```bash
just lint && just check
git add -A
git commit -m "feat(admin): add Cockpit, PCP, Tailscale and a Tailscale-only admin firewall

Assisted-by: Claude Opus 5.5 via Claude Code
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
just clean-images
```

---

### Task 3: Virtualization and lab network containment

**Files:**
- Create: `build/20-virt.sh`, `system/usr/share/outbreak/lab-firewall.nft`, `system/usr/lib/systemd/system/outbreak-lab-firewall.service`, `system/usr/lib/sysctl.d/60-outbreak-forwarding.conf`, `system/usr/lib/tmpfiles.d/libvirt-workaround.conf`, `system/usr/lib/tmpfiles.d/swtpm-workaround.conf`, `system/usr/lib/systemd/system/libvirt-workaround.service`, `system/usr/lib/systemd/system/swtpm-workaround.service`
- Modify: `build/build.sh`, `build/99-tests.sh`, `Justfile` (`test-image`), `docs/networking.md`, `docs/build-stages.md`

**Interfaces:**
- Consumes: Task 2 (`just test-image`, firewalld).
- Produces: nftables table `inet outbreak_labs` loaded by `outbreak-lab-firewall.service` before libvirt's network daemon; containment applies to every interface matching `virbr*`. The labs plan must keep lab networks on `virbr*` bridges.

- [ ] **Step 1: Add the failing tests**

In `build/99-tests.sh`, before the final `echo "::endgroup::"`:

```bash
# --- Virtualization and lab containment (Task 3) ---
for package in libvirt-daemon-kvm libvirt-daemon-config-network libvirt-client qemu-kvm \
    virt-install swtpm swtpm-tools vagrant vagrant-libvirt cockpit-machines; do
    rpm -q "${package}" >/dev/null || { echo "Missing package: ${package}"; exit 1; }
done
for unit in virtqemud.socket virtnetworkd.socket virtstoraged.socket virtnodedevd.socket \
    virtsecretd.socket virtproxyd.socket outbreak-lab-firewall.service \
    libvirt-workaround.service swtpm-workaround.service; do
    systemctl is-enabled --quiet "${unit}" || { echo "Not enabled: ${unit}"; exit 1; }
done
semodule -l | grep -cx swtpm_libvirt >/dev/null
test -f /usr/share/outbreak/lab-firewall.nft
grep -qx 'net.ipv4.ip_forward = 1' /usr/lib/sysctl.d/60-outbreak-forwarding.conf
```

- [ ] **Step 2: Run the build to verify the tests fail**

Run: `git add -A && just build`
Expected: FAIL at `Missing package: libvirt-daemon-kvm`.

- [ ] **Step 3: Add the containment ruleset and its unit**

`system/usr/share/outbreak/lab-firewall.nft`:

```
#!/usr/bin/nft -f
# Lab containment. See docs/networking.md.
# Lab VMs (any virbr* bridge) may reach the internet and each other, but not
# the LAN, the tailnet, or services on this host. Replies to connections that
# started outside a lab (e.g. from the owner's laptop over Tailscale) pass.
# A drop here is final even if libvirt's or firewalld's own tables accept.

destroy table inet outbreak_labs

table inet outbreak_labs {
    set private4 {
        type ipv4_addr
        flags interval
        elements = { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 }
    }

    set private6 {
        type ipv6_addr
        flags interval
        elements = { fc00::/7, fe80::/10 }
    }

    chain forward {
        type filter hook forward priority filter - 10; policy accept;
        ct state established,related accept
        iifname "virbr*" oifname "virbr*" accept
        iifname "virbr*" ip daddr @private4 drop
        iifname "virbr*" ip6 daddr @private6 drop
    }

    chain input {
        type filter hook input priority filter - 10; policy accept;
        iifname != "virbr*" accept
        ct state established,related accept
        meta l4proto { icmp, ipv6-icmp } accept
        udp dport { 53, 67, 547 } accept
        tcp dport 53 accept
        drop
    }
}
```

`system/usr/lib/systemd/system/outbreak-lab-firewall.service`:

```ini
[Unit]
Description=Outbreak lab network containment rules
Documentation=file:///usr/share/outbreak/lab-firewall.nft
After=firewalld.service
Before=virtnetworkd.service virtqemud.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nft -f /usr/share/outbreak/lab-firewall.nft
ExecStop=/usr/bin/nft destroy table inet outbreak_labs

[Install]
WantedBy=multi-user.target
```

`system/usr/lib/sysctl.d/60-outbreak-forwarding.conf`:

```
# Needed for libvirt NAT networks and for advertising lab subnets over Tailscale.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
```

- [ ] **Step 4: Add the SELinux relabel workarounds (carried over from Sivablue, where they are proven on Fedora bootc)**

`system/usr/lib/tmpfiles.d/libvirt-workaround.conf`:

```
d /var/log/libvirt 0750 - - - -
```

`system/usr/lib/tmpfiles.d/swtpm-workaround.conf`:

```
C /usr/local/bin/overrides/swtpm - - - - /usr/bin/swtpm
d /var/lib/swtpm-localca 0750 tss tss - -
d /var/lib/libvirt/swtpm 0710 tss tss - -
```

`system/usr/lib/systemd/system/libvirt-workaround.service`:

```ini
[Unit]
Description=Workaround to relabel libvirt files and directories
After=local-fs.target

[Service]
Type=oneshot
ExecStart=-/usr/sbin/restorecon -R /var/log/libvirt/
ExecStart=-/usr/sbin/restorecon -R /var/lib/libvirt/
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

`system/usr/lib/systemd/system/swtpm-workaround.service`:

```ini
[Unit]
Description=Workaround swtpm not having the correct label
ConditionFileIsExecutable=/usr/bin/swtpm
After=local-fs.target

[Service]
Type=oneshot
ExecStartPre=/usr/bin/bash -c "[ -x /usr/local/bin/overrides/swtpm ] || /usr/bin/cp /usr/bin/swtpm /usr/local/bin/overrides/swtpm"
ExecStartPre=/usr/bin/mount --bind /usr/local/bin/overrides/swtpm /usr/bin/swtpm
ExecStart=/usr/sbin/restorecon /usr/bin/swtpm
ExecStop=/usr/bin/umount /usr/bin/swtpm
ExecStop=/usr/bin/rm /usr/local/bin/overrides/swtpm
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 5: Write the stage**

`build/20-virt.sh` (mode 0755):

```bash
#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

VIRT_PACKAGES=(
    cockpit-machines
    libvirt-client
    libvirt-daemon-config-network
    libvirt-daemon-kvm
    qemu-kvm
    swtpm
    swtpm-tools
    vagrant
    vagrant-libvirt
    virt-install
)

dnf5 -y install --setopt=install_weak_deps=False "${VIRT_PACKAGES[@]}"

# Modular libvirt daemons. virtproxyd provides the legacy libvirt-sock that
# vagrant-libvirt connects to for qemu:///system.
systemctl enable \
    virtqemud.socket \
    virtnetworkd.socket \
    virtstoraged.socket \
    virtnodedevd.socket \
    virtsecretd.socket \
    virtproxyd.socket \
    outbreak-lab-firewall.service \
    libvirt-workaround.service \
    swtpm-workaround.service

# The swtpm policy modules are not loaded by the RPM scriptlets in an image
# build; without them restorecon cannot label swtpm for libvirt at boot.
semodule -i \
    /usr/share/selinux/packages/swtpm.pp \
    /usr/share/selinux/packages/swtpm_libvirt.pp \
    /usr/share/selinux/packages/swtpm_svirt.pp

echo "::endgroup::"
```

Add to `build/build.sh` after `10-admin.sh`:

```bash
/ctx/build/20-virt.sh
```

- [ ] **Step 6: Run the build to verify it passes**

Run: `git add -A && just build`
Expected: PASS.

- [ ] **Step 7: Check the ruleset parses (needs CAP_NET_ADMIN, so it runs in `test-image`)**

Append inside the `test-image` recipe in `Justfile`:

```just
    echo "lab firewall ruleset parses:"
    ${PODMAN} run --rm --cap-add NET_ADMIN "${img}" nft -c -f /usr/share/outbreak/lab-firewall.nft
```

Run: `just test-image`
Expected: exits 0.

- [ ] **Step 8: Document**

Append to `docs/networking.md`:

```markdown
## Lab containment

`outbreak-lab-firewall.service` loads `/usr/share/outbreak/lab-firewall.nft`
(table `inet outbreak_labs`) before libvirt's network daemon starts. For every
`virbr*` bridge:

| From a lab VM to… | Result |
|---|---|
| The internet | Allowed (libvirt NAT); needed for GOAD provisioning |
| Another lab bridge | Allowed |
| LAN, tailnet, link-local (RFC 1918, 100.64/10, fc00::/7…) | Dropped |
| This host | Only DHCP and DNS (libvirt's dnsmasq) and ICMP; everything else dropped |
| Replies to connections started from outside (your laptop over Tailscale) | Allowed |

The table uses its own base chains at priority `filter - 10`. In nftables a
`drop` in any table is final, so libvirt's and firewalld's `accept` rules
cannot re-open these paths.

**Lab networks must use `virbr*` bridge names**, or they are not contained.
libvirt's defaults and vagrant-libvirt's generated networks both do.

**Reaching labs over Tailscale:** libvirt NAT networks reject new inbound
connections from outside the host. The labs plan sets up route-mode networks
and advertises their subnets with `tailscale up --advertise-routes=…`, limited
by tailnet ACLs to the owner's devices. IP forwarding is enabled in
`/usr/lib/sysctl.d/60-outbreak-forwarding.conf`.
```

Add to `docs/build-stages.md`:

```markdown
| `20-virt.sh` | libvirt/KVM (modular daemons, including `virtproxyd` for vagrant-libvirt), `swtpm` for Windows guests, `vagrant` + `vagrant-libvirt` for GOAD, cockpit-machines. Enables the lab containment firewall and the SELinux relabel workarounds for libvirt and swtpm. |
```

- [ ] **Step 9: Lint and commit**

```bash
just lint && just check
git add -A
git commit -m "feat(virt): add libvirt, vagrant-libvirt and lab network containment

Assisted-by: Claude Opus 5.5 via Claude Code
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
just clean-images
```

---

### Task 4: GPU compute — hashcat and the ROCm runtime

**Files:**
- Create: `build/30-gpu.sh`
- Modify: `build/build.sh`, `build/99-tests.sh`, `docs/build-stages.md`

**Interfaces:**
- Consumes: Task 1 pipeline.
- Produces: `/usr/bin/hashcat`, `libamdhip64.so.7`, `libhiprtc.so.7`, `rocm-smi`, `rocminfo` on the host. GPU function itself is checked on hardware (Task 9 checklist).

- [ ] **Step 1: Add the failing tests**

In `build/99-tests.sh`, before the final `echo "::endgroup::"`:

```bash
# --- GPU compute (Task 4) ---
for package in hashcat rocm-hip rocm-runtime rocm-opencl rocm-smi rocminfo nfs-utils; do
    rpm -q "${package}" >/dev/null || { echo "Missing package: ${package}"; exit 1; }
done
ldconfig -p | grep -c 'libamdhip64.so.7 ' >/dev/null
ldconfig -p | grep -c 'libhiprtc.so.7 ' >/dev/null
# hashcat creates state under $HOME; keep it out of the image.
HOME=/tmp/hashcat-test hashcat --version | grep -cE '^v7\.' >/dev/null
rm -rf /tmp/hashcat-test
```

- [ ] **Step 2: Run the build to verify the tests fail**

Run: `git add -A && just build`
Expected: FAIL at `Missing package: hashcat`.

- [ ] **Step 3: Write the stage**

`build/30-gpu.sh` (mode 0755):

```bash
#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# hashcat's HIP backend loads libamdhip64 and libhiprtc from rocm-hip at run
# time. The amdgpu kernel driver comes with the Fedora kernel. See the spec's
# GPU section for why ROCm is on the host rather than in a container.
GPU_PACKAGES=(
    hashcat
    rocm-hip
    rocm-opencl
    rocm-runtime
    rocm-smi
    rocminfo
)

dnf5 -y install --setopt=install_weak_deps=False "${GPU_PACKAGES[@]}"

echo "::endgroup::"
```

Add to `build/build.sh` after `20-virt.sh`:

```bash
/ctx/build/30-gpu.sh
```

- [ ] **Step 4: Run the build to verify it passes**

Run: `git add -A && just build`
Expected: PASS.

- [ ] **Step 5: Document**

Add to `docs/build-stages.md`:

```markdown
| `30-gpu.sh` | hashcat and the ROCm runtime (`rocm-hip`, `rocm-runtime`, `rocm-opencl`, `rocm-smi`, `rocminfo`) on the host, so hashcat's HIP backend talks to the 7900 XTX directly. Ollama brings its own ROCm libraries in its container. The build can only check that these install and start; GPU checks run on the hardware after first boot (install.md). |
```

- [ ] **Step 6: Lint and commit**

```bash
just lint && just check
git add -A
git commit -m "feat(gpu): install hashcat and the ROCm HIP runtime on the host

Assisted-by: Claude Opus 5.5 via Claude Code
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
just clean-images
```

---

### Task 5: Rootless service account and ujust

**Files:**
- Create: `build/40-services.sh`, `system/usr/bin/ujust`, `system/usr/share/outbreak/just/main.just`, `system/usr/lib/sysusers.d/outbreak-svc.conf`, `system/usr/lib/tmpfiles.d/outbreak-svc.conf`, `system/etc/subuid`, `system/etc/subgid`, `system/usr/lib/sysctl.d/61-outbreak-unprivileged-ports.conf`
- Modify: `build/build.sh`, `build/99-tests.sh`, `docs/build-stages.md`

**Interfaces:**
- Consumes: Task 1 pipeline.
- Produces: system user `svc` with **UID/GID 880**, in groups `render` and `video`, home `/var/lib/svc`, lingering, subordinate IDs `1000000000:65536`. Service state root `/var/lib/outbreak` owned by `svc`. Rootless Quadlets for `svc` are read from `/etc/containers/systemd/users/880/`; how they get there is the services plan's decision. `ujust` entry point `/usr/share/outbreak/just/main.just`, which Tasks 6 and 7 extend with `import` lines.

- [ ] **Step 1: Add the failing tests**

In `build/99-tests.sh`, before the final `echo "::endgroup::"`:

```bash
# --- Service account and ujust (Task 5) ---
rpm -q just >/dev/null
test -x /usr/bin/ujust
grep -qx 'u svc 880:880 "Outbreak rootless services" /var/lib/svc /usr/sbin/nologin' /usr/lib/sysusers.d/outbreak-svc.conf
grep -qx 'm svc render' /usr/lib/sysusers.d/outbreak-svc.conf
grep -qx 'm svc video' /usr/lib/sysusers.d/outbreak-svc.conf
grep -qx 'svc:1000000000:65536' /etc/subuid
grep -qx 'svc:1000000000:65536' /etc/subgid
grep -q '^f /var/lib/systemd/linger/svc ' /usr/lib/tmpfiles.d/outbreak-svc.conf
grep -qx 'net.ipv4.ip_unprivileged_port_start = 80' /usr/lib/sysctl.d/61-outbreak-unprivileged-ports.conf
just --justfile /usr/share/outbreak/just/main.just --list >/dev/null
```

- [ ] **Step 2: Run the build to verify the tests fail**

Run: `git add -A && just build`
Expected: FAIL at `rpm -q just`.

- [ ] **Step 3: Add the service account files**

`system/usr/lib/sysusers.d/outbreak-svc.conf`:

```
# Rootless Podman services run as this user. See docs/build-stages.md.
u svc 880:880 "Outbreak rootless services" /var/lib/svc /usr/sbin/nologin
m svc render
m svc video
```

`system/usr/lib/tmpfiles.d/outbreak-svc.conf`:

```
d /var/lib/svc 0750 svc svc - -
d /var/lib/outbreak 0750 svc svc - -
f /var/lib/systemd/linger/svc 0644 root root - -
```

`system/etc/subuid` and `system/etc/subgid` (identical; the range sits far above what `useradd` hands to the owner's account at install, which starts at 524288):

```
svc:1000000000:65536
```

`system/usr/lib/sysctl.d/61-outbreak-unprivileged-ports.conf`:

```
# Lets rootless Caddy bind 80/443. See docs/networking.md.
net.ipv4.ip_unprivileged_port_start = 80
```

- [ ] **Step 4: Add ujust**

`system/usr/bin/ujust` (mode 0755):

```bash
#!/usr/bin/bash
exec /usr/bin/just --justfile /usr/share/outbreak/just/main.just --working-directory "${PWD}" "${@}"
```

`system/usr/share/outbreak/just/main.just` (Tasks 6 and 7 add `import` lines for their recipe files):

```just
set allow-duplicate-recipes := true
set ignore-comments := true

_default:
    @ujust --list --list-heading $'Available commands:\n' --list-prefix $' - '
```

- [ ] **Step 5: Write the stage**

`build/40-services.sh` (mode 0755):

```bash
#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# just runs ujust. The svc account, its linger file and subordinate IDs come
# from system/ (sysusers.d, tmpfiles.d, /etc/subuid, /etc/subgid).
dnf5 -y install --setopt=install_weak_deps=False just

echo "::endgroup::"
```

Add to `build/build.sh` after `30-gpu.sh`:

```bash
/ctx/build/40-services.sh
```

- [ ] **Step 6: Run the build to verify it passes**

Run: `git add -A && just build`
Expected: PASS.

- [ ] **Step 7: Check the account is created at boot (sysusers runs at boot, not during the build)**

Append inside the `test-image` recipe in `Justfile`:

```just
    echo "svc account resolves after sysusers:"
    ${PODMAN} run --rm "${img}" bash -c 'systemd-sysusers && id svc | grep -q "uid=880(svc)" && id -nG svc | grep -qw render && id -nG svc | grep -qw video'
```

Run: `just test-image`
Expected: exits 0.

- [ ] **Step 8: Document**

Add to `docs/build-stages.md`:

```markdown
| `40-services.sh` | Installs `just` for `ujust`. The rootless service account comes from `system/`: `svc` (UID/GID 880, groups `render` and `video`, lingering, subordinate IDs `1000000000:65536`), state under `/var/lib/outbreak/`, and `ip_unprivileged_port_start=80` so rootless Caddy can bind 80/443. Rootless Quadlets for `svc` go in `/etc/containers/systemd/users/880/`; deploying them is handled outside the image (see the services plan). |
```

- [ ] **Step 9: Lint and commit**

```bash
just lint && just check
git add -A
git commit -m "feat(services): add the rootless svc account and ujust

Assisted-by: Claude Opus 5.5 via Claude Code
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
just clean-images
```

---

### Task 6: Stage updates automatically, reboot manually

**Files:**
- Create: `build/50-updates.sh`, `system/usr/lib/systemd/system/outbreak-stage-update.service`, `system/usr/lib/systemd/system/outbreak-stage-update.timer`, `system/usr/libexec/outbreak/update-motd`, `system/usr/share/outbreak/just/updates.just`, `docs/updates.md`
- Modify: `build/build.sh`, `build/99-tests.sh`, `system/usr/share/outbreak/just/main.just`, `docs/build-stages.md`

**Interfaces:**
- Consumes: Task 5 (`main.just`).
- Produces: enabled `outbreak-stage-update.timer`; masked `bootc-fetch-apply-updates.timer`; `/run/motd.d/50-outbreak-update` present while an update is staged; `ujust update-status`.

- [ ] **Step 1: Add the failing tests**

In `build/99-tests.sh`, before the final `echo "::endgroup::"`:

```bash
# --- Update staging (Task 6) ---
systemctl is-enabled --quiet outbreak-stage-update.timer
[[ "$(systemctl is-enabled bootc-fetch-apply-updates.timer || true)" == "masked" ]]
test -x /usr/libexec/outbreak/update-motd
bash -n /usr/libexec/outbreak/update-motd
grep -qx 'ExecStart=/usr/bin/bootc upgrade --quiet' /usr/lib/systemd/system/outbreak-stage-update.service
just --justfile /usr/share/outbreak/just/main.just --list | grep -c 'update-status' >/dev/null
```

- [ ] **Step 2: Run the build to verify the tests fail**

Run: `git add -A && just build`
Expected: FAIL at `systemctl is-enabled --quiet outbreak-stage-update.timer`.

- [ ] **Step 3: Add the units and the notice script**

`system/usr/lib/systemd/system/outbreak-stage-update.service`:

```ini
[Unit]
Description=Download and stage the latest Outbreak image (applied at the next reboot)
Documentation=man:bootc-upgrade(8)
ConditionPathExists=/run/ostree-booted
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bootc upgrade --quiet
ExecStartPost=/usr/libexec/outbreak/update-motd
```

`system/usr/lib/systemd/system/outbreak-stage-update.timer`:

```ini
[Unit]
Description=Stage Outbreak image updates daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

`system/usr/libexec/outbreak/update-motd` (mode 0755):

```bash
#!/usr/bin/bash
# Writes a login notice while a staged update is waiting for a reboot.
set -euo pipefail

MOTD="/run/motd.d/50-outbreak-update"
status="$(bootc status --format=json)"
staged="$(jq -r '.status.staged.image.image.image // empty' <<<"${status}")"

if [[ -n "${staged}" ]]; then
    version="$(jq -r '.status.staged.image.version // "unknown version"' <<<"${status}")"
    install -d -m 0755 /run/motd.d
    printf 'Outbreak update staged: %s (%s), checked %s.\nReboot when convenient to apply it: sudo systemctl reboot\n' \
        "${version}" "${staged}" "$(date -u +%F)" >"${MOTD}"
else
    rm -f "${MOTD}"
fi
```

`system/usr/share/outbreak/just/updates.just`:

```just
# Show the booted, staged and rollback images
[group('Updates')]
update-status:
    sudo bootc status

# Check for and stage an update now (applied at the next reboot)
[group('Updates')]
update-now:
    sudo systemctl start outbreak-stage-update.service
    sudo bootc status
```

Append to `system/usr/share/outbreak/just/main.just`:

```just
import "/usr/share/outbreak/just/updates.just"
```

- [ ] **Step 4: Write the stage**

`build/50-updates.sh` (mode 0755):

```bash
#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# bootc's own timer runs `bootc upgrade --apply`, which reboots. Mask it so
# nothing (presets included) can turn it back on; ours only stages.
systemctl mask bootc-fetch-apply-updates.timer
systemctl enable outbreak-stage-update.timer

echo "::endgroup::"
```

Add to `build/build.sh` after `40-services.sh`:

```bash
/ctx/build/50-updates.sh
```

- [ ] **Step 5: Run the build to verify it passes**

Run: `git add -A && just build`
Expected: PASS.

- [ ] **Step 6: Document**

`docs/updates.md`:

```markdown
# Updates

- `outbreak-stage-update.timer` runs daily (up to an hour's random delay) and
  calls `bootc upgrade --quiet`: it downloads and stages the new image. The
  staged image is applied at the **next reboot, whenever that happens**.
- `bootc-fetch-apply-updates.timer` is masked: it would reboot automatically.
- While an update is staged, `/run/motd.d/50-outbreak-update` prints a notice
  at SSH login. `ujust update-status` shows the booted, staged and rollback
  images; `ujust update-now` stages immediately.
- To undo a bad update: `sudo bootc rollback`, then reboot.

Reboot when nothing long-running is active (hashcat can resume with
`--restore`; lab VMs and services restart on their own).
```

Add to `docs/build-stages.md`:

```markdown
| `50-updates.sh` | Masks bootc's auto-apply timer and enables `outbreak-stage-update.timer` (stage only; reboots are manual). See updates.md. |
```

- [ ] **Step 7: Lint and commit**

```bash
just lint && just check
git add -A
git commit -m "feat(updates): stage image updates daily and leave reboots manual

Assisted-by: Claude Opus 5.5 via Claude Code
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
just clean-images
```

---

### Task 7: Image signing

**Files:**
- Create: `cosign.pub`, `system/usr/lib/pki/containers/outbreak.pub`, `system/etc/containers/policy.json`, `system/etc/containers/registries.d/outbreak.yaml`, `system/usr/share/outbreak/just/system.just`, `docs/signing.md`
- Modify: `build/99-tests.sh`, `Justfile` (`check`, add `verify`), `system/usr/share/outbreak/just/main.just`

**Interfaces:**
- Consumes: Task 5 (`main.just`).
- Produces: GitHub Actions secret `SIGNING_SECRET` (the private key, consumed by Task 8); policy requiring `sigstoreSigned` for `ghcr.io/sir-mudkip/outbreak`; `ujust enforce-signatures`; `just verify`.

- [ ] **Step 1: Add the failing tests**

In `build/99-tests.sh`, before the final `echo "::endgroup::"`:

```bash
# --- Signing (Task 7) ---
grep -q 'BEGIN PUBLIC KEY' /usr/lib/pki/containers/outbreak.pub
jq -e '.transports.docker["ghcr.io/sir-mudkip/outbreak"][0].type == "sigstoreSigned"' /etc/containers/policy.json
jq -e '.transports.docker["ghcr.io/sir-mudkip/outbreak"][0].keyPath == "/usr/lib/pki/containers/outbreak.pub"' /etc/containers/policy.json
grep -q 'use-sigstore-attachments: true' /etc/containers/registries.d/outbreak.yaml
just --justfile /usr/share/outbreak/just/main.just --list | grep -c 'enforce-signatures' >/dev/null
```

- [ ] **Step 2: Run the build to verify the tests fail**

Run: `git add -A && just build`
Expected: FAIL at `grep -q 'BEGIN PUBLIC KEY' /usr/lib/pki/containers/outbreak.pub`.

- [ ] **Step 3: Generate the keypair and store the secret (owner action — confirm before running)**

This creates a signing key and writes a GitHub secret. Ask the owner before running.

```bash
COSIGN_PASSWORD="" cosign generate-key-pair
git check-ignore cosign.key          # must print "cosign.key"; stop if it doesn't
gh secret set SIGNING_SECRET -R Sir-Mudkip/Outbreak < cosign.key
install -D -m 0644 cosign.pub system/usr/lib/pki/containers/outbreak.pub
```

Expected: `cosign.key` and `cosign.pub` in the repo root; `gh secret list -R Sir-Mudkip/Outbreak` shows `SIGNING_SECRET`. Back up `cosign.key` somewhere safe outside the repo (a password manager); losing it means rotating the key on the server.

- [ ] **Step 4: Add the container policy and registry config**

`system/etc/containers/policy.json`:

```json
{
    "default": [
        {
            "type": "reject"
        }
    ],
    "transports": {
        "docker": {
            "ghcr.io/sir-mudkip/outbreak": [
                {
                    "type": "sigstoreSigned",
                    "keyPath": "/usr/lib/pki/containers/outbreak.pub",
                    "signedIdentity": {
                        "type": "matchRepository"
                    }
                }
            ],
            "": [
                {
                    "type": "insecureAcceptAnything"
                }
            ]
        },
        "docker-daemon": { "": [ { "type": "insecureAcceptAnything" } ] },
        "containers-storage": { "": [ { "type": "insecureAcceptAnything" } ] },
        "dir": { "": [ { "type": "insecureAcceptAnything" } ] },
        "oci": { "": [ { "type": "insecureAcceptAnything" } ] },
        "oci-archive": { "": [ { "type": "insecureAcceptAnything" } ] },
        "docker-archive": { "": [ { "type": "insecureAcceptAnything" } ] },
        "tarball": { "": [ { "type": "insecureAcceptAnything" } ] }
    }
}
```

`system/etc/containers/registries.d/outbreak.yaml`:

```yaml
docker:
  ghcr.io/sir-mudkip/outbreak:
    use-sigstore-attachments: true
```

`system/usr/share/outbreak/just/system.just`:

```just
# Make bootc verify the Outbreak signature on every upgrade (run once after install)
[group('System')]
enforce-signatures:
    sudo bootc switch --enforce-container-sigpolicy ghcr.io/sir-mudkip/outbreak:stable
    sudo bootc status
```

Add to `system/usr/share/outbreak/just/main.just`:

```just
import "/usr/share/outbreak/just/system.just"
```

- [ ] **Step 5: Add `just verify` and a key-consistency check**

Append to the `check` recipe in `Justfile` (inside its script, at the end):

```bash
    echo "Checking cosign.pub matches the key baked into the image"
    cmp cosign.pub system/usr/lib/pki/containers/outbreak.pub
```

Append a new recipe to `Justfile`:

```just
# Verify a published image's cosign signature
[group('Image')]
verify $tag=default_tag:
    #!/usr/bin/bash
    set -euo pipefail
    cosign verify --key cosign.pub "ghcr.io/${REPO_ORG,,}/${image_name}:${tag}"
```

- [ ] **Step 6: Run the build to verify it passes**

Run: `git add -A && just build && just check`
Expected: PASS.

- [ ] **Step 7: Document**

`docs/signing.md`:

```markdown
# Signing

CI signs every pushed tag with cosign (`SIGNING_SECRET` holds the private key).
The public key is committed as `cosign.pub` and baked into the image at
`/usr/lib/pki/containers/outbreak.pub`; `just check` fails if they differ.

`/etc/containers/policy.json` requires that signature for
`ghcr.io/sir-mudkip/outbreak` and accepts other registries unsigned (service
containers come from Docker Hub, GHCR and others). After installing, run
`ujust enforce-signatures` once so `bootc upgrade` verifies every update.

Check a published image by hand: `just verify` (or `just verify <tag>`).

## Rotating the key

1. Generate a new pair; update `SIGNING_SECRET`.
2. Commit the new `cosign.pub` and `system/usr/lib/pki/containers/outbreak.pub`.
3. The server must boot an image carrying the new key **before** images signed
   only with the new key can be verified. If it cannot (the old key is lost),
   run `sudo bootc switch ghcr.io/sir-mudkip/outbreak:stable` without
   enforcement once, reboot, then `ujust enforce-signatures` again.
```

- [ ] **Step 8: Lint and commit (never `cosign.key`)**

```bash
just lint && just check
git status --short | grep -q 'cosign.key' && { echo "cosign.key is staged; stop"; exit 1; }
git add -A
git commit -m "feat(signing): require cosign signatures for Outbreak images

Assisted-by: Claude Opus 5.5 via Claude Code
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
just clean-images
```

---

### Task 8: CI — build, rechunk, push and sign on `master`

**Files:**
- Create: `.github/workflows/build.yml`, `.github/workflows/validate.yml`, `.github/workflows/clean.yml`
- Modify: `Justfile` (add `tag-images`), `docs/signing.md`

**Interfaces:**
- Consumes: Task 7 `SIGNING_SECRET`; Justfile recipes `build`, `tag-images`.
- Produces: `ghcr.io/sir-mudkip/outbreak:stable` and `:YYYY-MM-DD`, signed. Task 9 builds the ISO from `:stable`.

- [ ] **Step 1: Add `tag-images` to the Justfile**

```just
# Apply alias tags to the built image
[group('Image')]
tag-images $image_name="" $default_tag="" $tags="":
    #!/usr/bin/bash
    set -eou pipefail
    if [[ -z "${image_name}" || -z "${default_tag}" || -z "${tags}" ]]; then
        echo "Usage: just tag-images <image_name> <default_tag> <tags>"
        exit 1
    fi
    IMAGE=$(${PODMAN} inspect "localhost/${image_name}:${default_tag}" | jq -r '.[].Id')
    ${PODMAN} untag "localhost/${image_name}:${default_tag}"
    for tag in ${tags}; do
        ${PODMAN} tag "${IMAGE}" "${image_name}:${tag}"
    done
    ${PODMAN} tag "${IMAGE}" "${image_name}:${default_tag}"
    echo "Tagged ${image_name} with: ${tags}"
```

- [ ] **Step 2: Write `.github/workflows/build.yml`**

Action pins are the ones Sivablue's workflow uses today.

```yaml
---
name: Build container image
on:
  schedule:
    - cron: '20 10 * * *'  # daily, to pick up Fedora updates
  push:
    branches:
      - master
    paths-ignore:
      - "**.md"
  workflow_dispatch:

# No pull_request trigger: images are only built from master.
permissions:
  contents: read

env:
  IMAGE_NAME: outbreak
  IMAGE_VENDOR: sir-mudkip
  IMAGE_REGISTRY: ghcr.io/sir-mudkip
  DEFAULT_TAG: stable

jobs:
  build_push:
    name: Build and push image
    runs-on: ubuntu-24.04
    timeout-minutes: 240
    concurrency:
      group: ${{ github.workflow }}-${{ github.ref }}
      cancel-in-progress: true
    permissions:
      contents: read
      packages: write
      id-token: write

    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Setup runner
        uses: projectbluefin/actions/bootc-build/setup-runner@cbd8446f58a079e48f76d81d5bc1c2fdec95d592 # v1
        with:
          storage-backend: btrfs
          update-podman: "true"
          install-tools: '["just"]'

      # Force podman onto native overlayfs; the runner image's config would
      # route every layer diff through fuse-overlayfs (see Sivablue docs/ci.md).
      - name: Use native overlayfs for podman storage
        shell: bash
        run: |
          set -euo pipefail
          sudo install -d -m 0755 /etc/containers
          sudo tee /etc/containers/storage.conf >/dev/null <<'EOF'
          [storage]
          driver = "overlay"
          runroot = "/run/containers/storage"
          graphroot = "/var/lib/containers/storage"

          [storage.options.overlay]
          mountopt = "nodev,redirect_dir=off"
          EOF
          sudo podman system reset -f >/dev/null 2>&1 \
            || sudo rm -rf /var/lib/containers/storage
          NATIVE=$(sudo podman info --format '{{index .Store.GraphStatus "Native Overlay Diff"}}')
          echo "Native Overlay Diff: ${NATIVE}"
          if [ "${NATIVE}" != "true" ]; then
            echo "::error::podman is not using native overlayfs"
            exit 1
          fi

      - name: Restore DNF cache
        uses: projectbluefin/actions/bootc-build/dnf-cache@cbd8446f58a079e48f76d81d5bc1c2fdec95d592 # v1
        with:
          action: restore
          cache-name: ${{ env.IMAGE_NAME }}
          cache-bust: ${{ hashFiles('**/Containerfile') }}

      - name: Build image
        uses: nick-fields/retry@ad984534de44a9489a53aefd81eb77f87c70dc60 # v4
        with:
          timeout_minutes: 120
          max_attempts: 3
          retry_wait_seconds: 300
          command: |
            sudo -E "$(command -v just)" build "${IMAGE_NAME}" "${DEFAULT_TAG}"

      - name: Post-build image checks
        run: sudo -E "$(command -v just)" test-image "${IMAGE_NAME}" "${DEFAULT_TAG}"

      - name: Generate tags
        id: generate-tags
        shell: bash
        run: |
          TAGS="${DEFAULT_TAG} $(date -u +%Y-%m-%d)"
          echo "tags=${TAGS}" >> "$GITHUB_OUTPUT"
          echo "default-tag=${DEFAULT_TAG}" >> "$GITHUB_OUTPUT"

      - name: Save DNF cache
        if: always() && !cancelled()
        uses: projectbluefin/actions/bootc-build/dnf-cache@cbd8446f58a079e48f76d81d5bc1c2fdec95d592 # v1
        with:
          action: save
          cache-name: ${{ env.IMAGE_NAME }}
          allow-write: 'true'
          cache-bust: ${{ hashFiles('**/Containerfile') }}

      - name: Rechunk image
        uses: projectbluefin/actions/bootc-build/chunka@6231015b336556d2ff0adc1d1e59514bf19dcb42 # v1
        with:
          source-image: localhost/${{ env.IMAGE_NAME }}:${{ env.DEFAULT_TAG }}
          max-layers: 128

      - name: Tag images
        env:
          ALIAS_TAGS: ${{ steps.generate-tags.outputs.tags }}
        run: |
          sudo -E "$(command -v just)" tag-images "${IMAGE_NAME}" "${DEFAULT_TAG}" "${ALIAS_TAGS}"

      - name: Login to GitHub Container Registry
        uses: docker/login-action@abd2ef45e78c5afb21d64d4ca52ee8550d9572c7 # v4.5.1
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Push to GHCR
        uses: projectbluefin/actions/bootc-build/push-image@cbd8446f58a079e48f76d81d5bc1c2fdec95d592 # v1
        with:
          image-name: ${{ env.IMAGE_NAME }}
          tags: ${{ steps.generate-tags.outputs.tags }}
          default-tag: ${{ steps.generate-tags.outputs.default-tag }}
          github-token: ${{ secrets.GITHUB_TOKEN }}

      - name: Install Cosign
        uses: sigstore/cosign-installer@7e8b541eb2e61bf99390e1afd4be13a184e9ebc5 # v3.10.1

      - name: Sign container image
        env:
          TAGS: ${{ steps.generate-tags.outputs.tags }}
          COSIGN_EXPERIMENTAL: false
          COSIGN_PRIVATE_KEY: ${{ secrets.SIGNING_SECRET }}
        run: |
          for tag in ${TAGS}; do
            cosign sign -y --key env://COSIGN_PRIVATE_KEY "${IMAGE_REGISTRY}/${IMAGE_NAME}:${tag}"
          done
```

- [ ] **Step 3: Write `.github/workflows/validate.yml`**

```yaml
name: Validate
on:
  push:
    branches:
      - master
  workflow_dispatch:

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Install just
        uses: extractions/setup-just@53165ef7e734c5c07cb06b3c8e7b647c5aa16db3 # v4

      - name: Just syntax and key consistency
        run: just check

      - name: Shellcheck
        run: just lint
```

- [ ] **Step 4: Write `.github/workflows/clean.yml`**

```yaml
name: Cleanup Old Images
on:
  schedule:
    - cron: "0 0 * * 0"
  workflow_dispatch:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref || github.run_id }}

jobs:
  delete-older-than-90:
    runs-on: ubuntu-latest
    permissions:
      packages: write
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Cleanup old images
        uses: projectbluefin/actions/bootc-build/ghcr-cleanup@cbd8446f58a079e48f76d81d5bc1c2fdec95d592 # v1
        with:
          packages: outbreak
          older-than: 90 days
          keep-n-tagged: 7
          keep-n-untagged: 7
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 5: Verify locally what CI will run**

Run: `just check && just lint && git add -A && just build && just tag-images outbreak stable "stable $(date -u +%Y-%m-%d)" && podman images localhost/outbreak`
Expected: both tags listed.

- [ ] **Step 6: Lock `master` to the owner (owner action — confirm before running)**

```bash
gh api -X PUT repos/Sir-Mudkip/Outbreak/branches/master/protection \
  -H "Accept: application/vnd.github+json" \
  -f 'required_status_checks=null' -F 'enforce_admins=false' \
  -f 'required_pull_request_reviews=null' \
  -F 'restrictions[users][]=Sir-Mudkip' -F 'restrictions[teams][]=' \
  -F 'allow_force_pushes=false' -F 'allow_deletions=false'
```

If the API rejects `restrictions` (user-owned repositories cannot restrict pushers, only organisation repos can), the repo is already owner-only unless collaborators are added; confirm with `gh api repos/Sir-Mudkip/Outbreak/collaborators --jq '.[].login'` (expected: only `Sir-Mudkip`) and set just `allow_force_pushes=false` and `allow_deletions=false`.

- [ ] **Step 7: Commit, push and watch the first run (owner confirms the push)**

```bash
git add -A
git commit -m "ci: build, rechunk, push and sign Outbreak on master

Assisted-by: Claude Opus 5.5 via Claude Code
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin master
gh run watch -R Sir-Mudkip/Outbreak "$(gh run list -R Sir-Mudkip/Outbreak --workflow build.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
just verify
just clean-images
```

Expected: the build run succeeds and `just verify` prints the verified signature payload for `ghcr.io/sir-mudkip/outbreak:stable`.

---

### Task 9: Installer ISO, test install and first-boot checklist

**Files:**
- Create: `iso/config.example.toml`, `docs/install.md`
- Modify: `Justfile` (add `build-iso`, `test-install`)

**Interfaces:**
- Consumes: `ghcr.io/sir-mudkip/outbreak:stable` from Task 8.
- Produces: `output/bootiso/install.iso`.

- [ ] **Step 1: Write the example config**

`iso/config.example.toml`:

```toml
# Copy to iso/config.toml (gitignored) and fill in your user and SSH key.
# Anaconda asks which disk to install to: pick the Samsung 990 Pro.

[[customizations.user]]
name = "your-username"
key = "ssh-ed25519 AAAA...your-public-key... you@your-machine"
groups = ["wheel", "libvirt", "render", "video"]
```

Then create the real one from your key (it stays local):

```bash
cp iso/config.example.toml iso/config.toml
sed -i "s|^name = .*|name = \"$(id -un)\"|; s|^key = .*|key = \"$(cat ~/.ssh/id_ed25519.pub)\"|" iso/config.toml
git check-ignore iso/config.toml   # must print iso/config.toml
```

- [ ] **Step 2: Add `build-iso` and `test-install` to the Justfile**

At the top with the other exports:

```just
export bib_image := env("BIB_IMAGE", "ghcr.io/osbuild/bootc-image-builder:latest@sha256:4cd0deb14fb7f14d54304a11b8b0769e47c6ba23733d2356b21ffafd34aba178")
```

Recipes:

```just
# Build an Anaconda installer ISO from the published image
[group('Install')]
build-iso $tag=default_tag:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ ! -f iso/config.toml ]]; then
        echo "Create iso/config.toml from iso/config.example.toml first"
        exit 1
    fi
    ref="ghcr.io/${REPO_ORG,,}/${image_name}:${tag}"
    sudo ${PODMAN} pull "${ref}"
    mkdir -p output
    sudo ${PODMAN} run --rm --privileged --pull=newer \
        --security-opt label=type:unconfined_t \
        -v ./iso/config.toml:/config.toml:ro \
        -v ./output:/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        "${bib_image}" \
        --type anaconda-iso \
        --rootfs xfs \
        --use-librepo=True \
        "${ref}"
    sudo chown -R "$(id -u):$(id -g)" output
    ls -lh output/bootiso/install.iso

# Install the ISO into a throwaway VM to test it (UEFI, 8 GB RAM, 80 GB disk)
[group('Install')]
test-install:
    sudo virt-install --name outbreak-test --memory 8192 --vcpus 4 \
        --disk size=80 --cdrom "$(pwd)/output/bootiso/install.iso" \
        --osinfo fedora-unknown --boot uefi --graphics vnc --noautoconsole
    @echo "Open the console with: virt-viewer outbreak-test (or Cockpit/virt-manager)"
```

- [ ] **Step 3: Build the ISO**

Run: `just check && just build-iso`
Expected: `output/bootiso/install.iso` of roughly 3–5 GB.

- [ ] **Step 4: Test-install it in a VM and check the result**

Run: `just test-install`, then open the console with `virt-viewer outbreak-test`. Complete the installer (the VM has one disk), let it reboot, and log in **on the console** as your user. SSH over the VM's network address is refused by design (the `outbreak` zone does not open SSH) and the test VM has no Tailscale, so the console is the way in; the refusal itself is one of the checks below.

On the VM console, every line must succeed:

```bash
bootc status                                          # booted image: ghcr.io/sir-mudkip/outbreak:stable
systemctl is-active sshd cockpit.socket tailscaled firewalld pmcd pmlogger outbreak-lab-firewall
systemctl is-active virtqemud.socket virtproxyd.socket outbreak-stage-update.timer
sudo firewall-cmd --get-default-zone                  # outbreak
sudo firewall-cmd --zone=trusted --list-interfaces    # tailscale0
sudo nft list table inet outbreak_labs >/dev/null
id svc                                                # uid=880(svc) ... render, video
id -nG                                                # includes wheel libvirt render video
ssh -o PasswordAuthentication=yes -o PubkeyAuthentication=no -o BatchMode=yes localhost true \
  && echo "FAIL: password SSH accepted" || echo "ok: password SSH refused"
ujust --list                                          # update-status, update-now, enforce-signatures
sudo systemctl start outbreak-stage-update.service && ujust update-status
```

From the host, confirm SSH is closed on the LAN side:

```bash
vm_ip="$(sudo virsh domifaddr outbreak-test | awk '/ipv4/ {print $4}' | cut -d/ -f1)"
timeout 5 bash -c "</dev/tcp/${vm_ip}/22" && echo "FAIL: SSH open on LAN" || echo "ok: SSH closed on LAN"
timeout 5 bash -c "</dev/tcp/${vm_ip}/9090" && echo "FAIL: Cockpit open on LAN" || echo "ok: Cockpit closed on LAN"
```

Tear the VM down:

```bash
sudo virsh destroy outbreak-test
sudo virsh undefine outbreak-test --nvram --remove-all-storage
```

- [ ] **Step 5: Write the install guide and first-boot checklist**

`docs/install.md`:

```markdown
# Installing Outbreak

## Build the ISO

1. `cp iso/config.example.toml iso/config.toml` and set your username and SSH
   public key (the file is gitignored).
2. `just build-iso` builds `output/bootiso/install.iso` from
   `ghcr.io/sir-mudkip/outbreak:stable` with bootc-image-builder
   (`ghcr.io/osbuild/bootc-image-builder`, the compatibility container of
   osbuild's image-builder; `anaconda-iso` is its legacy-but-supported type).
3. Optional: `just test-install` installs it into a throwaway VM.

## Install

Write the ISO to a USB stick, boot the server from it, and pick the
**Samsung 990 Pro** as the install disk. Anaconda asks rather than choosing
automatically, so the second SSD can never be wiped by accident.

Enable the Intel iGPU in the BIOS alongside the 7900 XTX (Jellyfin transcodes
on it).

## First boot

Log in on the console or over SSH from the LAN console session, then:

1. `sudo tailscale up` and approve the machine. From now on use SSH and
   Cockpit (`https://<tailscale-name>:9090`) over Tailscale only.
2. `ujust enforce-signatures`, then reboot when convenient.
3. GPU checks: `rocm-smi` lists the 7900 XTX; `rocminfo | grep gfx1100`;
   `hashcat -I` shows the card under the HIP backend; `hashcat -b -m 1000`
   runs a benchmark.
4. Check whether Cockpit's Overview page shows the staged-update notice
   (`ujust update-now` when an update exists). If not, rely on the SSH login
   notice and `ujust update-status`.
5. Create the Podman secrets for services and deploy the Quadlets from the
   private `outbreak-services` repo to `/etc/containers/systemd/users/880/`
   (services plan).
6. Mount the NAS share at `/mnt/nas/data` and do a test *arr import to
   confirm hardlinks work (services plan).
7. When the second SSD is fitted, create the libvirt storage pool on it
   (labs plan).
```

- [ ] **Step 6: Commit and clean up**

```bash
git add -A
git status --short | grep -qE 'cosign.key|iso/config.toml' && { echo "secret file staged; stop"; exit 1; }
git commit -m "feat(install): build an Anaconda ISO and document first boot

Assisted-by: Claude Opus 5.5 via Claude Code
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
just clean-images
sudo podman rmi -f ghcr.io/sir-mudkip/outbreak:stable 2>/dev/null || true
sudo podman images -q ghcr.io/osbuild/bootc-image-builder | xargs -r sudo podman rmi -f
```

Keep `output/bootiso/install.iso` for the real install; `output/` is gitignored.
