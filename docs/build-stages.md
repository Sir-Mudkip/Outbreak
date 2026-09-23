# Build stages

`build/build.sh` copies `system/usr` and `system/etc` into the image, then runs
each stage by name. Numbers set the order.

| Stage | Purpose |
|---|---|
| `00-image-info.sh` | Writes `/usr/share/outbreak/image-info.json` and sets `VARIANT_ID`, `IMAGE_ID`, `IMAGE_VERSION` and `PRETTY_NAME` in os-release. `ID` stays `fedora` so Fedora tooling keeps recognising the system. |
| `10-admin.sh` | Cockpit (+ Podman, storage, files, network, SELinux pages), PCP, Tailscale, firewalld, tmux, htop. Sets the `outbreak` zone as default and puts `tailscale0` in `trusted`. See networking.md. |
| `20-virt.sh` | libvirt/KVM (modular daemons, including `virtproxyd` for vagrant-libvirt), `swtpm` for Windows guests, `vagrant` + `vagrant-libvirt` for GOAD, cockpit-machines. Enables the lab containment firewall and the SELinux relabel workarounds for libvirt and swtpm. |
| `30-gpu.sh` | hashcat and the ROCm runtime (`rocm-hip`, `rocm-runtime`, `rocm-opencl`, `rocm-smi`, `rocminfo`) on the host, so hashcat's HIP backend talks to the 7900 XTX directly. Ollama brings its own ROCm libraries in its container. The build can only check that these install and start; GPU checks run on the hardware after first boot (install.md). |
| `40-services.sh` | Installs `just` for `ujust`. The rootless service account comes from `system/`: `svc` (UID/GID 880, groups `render` and `video`, lingering, subordinate IDs `1000000000:65536`), state under `/var/lib/outbreak/`, and `ip_unprivileged_port_start=80` so rootless Caddy can bind 80/443. This stage also strips any `svc` account a package's RPM scriptlet created prematurely mid-build (so it's created cleanly by `systemd-sysusers` at first real boot instead), and promotes the `render`/`video` groups from `/usr/lib/group` into `/etc/group` — they're vendor-default groups only resolvable via nss-altfiles otherwise, and `systemd-sysusers` can't add `svc` as a member of a group with no real `/etc/group` line. Rootless Quadlets for `svc` go in `/etc/containers/systemd/users/880/`; deploying them is handled outside the image (see the services plan). |
| `50-updates.sh` | Masks bootc's auto-apply timer and enables `outbreak-stage-update.timer` (stage only; reboots are manual). See updates.md. |
| `98-clean-stage.sh` | Removes dnf caches and build residue from `/var`, `/tmp`, `/run` and `/boot` so `bootc container lint` passes. |
| `99-tests.sh` | The build's own test gate. Runs last; a failing check fails the build. |

`99-tests.sh` runs after the clean stage, so anything it writes would ship in
the image. Tools that create state run with `HOME=/tmp/…`.
