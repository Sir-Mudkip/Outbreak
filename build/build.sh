#!/usr/bin/bash

set -eoux pipefail

echo "::group:: Copy system files"
# git does not track empty directories, so either half may be absent early on.
if [[ -d /ctx/system/usr ]]; then
    cp -rT /ctx/system/usr/ /usr/
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
/ctx/build/98-clean-stage.sh
/ctx/build/99-tests.sh
