# Networking and firewall

## Zones

| Interface | Zone | Open |
|---|---|---|
| LAN NIC (default) | `outbreak` | HTTP/HTTPS (Caddy), DHCPv6 client, UDP 41641 (Tailscale direct peer connections) |
| `tailscale0` | `trusted` | Everything: SSH, Cockpit (9090), services |

SSH and Cockpit are deliberately **not** open on the LAN. If Tailscale is down,
admin access is via the physical console.

## SSH

`/etc/ssh/sshd_config.d/40-outbreak.conf` disables passwords, keyboard-interactive
auth and root login. It sorts before Fedora's `50-redhat.conf`, and sshd keeps
the first value it reads for each option.

## Cockpit

`cockpit.socket` listens on 9090, reachable only through `tailscale0`. Metrics
history comes from PCP (`pcp-zeroconf` sets up `pmcd`/`pmlogger`); Cockpit reads
it through `python3-pcp` (there is no separate `cockpit-pcp` package any more).

## Tailscale

From Fedora's own repository, so the image carries no third-party repos.
Authenticate once after install with `sudo tailscale up`.
