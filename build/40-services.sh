#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# just runs ujust. The svc account, its linger file and subordinate IDs come
# from system/ (sysusers.d, tmpfiles.d, /etc/subuid, /etc/subgid).
dnf5 -y install --setopt=install_weak_deps=False just

# Some packages' RPM scriptlets (e.g. pcp) eagerly invoke systemd-sysusers
# for every pending sysusers.d file as a side effect of their own install.
# This creates svc mid-build, before render/video are promoted to /etc/group
# below, leaving its group membership incomplete. Strip it so the account is
# created cleanly, with full group membership, by systemd-sysusers at first
# real boot instead (see docs/build-stages.md). userdel/groupdel also strip
# matching /etc/subuid and /etc/subgid entries, which this image ships on
# purpose, so edit the account databases directly.
sed -i '/^svc:/d' /etc/passwd /etc/shadow /etc/group /etc/gshadow
# Also drop svc from the render/video member lists, in case a premature run
# above did add it there before the groups were real /etc/group entries.
sed -i -E '
/^(render|video):/ {
    s/:svc,/:/
    s/:svc$/:/
    s/,svc,/,/
    s/,svc$//
}
' /etc/group /etc/gshadow

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
