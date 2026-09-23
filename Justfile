export image_name := env("IMAGE_NAME", "outbreak")
export default_tag := env("DEFAULT_TAG", "stable")
export PODMAN := env("PODMAN", "podman")
export REPO_ORG := env("GITHUB_REPOSITORY_OWNER", "sir-mudkip")
export bib_image := env("BIB_IMAGE", "ghcr.io/osbuild/bootc-image-builder:latest@sha256:4cd0deb14fb7f14d54304a11b8b0769e47c6ba23733d2356b21ffafd34aba178")

[private]
default:
    @just --list

# Check Justfile and ujust syntax
[group('Just')]
check:
    #!/usr/bin/bash
    set -euo pipefail
    find . -type f -name "*.just" | while read -r file; do
        echo "Checking syntax: $file"
        just --unstable --fmt --check -f "$file"
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile
    echo "Checking cosign.pub matches the key baked into the image"
    cmp cosign.pub system/usr/lib/pki/containers/outbreak.pub

# Fix Justfile and ujust formatting
[group('Just')]
fix:
    #!/usr/bin/bash
    set -euo pipefail
    find . -type f -name "*.just" | while read -r file; do
        just --unstable --fmt -f "$file"
    done
    just --unstable --fmt -f Justfile

# Shellcheck every tracked shell script (by .sh suffix or shebang)
[group('Lint')]
lint:
    #!/usr/bin/env bash
    set -eou pipefail
    command -v shellcheck >/dev/null || { echo "shellcheck is not installed"; exit 1; }
    mapfile -t scripts < <(
        git ls-files | while read -r f; do
            [ -f "$f" ] || continue
            case "$f" in
                *.sh) echo "$f" ;;
                *) head -n1 "$f" 2>/dev/null | grep -qE '^#!.*\b(sh|bash|dash|ksh)$' && echo "$f" ;;
            esac
        done
    )
    if [ "${#scripts[@]}" -eq 0 ]; then
        echo "No shell scripts found to lint."
        exit 1
    fi
    echo "Linting ${#scripts[@]} shell scripts..."
    shellcheck "${scripts[@]}"

# Build the image
[group('Image')]
build $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail
    fedora_version=$(grep -E '^ARG FEDORA_VERSION=' Containerfile | head -n1 | grep -oE '[0-9]+')
    ver="${fedora_version}.$(date -u +%Y%m%d)"
    BUILD_ARGS=(
        --build-arg "VERSION=${ver}"
        --build-arg "IMAGE_NAME=${target_image}"
        --build-arg "IMAGE_VENDOR=${REPO_ORG,,}"
    )
    LABELS=(
        --label "containers.bootc=1"
        --label "org.opencontainers.image.title=${target_image}"
        --label "org.opencontainers.image.version=${ver}"
        --label "org.opencontainers.image.description=Outbreak headless server"
        --label "org.opencontainers.image.source=https://github.com/Sir-Mudkip/Outbreak"
        --label "org.opencontainers.image.licenses=Apache-2.0"
        --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    )
    ${PODMAN} build "${BUILD_ARGS[@]}" "${LABELS[@]}" --pull=newer --tag "${target_image}:${tag}" .

# Apply alias tags to the built image
[group('Image')]
tag-images $image_name="" $default_tag="" $tags="":
    #!/usr/bin/bash
    set -eou pipefail
    if [[ -z "${image_name}" || -z "${default_tag}" || -z "${tags}" ]]; then
        echo "Usage: just tag-images <image_name> <default_tag> <tags>"
        exit 1
    fi
    IMAGE=$(${PODMAN} inspect "localhost/${image_name}:${default_tag}" | jq -r '.[].Id')
    ${PODMAN} untag "localhost/${image_name}:${default_tag}"
    for tag in ${tags}; do
        ${PODMAN} tag "${IMAGE}" "${image_name}:${tag}"
    done
    ${PODMAN} tag "${IMAGE}" "${image_name}:${default_tag}"
    echo "Tagged ${image_name} with: ${tags}"

# Remove images this repo builds (run at the end of every session)
[group('Image')]
clean-images:
    #!/usr/bin/bash
    set -uo pipefail
    fedora_version=$(grep -E '^ARG FEDORA_VERSION=' Containerfile | head -n1 | grep -oE '[0-9]+')
    ${PODMAN} rmi -f "localhost/${image_name}:${default_tag}" 2>/dev/null || true
    ${PODMAN} image prune -f --filter "label=org.opencontainers.image.title=${image_name}" || true
    ${PODMAN} rmi -f "quay.io/fedora/fedora-bootc:${fedora_version}" 2>/dev/null || true
    echo "Remaining images:"
    ${PODMAN} images

# Post-build checks that need capabilities the build sandbox lacks
[group('Image')]
test-image $target_image=image_name $tag=default_tag:
    #!/usr/bin/bash
    set -euo pipefail
    img="localhost/${target_image}:${tag}"
    echo "sshd config parses:"
    ${PODMAN} run --rm "${img}" bash -c 'ssh-keygen -A >/dev/null && /usr/sbin/sshd -t'
    echo "lab firewall ruleset parses:"
    ${PODMAN} run --rm --cap-add NET_ADMIN "${img}" nft -c -f /usr/share/outbreak/lab-firewall.nft
    echo "svc account resolves after sysusers:"
    ${PODMAN} run --rm "${img}" bash -c 'systemd-sysusers && id svc | grep -q "uid=880(svc)" && id -nG svc | grep -qw render && id -nG svc | grep -qw video'

# Verify a published image's cosign signature
[group('Image')]
verify $tag=default_tag:
    #!/usr/bin/bash
    set -euo pipefail
    cosign verify --key cosign.pub "ghcr.io/${REPO_ORG,,}/${image_name}:${tag}"

# Build an Anaconda installer ISO from the published image
[group('Install')]
build-iso $tag=default_tag:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ ! -f iso/config.toml ]]; then
        echo "Create iso/config.toml from iso/config.example.toml first (see docs/install.md)"
        exit 1
    fi
    if grep -qE 'your-username|your-password-hash|public-key\.\.\.' iso/config.toml; then
        echo "iso/config.toml still has placeholder values"
        exit 1
    fi
    ref="ghcr.io/${REPO_ORG,,}/${image_name}:${tag}"
    sudo ${PODMAN} pull "${ref}"
    mkdir -p output
    sudo ${PODMAN} run --rm --privileged --pull=newer \
        --security-opt label=type:unconfined_t \
        -v ./iso/config.toml:/config.toml:ro \
        -v ./output:/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        "${bib_image}" \
        --type anaconda-iso \
        --rootfs xfs \
        --use-librepo=True \
        "${ref}"
    sudo chown -R "$(id -u):$(id -g)" output
    ls -lh output/bootiso/install.iso

# Install the ISO into a throwaway VM to test it (UEFI, 8 GB RAM, 80 GB disk)
[group('Install')]
test-install:
    #!/usr/bin/bash
    set -euo pipefail
    if ! command -v virt-install >/dev/null; then
        echo "virt-install not found. Create the VM in virt-manager instead:"
        echo "  name outbreak-test, UEFI firmware, 8 GB RAM, 4 vCPUs, 80 GB disk,"
        echo "  CD-ROM $(pwd)/output/bootiso/install.iso"
        exit 1
    fi
    sudo virt-install --name outbreak-test --memory 8192 --vcpus 4 \
        --disk size=80 --cdrom "$(pwd)/output/bootiso/install.iso" \
        --osinfo fedora-unknown --boot uefi --graphics vnc --noautoconsole
    echo "Open the console with: virt-viewer --connect qemu:///system outbreak-test"
