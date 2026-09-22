#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# hashcat's HIP backend loads libamdhip64 and libhiprtc from rocm-hip at run
# time. The amdgpu kernel driver comes with the Fedora kernel. See the spec's
# GPU section for why ROCm is on the host rather than in a container.
# nfs-utils is included here for mounting shared wordlist/hash storage for
# hashcat runs (see the labs plan for the NFS export itself).
GPU_PACKAGES=(
    hashcat
    rocm-hip
    rocm-opencl
    rocm-runtime
    rocm-smi
    rocminfo
    nfs-utils
)

dnf5 -y install --setopt=install_weak_deps=False "${GPU_PACKAGES[@]}"

echo "::endgroup::"
