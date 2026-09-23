# Installing Outbreak

## Build the ISO

1. Create the local config (gitignored; it never leaves your machine):

   ```bash
   cp iso/config.example.toml iso/config.toml
   openssl passwd -6          # paste the hash into password = "..."
   ```

   Then set `name` to your username and put every SSH public key you will log
   in with in `key`, one per line (e.g. desktop and laptop). The password is
   needed for console login and `sudo`; SSH itself stays key-only.
2. `just build-iso` builds `output/bootiso/install.iso` from
   `ghcr.io/sir-mudkip/outbreak:stable` with bootc-image-builder
   (`ghcr.io/osbuild/bootc-image-builder`, the compatibility container of
   osbuild's image-builder; `anaconda-iso` is its legacy-but-supported type).
3. Optional: `just test-install` installs it into a throwaway VM. It needs
   `virt-install`; without it, the recipe prints the settings to use in
   virt-manager.

## Install

Write the ISO to a USB stick, boot the server from it, and pick the
**Samsung 990 Pro** as the install disk. Anaconda asks rather than choosing
automatically, so the second SSD can never be wiped by accident.

Enable the Intel iGPU in the BIOS alongside the 7900 XTX (Jellyfin transcodes
on it).

## First boot

SSH is closed on the LAN by design, so log in on the console, then:

1. `sudo tailscale up` and approve the machine. From now on use SSH and
   Cockpit (`https://<tailscale-name>:9090`) over Tailscale only.
2. `ujust enforce-signatures`, then reboot when convenient.
3. GPU checks: `rocm-smi` lists the 7900 XTX; `rocminfo | grep gfx1100`;
   `hashcat -I` shows the card under the HIP backend; `hashcat -b -m 1000`
   runs a benchmark.
4. Create the Podman secrets for services and deploy the Quadlets from the
   private `outbreak-services` repo to `/etc/containers/systemd/users/880/`
   (services plan).
5. Mount the NAS share at `/mnt/nas/data` and do a test *arr import to
   confirm hardlinks work (services plan).
6. Rootless torrent check: download a public-domain torrent (e.g. Nosferatu)
   through Gluetun + qBittorrent. Confirm `podman info` as `svc` shows the
   pasta network backend, Gluetun uses kernel WireGuard, the forwarded port
   is connectable, and tunnel speed is close to the host's. If it is slow,
   move only that pair to a rootful Quadlet (services plan).
7. When the second SSD is fitted, create the libvirt storage pool on it
   (labs plan).
