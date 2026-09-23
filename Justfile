export image_name := env("IMAGE_NAME", "outbreak")
export default_tag := env("DEFAULT_TAG", "stable")
export PODMAN := env("PODMAN", "podman")
export REPO_ORG := env("GITHUB_REPOSITORY_OWNER", "sir-mudkip")

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
    # --root=/ makes systemd-sysusers check the real /etc/group instead of
    # nss-systemd's synthesized (not-yet-persisted) entries for the standard
    # render/video groups, which without a running PID 1 otherwise makes it
    # skip writing svc's membership. systemd-sysusers.service takes no args
    # and runs after PID 1 is up, so real boot is unaffected either way.
    ${PODMAN} run --rm "${img}" bash -c 'systemd-sysusers --root=/ && id svc | grep -q "uid=880(svc)" && id -nG svc | grep -qw render && id -nG svc | grep -qw video'
