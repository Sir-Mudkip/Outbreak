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

## Lab containment

`outbreak-lab-firewall.service` loads `/usr/share/outbreak/lab-firewall.nft`
(table `inet outbreak_labs`) before libvirt's network daemon starts. For every
`virbr*` bridge:

| From a lab VM to… | Result |
|---|---|
| The internet | Allowed (libvirt NAT); needed for GOAD provisioning |
| Another lab bridge | Not blocked by this table (libvirt's own NAT rules still reject new traffic between NAT networks) |
| LAN, tailnet, link-local (RFC 1918, 100.64/10, fc00::/7…) | Dropped |
| This host | Only DHCP and DNS (libvirt's dnsmasq) and ICMP; everything else dropped |
| Replies to connections started from outside (your laptop over Tailscale) | Allowed |
| New connections into a lab from anywhere except the tailnet or another lab bridge | Dropped |

Lab traffic leaving a lab is IPv4-only: any IPv6 forwarded out of a `virbr*`
bridge is dropped, so a lab VM cannot reach the LAN or tailnet over IPv6.

The table uses its own base chains at priority `filter - 10`. In nftables a
`drop` in any table is final, so libvirt's and firewalld's `accept` rules
cannot re-open these paths.

**Lab networks must use `virbr*` bridge names**, or they are not contained.
libvirt's defaults and vagrant-libvirt's generated networks both do.

**Reaching labs over Tailscale:** libvirt NAT networks reject new inbound
connections from outside the host. The labs plan sets up route-mode networks
and advertises their subnets with `tailscale up --advertise-routes=…`, limited
by tailnet ACLs to the owner's devices. IP forwarding is enabled in
`/usr/lib/sysctl.d/60-outbreak-forwarding.conf`.
