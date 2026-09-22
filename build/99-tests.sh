#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# Runs after 98-clean-stage.sh: never write under /var or $HOME here.

# --- Image identity (Task 1) ---
test -f /usr/share/outbreak/image-info.json
jq -e '."image-name" == "outbreak"' /usr/share/outbreak/image-info.json
grep -q '^VARIANT_ID="outbreak"$' /usr/lib/os-release
grep -q '^IMAGE_ID="outbreak"$' /usr/lib/os-release

echo "::endgroup::"
