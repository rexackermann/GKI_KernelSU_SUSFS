# Hotspot DNS Redirect

A KernelSU/Magisk module that forces all hotspot/tethering clients to use your phone's DNS resolver, making them obey your system `/etc/hosts` file.

**OverlayFS compatible** — no system files are modified. Uses only runtime iptables rules in custom chains.

## What it blocks

| Protocol | Port | Action | Effect |
|----------|------|--------|--------|
| Standard DNS | 53 (UDP/TCP) | **Redirect** to local resolver | All DNS goes through your hosts file |
| DNS-over-TLS | 853 (UDP/TCP) | **Reject** | Clients can't bypass via encrypted DNS |
| DNS-over-HTTPS | 443 (TCP/UDP) to known DNS IPs | **Reject** | Blocks DoH to Google, Cloudflare, etc. |
| Direct DNS | Port 53 to known DNS IPs | **Reject** | Prevents hardcoded DNS (8.8.8.8, etc.) |

### Blocked DNS Providers
Google (8.8.8.8/8.8.4.4), Cloudflare (1.1.1.1/1.0.0.1), Quad9 (9.9.9.9), OpenDNS (208.67.222.222/208.67.220.220), Neustar (64.6.64.6), CleanBrowsing (185.228.168.168), Control D (76.76.19.19), AdGuard (94.140.14.14)

## Requirements

- Rooted device (KernelSU or Magisk)
- A hosts-based ad blocker like [AdAway](https://adaway.org/) with Systemless Hosts enabled

## Installation

1. Flash the module zip via KernelSU or Magisk manager
2. Reboot
3. Enable your hotspot — connected devices will now use your hosts file

## OverlayFS Compatibility

This module is fully compatible with KernelSU's OverlayFS-based module system:
- **No system partition modifications** — everything runs in RAM via iptables
- **Custom chains** (`HOTSPOT_DNS` / `HOTSPOT_DNS_FWD`) — never conflicts with other modules or Android's netd
- **Clean teardown** — rules are automatically removed when the hotspot is turned off

## Supported Interfaces

- Wi-Fi hotspot: `wlan1`, `ap0`, `swlan0`, `wlan2`, `softap0`
- USB tethering: `rndis0`, `usb0`
- Bluetooth tethering: `bt-pan`

## Logs

```bash
cat /data/local/tmp/hotspot-dns-redirect.log
```

## Limitations

- **DoH via non-DNS providers**: If a client uses DoH through a CDN or custom server (not a well-known DNS IP), it won't be blocked. Standard DNS will still be redirected though.
- **5-second polling**: There's a brief window after enabling the hotspot where rules aren't applied yet.
