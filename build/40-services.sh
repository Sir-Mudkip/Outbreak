#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# just runs ujust. The svc account, its linger file and subordinate IDs come
# from system/ (sysusers.d, tmpfiles.d, /etc/subuid, /etc/subgid).
dnf5 -y install --setopt=install_weak_deps=False just

# Some packages' RPM scriptlets (e.g. pcp) eagerly invoke systemd-sysusers
# for every pending sysusers.d file as a side effect of their own install,
# which can create svc before the render/video groups exist and leave its
# group membership inconsistent. Undo any such premature creation so the
# account is created cleanly by systemd-sysusers at first real boot instead
# (see the note in outbreak-svc.conf and the test-image recipe). userdel/
# groupdel also strip matching /etc/subuid and /etc/subgid entries, which
# this image ships on purpose, so edit the account databases directly.
sed -i '/^svc:/d' /etc/passwd /etc/shadow /etc/group /etc/gshadow
# Also drop svc from the render/video member lists the "m" lines above add it
# to, in whichever position it landed in the comma-separated member list.
sed -i -E '
/^(render|video):/ {
    s/:svc,/:/
    s/:svc$/:/
    s/,svc,/,/
    s/,svc$//
}
' /etc/group /etc/gshadow

echo "::endgroup::"
