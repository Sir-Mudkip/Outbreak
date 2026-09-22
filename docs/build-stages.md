# Build stages

`build/build.sh` copies `system/usr` and `system/etc` into the image, then runs
each stage by name. Numbers set the order.

| Stage | Purpose |
|---|---|
| `00-image-info.sh` | Writes `/usr/share/outbreak/image-info.json` and sets `VARIANT_ID`, `IMAGE_ID`, `IMAGE_VERSION` and `PRETTY_NAME` in os-release. `ID` stays `fedora` so Fedora tooling keeps recognising the system. |
| `10-admin.sh` | Cockpit (+ Podman, storage, files, network, SELinux pages), PCP, Tailscale, firewalld, tmux, htop. Sets the `outbreak` zone as default and puts `tailscale0` in `trusted`. See networking.md. |
| `20-virt.sh` | libvirt/KVM (modular daemons, including `virtproxyd` for vagrant-libvirt), `swtpm` for Windows guests, `vagrant` + `vagrant-libvirt` for GOAD, cockpit-machines. Enables the lab containment firewall and the SELinux relabel workarounds for libvirt and swtpm. |
| `30-gpu.sh` | hashcat and the ROCm runtime (`rocm-hip`, `rocm-runtime`, `rocm-opencl`, `rocm-smi`, `rocminfo`) on the host, so hashcat's HIP backend talks to the 7900 XTX directly. Ollama brings its own ROCm libraries in its container. The build can only check that these install and start; GPU checks run on the hardware after first boot (install.md). |
| `98-clean-stage.sh` | Removes dnf caches and build residue from `/var`, `/tmp`, `/run` and `/boot` so `bootc container lint` passes. |
| `99-tests.sh` | The build's own test gate. Runs last; a failing check fails the build. |

`99-tests.sh` runs after the clean stage, so anything it writes would ship in
the image. Tools that create state run with `HOME=/tmp/…`.
