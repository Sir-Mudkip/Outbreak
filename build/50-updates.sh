#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# bootc's own timer runs `bootc upgrade --apply`, which reboots. Mask it so
# nothing (presets included) can turn it back on; ours only stages.
systemctl mask bootc-fetch-apply-updates.timer
systemctl enable outbreak-stage-update.timer

echo "::endgroup::"
