#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# just runs ujust. The svc account, its linger file and subordinate IDs come
# from system/ (sysusers.d, tmpfiles.d, /etc/subuid, /etc/subgid). build.sh
# installs the sysusers.d file after all package stages, so svc is created at
# first boot rather than baked into the image.
dnf5 -y install --setopt=install_weak_deps=False just

# render and video are ostree/bootc vendor-default groups: they only exist in
# /usr/lib/group (resolved via nss-altfiles; see nsswitch.conf), not
# /etc/group. systemd-sysusers treats an altfiles-resolved group as already
# existing and cannot add a member to a group with no /etc/group line, so the
# "m svc render"/"m svc video" lines in outbreak-svc.conf would silently fail
# to persist membership at boot. Promote them to /etc/group (the standard
# ostree workaround) so sysusers can actually record svc as a member.
for grp in render video; do
    if ! grep -q "^${grp}:" /etc/group; then
        grep "^${grp}:" /usr/lib/group >>/etc/group
        echo "${grp}:!::" >>/etc/gshadow
    fi
done

echo "::endgroup::"
