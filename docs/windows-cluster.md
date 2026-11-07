# PrivateLM Windows cluster

A Windows PC can run a GGUF model together with Android/iOS phones on the same
Wi-Fi. Either side can be the master:

| Master        | Workers                          | Status |
|---------------|----------------------------------|--------|
| Windows PC    | Android phones, iOS phones, PCs  | works  |
| Android phone | Windows PC, Android phones       | works  |
| iOS phone     | —                                | not yet (iOS can only be a worker) |

The master runs the model; each worker holds part of its layers. Every token
travels over the network once, so a fast LAN (5 GHz Wi-Fi or Ethernet) matters
more than raw phone speed.

> **Trusted LAN only.** llama.cpp's RPC protocol has **no authentication**. A
> worker exposes its CPU and memory to anyone who can reach TCP port `50052`.
> Do not run cluster mode on public Wi-Fi, and never port-forward `50052`.

## Windows as a worker

1. Open **Cluster** in PrivateLM and pick **Worker**.
2. If Windows Firewall prompts (or the screen shows a warning), allow the
   `PrivateLM Cluster` rule. This is one UAC prompt.
3. The screen shows a QR code and an `IP:port` line. Scan the QR with an
   Android/iOS master, or type `IP:port` there.
4. Keep PrivateLM running. Closing the app stops the worker; it is a child
   process of the app and is killed with it.

The worker writes its live state to
`%LOCALAPPDATA%\PrivateLM\cluster\worker.json` (rewritten every second). The
Windows cluster screen and the master read the same information over the RPC
probe, so a stale file is not treated as a running worker after six seconds.

## Windows as a master

1. Add workers by QR code, by pasting a `privatelm://worker?...` link, or by
   typing `IP:port`.
2. Turn the role to **Master**. The choice is saved as `cluster_enabled`.
3. Load a GGUF model. The app asks each worker for its free RAM and memory
   bandwidth, then either fills the fastest devices first (model does not fit
   here) or shares in proportion to speed (it fits, and you chose to share).
4. The split card shows this PC's share and each worker's share.

Workers that moved to a new IP are found again by their stable worker ID, as
long as "Find nearby" (mDNS) can see them. If mDNS is blocked, remove the
worker and pair it again by IP.

## Firewall and network profile

Cluster mode needs:

- **TCP 50052** inbound — the RPC worker. Required for manual IP pairing.
- **UDP 5353** inbound — mDNS, only for "Find nearby".

Windows Firewall applies rules per network profile. A network that Windows
classifies as **Public** blocks both even when the rule exists. Set the Wi-Fi
or Ethernet network to **Private**:

```
Settings → Network & Internet → <adapter> → Network profile type → Private
```

The cluster screen's "Allow through Windows Firewall" button adds the TCP rule.
It does not change the network profile and does not add the mDNS rule.

If the port cannot be bound, the worker reports the Winsock error verbatim
(for example `Only one usage of each socket address is normally permitted`)
instead of a generic failure.

## Choosing an interface

A PC usually has several IPv4 addresses (Wi-Fi, Ethernet, Hyper-V, WSL,
VirtualBox, Tailscale). The cluster screen lists the physical ones first and
skips known virtual adapters. If the wrong one was picked, choose another; the
choice is saved as `cluster_interface` and advertised through mDNS.

## Troubleshooting

**The phone can't reach the PC.**
Check the IP in the worker screen, not the one from `ipconfig` if the PC has
several adapters. Confirm the network profile is Private and that TCP 50052 is
allowed. From the phone's network, try `Test-NetConnection <pc-ip> -Port 50052`
on the PC (PowerShell) or any TCP probe app on the phone.

**"Find nearby" finds nothing.**
mDNS is often blocked on guest Wi-Fi and some routers. Manual IP pairing works
without it.

**The load fails with "Worker … reported no devices" or "No cluster workers".**
The worker process died or its port is not reachable. Re-open the cluster
screen on the PC, make sure the role is Worker, and check the status line.

**The master loads but generation is very slow.**
A slow or congested Wi-Fi link dominates. Prefer Ethernet on the PC, 5 GHz
Wi-Fi on phones, and put the largest share on the fastest device. Phones on
battery saver are throttled; the Android worker asks for an unrestricted
battery exemption for this reason.

**Closing the PC app leaves a worker behind.**
It should not: the worker is in a Job Object with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. If it happens after a crash, end
`privatelm_rpc_worker.exe` in Task Manager. The next start replaces the status
file.

**The PC window is black on an old GPU.**
That is a Flutter 3.47 compositor bug on D3D11 feature level 10_0 hardware, not
a cluster problem. See the "Old GPUs and the black window" section of
[windows-build.md](windows-build.md).

## What is not shared

- LiteRT-LM (`.litertlm`) and Stable Diffusion (`.safetensors`) models cannot be
  split; only GGUF goes through llama.cpp's RPC backend.
- Cluster mode carries text generation. Vision projectors run on the master's
  CPU, so images are encoded locally before the prompt is sent.
