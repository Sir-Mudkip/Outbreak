#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# Runs after 98-clean-stage.sh: never write under /var or $HOME here.

# --- Image identity (Task 1) ---
test -f /usr/share/outbreak/image-info.json
jq -e '."image-name" == "outbreak"' /usr/share/outbreak/image-info.json
grep -q '^VARIANT_ID="outbreak"$' /usr/lib/os-release
grep -q '^IMAGE_ID="outbreak"$' /usr/lib/os-release

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

# --- GPU compute (Task 4) ---
for package in hashcat rocm-hip rocm-runtime rocm-opencl rocm-smi rocminfo nfs-utils; do
    rpm -q "${package}" >/dev/null || { echo "Missing package: ${package}"; exit 1; }
done
ldconfig -p | grep -c 'libamdhip64.so.7 ' >/dev/null
ldconfig -p | grep -c 'libhiprtc.so.7 ' >/dev/null
# hashcat creates state under $HOME; keep it out of the image.
HOME=/tmp/hashcat-test hashcat --version | grep -cE '^v7\.' >/dev/null
rm -rf /tmp/hashcat-test

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
# render/video must be real /etc/group lines (not just resolvable via
# nss-altfiles from /usr/lib/group) or systemd-sysusers can't add svc as a
# member of them at boot.
grep -q '^render:' /etc/group
grep -q '^video:' /etc/group
# svc must not be baked into the image; some package's RPM scriptlet can
# create it prematurely mid-build, and 40-services.sh must strip that so the
# account is created cleanly by systemd-sysusers at first real boot.
if grep -q '^svc:' /etc/passwd; then
    echo "svc must not be created during the build"; exit 1
fi
if grep -q '^svc:' /etc/group; then
    echo "svc group must not be created during the build"; exit 1
fi

# --- Update staging (Task 6) ---
systemctl is-enabled --quiet outbreak-stage-update.timer
[[ "$(systemctl is-enabled bootc-fetch-apply-updates.timer || true)" == "masked" ]]
if [[ -e /usr/libexec/outbreak/update-motd ]]; then
    echo "update-motd must not be present: headless server, no login notice"; exit 1
fi
if grep -q 'ExecStartPost' /usr/lib/systemd/system/outbreak-stage-update.service; then
    echo "outbreak-stage-update.service must not have an ExecStartPost"; exit 1
fi
grep -qx 'ExecStart=/usr/bin/bootc upgrade --quiet' /usr/lib/systemd/system/outbreak-stage-update.service
just --justfile /usr/share/outbreak/just/main.just --list | grep -c 'update-status' >/dev/null

# --- Signing (Task 7) ---
grep -q 'BEGIN PUBLIC KEY' /usr/lib/pki/containers/outbreak.pub
jq -e '.transports.docker["ghcr.io/sir-mudkip/outbreak"][0].type == "sigstoreSigned"' /etc/containers/policy.json
jq -e '.transports.docker["ghcr.io/sir-mudkip/outbreak"][0].keyPath == "/usr/lib/pki/containers/outbreak.pub"' /etc/containers/policy.json
grep -q 'use-sigstore-attachments: true' /etc/containers/registries.d/outbreak.yaml
just --justfile /usr/share/outbreak/just/main.just --list | grep -c 'enforce-signatures' >/dev/null

echo "::endgroup::"
