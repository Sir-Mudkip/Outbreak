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

echo "::endgroup::"
