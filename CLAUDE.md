# Outbreak

A headless bootc server image built on `quay.io/fedora/fedora-bootc:44`.
Design: `docs/superpowers/specs/2026-09-22-outbreak-server-design.md`.
Rules live here; the reasoning behind them lives in `docs/` (index: `docs/README.md`).

## Rules

- Static files go in `system/` (mirrored into `/usr` and `/etc`). Anything that runs goes in a `build/NN-name.sh` stage.
- `build/build.sh` calls stages **by name**. A new stage must be added there or it never runs.
- Stage boilerplate: `#!/usr/bin/bash`, `set -eoux pipefail`, `::group::`/`::endgroup::` markers, mode 0755.
- `dnf5 -y install --setopt=install_weak_deps=False …` only. Never `dnf`, `yum` or `rpm-ostree`.
- Add a check to `build/99-tests.sh` for everything you add. It runs after the clean stage: never write under `/var` or `$HOME` there.
- This repo is public. No service definitions, secrets, TLS material or personal data. Services live in the private `outbreak-services` repo.
- Never commit `cosign.key` or `iso/config.toml`.
- Conventional commits (`<type>(<scope>): <description>`), with `Assisted-by: <Model> via <Tool>` in the footer for AI-assisted commits.
- Run `just clean-images` at the end of every session that built images.

## Validation

    just check   # just syntax
    just lint    # shellcheck (tracked files only: git add first)
    just build   # full image build, including 99-tests.sh and bootc container lint
