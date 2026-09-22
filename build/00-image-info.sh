#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -euox pipefail

IMAGE_INFO="/usr/share/outbreak/image-info.json"
OS_RELEASE="/usr/lib/os-release"
IMAGE_REF="ostree-image-signed:docker://ghcr.io/${IMAGE_VENDOR}/${IMAGE_NAME}"

mkdir -p /usr/share/outbreak
cat >"${IMAGE_INFO}" <<EOF
{
  "image-name": "${IMAGE_NAME}",
  "image-vendor": "${IMAGE_VENDOR}",
  "image-ref": "${IMAGE_REF}",
  "fedora-version": "${FEDORA_VERSION}",
  "version": "${VERSION}"
}
EOF

# Upsert KEY="value" in os-release. ID stays "fedora" so tooling keeps working.
set_os_release_field() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "${OS_RELEASE}"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "${OS_RELEASE}"
    else
        echo "${key}=\"${value}\"" >>"${OS_RELEASE}"
    fi
}

set_os_release_field "PRETTY_NAME" "Outbreak (${VERSION})"
set_os_release_field "VARIANT" "Outbreak"
set_os_release_field "VARIANT_ID" "outbreak"
set_os_release_field "IMAGE_ID" "${IMAGE_NAME}"
set_os_release_field "IMAGE_VERSION" "${VERSION}"
set_os_release_field "HOME_URL" "https://github.com/Sir-Mudkip/Outbreak"
set_os_release_field "BUG_REPORT_URL" "https://github.com/Sir-Mudkip/Outbreak/issues"

echo "::endgroup::"
