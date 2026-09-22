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
