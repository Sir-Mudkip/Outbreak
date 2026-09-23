# Signing

CI signs every pushed tag with cosign (`SIGNING_SECRET` holds the private key).
The public key is committed as `cosign.pub` and baked into the image at
`/usr/lib/pki/containers/outbreak.pub`; `just check` fails if they differ.

`/etc/containers/policy.json` requires that signature for
`ghcr.io/sir-mudkip/outbreak` and accepts other registries unsigned (service
containers come from Docker Hub, GHCR and others). After installing, run
`ujust enforce-signatures` once so `bootc upgrade` verifies every update.

Check a published image by hand: `just verify` (or `just verify <tag>`).

## Rotating the key

1. Generate a new pair; update `SIGNING_SECRET`.
2. Commit the new `cosign.pub` and `system/usr/lib/pki/containers/outbreak.pub`.
3. The server must boot an image carrying the new key **before** images signed
   only with the new key can be verified. If it cannot (the old key is lost),
   run `sudo bootc switch ghcr.io/sir-mudkip/outbreak:stable` without
   enforcement once, reboot, then `ujust enforce-signatures` again.
