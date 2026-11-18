# PrivateLM AI cluster

A PrivateLM cluster spreads one GGUF model across the devices you already own.
One device is the **master** and runs the model; every other device is a
**worker** that holds part of the model's layers and serves them over the
network. Each token crosses the network once, so a fast LAN (5 GHz Wi-Fi,
Ethernet) matters more than raw CPU speed.

This page covers clustering for Linux, Windows, Android and iOS over a LAN, a
USB cable (`adb`), USB tethering, and Tailscale. The transport changes how
devices are paired and reached; the `rpc7` protocol and the split are the same.

| Master        | Workers                          | Status |
|---------------|----------------------------------|--------|
| Linux PC      | Linux PC, Windows PC, phones     | works  |
| Windows PC    | Linux PC, Windows PC, phones     | works  |
| Android phone | Linux PC, Windows PC, phones     | works  |
| iOS phone     | —                                | not yet (worker only) |

| Transport | Pairing | Notes |
|---|---|---|
| Wi-Fi / LAN | QR code, address, "Find nearby" | Default; fastest practical link |
| USB · adb | "Add over USB" (desktop) | Plain cable, no root; see [usb-adb.md](usb-adb.md) |
| USB tether | Phone's USB tethering address | No adb needed; pick the `192.168.42.x` interface |
| Tailscale | "Find Tailscale" (desktop) | Off by default; see the security section |

> **Trusted networks only.** llama.cpp's RPC protocol has **no
> authentication**. A worker exposes its CPU and memory to anyone who can
> reach TCP port `50052`. Do not run a worker on public Wi-Fi, in a café, or on
> a network you do not control, and never port-forward `50052` from the
> internet. Tailscale is the supported way to cross networks, and its opt-in
> warning applies too.

## Requirements

- The same LAN (same subnet, no client isolation / "AP isolation").
- **TCP 50052** inbound on the worker.
- **UDP 5353** (mDNS) for "Find nearby" only; pairing by `IP:port` or QR code
  works without it.
- The same PrivateLM build family: the workers speak llama.cpp's `rpc7`
  protocol, so all devices must run versions built from the same engine.

For USB, additionally:

- Desktop: Android platform-tools (`adb`) on `PATH` or `ANDROID_HOME`.
- Phone: USB debugging enabled and this computer authorized.
  [usb-adb.md](usb-adb.md) walks through it.

For Tailscale: the `tailscale` CLI signed in on the desktop. Entering a
MagicDNS name by hand works without the CLI.

## Linux as a worker

1. Open **Cluster** in PrivateLM and choose **Worker**.
2. The screen shows a QR code and an `IP:port` line. Scan the QR from an
   Android/iOS master, or type the address there.
3. Allow the port through the local firewall if the master cannot connect:

   ```bash
   # ufw (Ubuntu, Debian, Linux Mint)
   sudo ufw allow 50052/tcp

   # firewalld (Fedora, RHEL, openSUSE)
   sudo firewall-cmd --add-port=50052/tcp
   sudo firewall-cmd --permanent --add-port=50052/tcp
   ```

   PrivateLM never elevates and never edits firewall rules on Linux; the
   cluster screen shows this hint instead of a button.

The worker is `bundle/lib/privatelm_rpc_worker`, started by the app as a child
process and stopped when you choose another role or close the app. Its state
lives in:

```
$XDG_STATE_HOME/privatelm/cluster/worker.json      # or
~/.local/state/privatelm/cluster/worker.json
```

The file is rewritten every second; the app treats a file older than six
seconds as a stopped worker. The worker also exits within about two seconds of
the app process disappearing, so a crashed window does not leave the port
held.

## Linux as a master

1. On each worker device, choose **Worker** and note its `IP:port`.
2. On the Linux PC, choose **Master**, then add workers:
   - paste a `privatelm://worker?...` link,
   - type `IP:port`, or
   - use **Find nearby**, which browses mDNS.
3. Load a GGUF model. PrivateLM asks each worker for its free RAM and memory
   speed, then fills the fastest devices first (or shares in proportion to
   speed when the model also fits locally).
4. The split card shows this PC's share and each worker's share.

Linux has no camera scanner plugin, so a Linux master pairs by pasted link or
`IP:port` instead of a QR scan. Phones can still scan the QR code shown by a
Linux worker.

## USB over a cable

On the desktop, **AI cluster** → **Master** → **Add over USB** lists attached
phones and adds the selected one as `127.0.0.1:501xx` through
`adb forward`. For the other direction, choose **Worker** on the PC, tap
**Connect a phone over USB**, then add `127.0.0.1:50100` on the phone's master
screen. The app removes the mappings on role change and exit.

Full setup, cleanup and troubleshooting: [usb-adb.md](usb-adb.md).

## USB tethering

Turn on **USB tethering** on the phone and leave the cable connected. The phone
gets a `192.168.42.x` address on its USB network and the PC gets another. Pick
that interface under **AI cluster → This device**, or enter the address
directly; the worker badge shows **USB tether**.

No adb and no developer settings are needed. Tethering also works for an
iPhone's Personal Hotspot over USB, where the phone is the worker or master
using the hotspot subnet.

## Tailscale

Tailscale reaches devices that are not on the same LAN. It is **off by
default**:

1. Install and sign in to Tailscale on both devices.
2. In **AI cluster → This device → Change**, enable **Tailscale interfaces**.
3. On the desktop master, use **Find Tailscale** to list online peers, or type
   the peer's MagicDNS name in **Enter IP**.

A DERP-relayed peer is shown with its estimated latency and receives a smaller
share of the model, because every token crosses the relay. Direct peers are
preferred.

> **A tailnet is not a trusted LAN.** The RPC port has no authentication.
> Restrict `tcp:50052` with Tailscale ACLs to the devices that should cluster,
> prefer tagged and approved devices, and disable key expiry only deliberately.
> Never enable Tailscale mode on a machine you do not control.

To reduce exposure further, open **AI cluster → This device → Change** and turn
on **Worker: this network only**. The worker then binds its RPC listener to the
selected interface instead of `0.0.0.0`, so the LAN, a USB link and the tailnet
cannot reach it at the same time. Restart the worker after changing it; the
setting is remembered across launches.

## Discovery on Linux

The worker advertises `_privatelm._tcp` through `avahi-publish-service` when
Avahi is installed; without it nothing is advertised, and pairing by address
still works. The app browses mDNS with `multicast_dns`, which works on both
Windows and Linux.

To confirm the advertisement:

```bash
avahi-browse -rt _privatelm._tcp
```

## Network interfaces

A desktop usually has several interfaces. PrivateLM ranks the physical ones
first — Wi-Fi (`wlan*`, `wlp*`, `Wi-Fi`), then Ethernet (`en*`, `eth*`,
`Ethernet`), then USB/RNDIS (`usb*`, `enx*`, `rndis*`) — and skips virtual
ones (`docker0`, `veth*`, `virbr*`, `br-*`, `vmnet*`, `tap*`, `zerotier*`,
Hyper-V, WSL, VirtualBox). `tailscale*`/`utun*` (and a generic `tun*` on
Android) are listed only when **Tailscale interfaces** is on. Pick the
interface that is on the same network as the other devices in **AI cluster →
This device**.

## Windows

Windows uses the same protocol and the same role model; firewall prompts,
`%LOCALAPPDATA%\PrivateLM\cluster`, and network-profile caveats are covered in
[docs/windows-cluster.md](windows-cluster.md).

## Troubleshooting

| Symptom | Check |
|---|---|
| Master reports the worker unreachable | `ss -ltn \| grep 50052` on the worker, then the firewall commands above. |
| Worker starts then immediately errors | Another process holds 50052, or the app is gone. The status file carries the OS message. |
| Worker binary missing | Rebuild with `scripts/build_linux.sh`; `bundle/lib/privatelm_rpc_worker` must exist and be executable. |
| Pairing works by IP, "Find nearby" is empty | mDNS is blocked (UDP 5353) or Avahi is not running; use `IP:port`. |
| Model does not fit | Add a worker, close apps on the workers, or choose a smaller quantization. |
| Worker disconnects when idle | The Linux worker holds an idle inhibitor through `systemd-inhibit` while sharing; on hosts without systemd this is skipped, so disable suspend for long jobs. |

## Limits

- iOS is worker-only; it cannot be a master.
- The protocol has no authentication or encryption. Use trusted networks,
  adb, or an ACL-restricted tailnet.
- IPv6 works for manual addresses and MagicDNS. mDNS discovery is IPv4 only.
- There is no cloud relay or account: devices find each other directly.
