#!/usr/bin/bash

set -eoux pipefail

echo "::group:: Copy system files"
# git does not track empty directories, so either half may be absent early on.
if [[ -d /ctx/system/usr ]]; then
    cp -rT /ctx/system/usr/ /usr/
    # sysusers.d files are held back until every package is installed: RPM
    # scriptlets (e.g. pcp's) run systemd-sysusers over all pending files, which
    # would create our accounts mid-build and bake them into the image.
    for conf in /ctx/system/usr/lib/sysusers.d/*.conf; do
        rm -f "/usr/lib/sysusers.d/$(basename "${conf}")"
    done
fi
if [[ -d /ctx/system/etc ]]; then
    cp -rT /ctx/system/etc/ /etc/
fi
echo "::endgroup::"

# Stages are called by name, in order. A new stage must be added here.
/ctx/build/00-image-info.sh
/ctx/build/10-admin.sh
/ctx/build/20-virt.sh
/ctx/build/30-gpu.sh
/ctx/build/40-services.sh
/ctx/build/50-updates.sh

echo "::group:: Install sysusers.d files"
# After the last package install, so accounts are created at first boot only.
if [[ -d /ctx/system/usr/lib/sysusers.d ]]; then
    cp -rT /ctx/system/usr/lib/sysusers.d/ /usr/lib/sysusers.d/
fi
echo "::endgroup::"

/ctx/build/98-clean-stage.sh
/ctx/build/99-tests.sh
