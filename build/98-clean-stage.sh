#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

dnf5 clean all

rm -rf /.gitkeep
# /var/cache and /var/log are build cache mounts and /tmp is a tmpfs; removing
# the mount points themselves fails harmlessly (find ignores -exec failures,
# and a failing `rm` on the left of && does not trip set -e).
find /var/* -maxdepth 0 -type d \! -name cache -exec rm -fr {} \;
find /var/cache/* -maxdepth 0 -type d \! -name libdnf5 -exec rm -fr {} \;
rm -rf /tmp && mkdir -p /tmp
# /run is a tmpfs at runtime; podman bind-mounts some files there during RUN.
find /run -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
# /boot is populated by the bootc install.
# shellcheck disable=SC2114
rm -rf /boot && mkdir -p /boot

echo "::endgroup::"
