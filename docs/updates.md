# Updates

- `outbreak-stage-update.timer` runs daily (up to an hour's random delay) and
  calls `bootc upgrade --quiet`: it downloads and stages the new image. The
  staged image is applied at the **next reboot, whenever that happens**.
- `bootc-fetch-apply-updates.timer` is masked: it would reboot automatically.
- A staged update is visible with `ujust update-status`, which shows the
  booted, staged and rollback images; `ujust update-now` stages immediately.
- To undo a bad update: `sudo bootc rollback`, then reboot.

Reboot when nothing long-running is active (hashcat can resume with
`--restore`; lab VMs and services restart on their own).
