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
