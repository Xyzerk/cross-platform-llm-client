# Pairing a phone over USB with adb

PrivateLM can use a plain USB cable instead of Wi-Fi. It does not need root,
USB tethering, or a second network: it asks the `adb` you already have to
forward a loopback port to the phone, and the cluster speaks its normal TCP
protocol through it.

This works from the **Windows** and **Linux** desktop apps. Phones cannot run
`adb` against each other.

## What you need

- A USB **data** cable (not a charge-only cable).
- Android **platform-tools** (`adb`) on the desktop:
  - Ubuntu/Debian: `sudo apt install android-tools-adb`
  - Fedora: `sudo dnf install android-tools`
  - Arch: `sudo pacman -S android-tools`
  - Or install Android Studio / the SDK command-line tools.
- Developer options and **USB debugging** on the phone:
  1. Settings → About phone → tap **Build number** seven times.
  2. Developer options → enable **USB debugging**.
  3. Plug in the cable and tap **Allow** on the phone.

PrivateLM looks for `adb` in this order: `PRIVATELM_ADB`, `PATH`,
`ANDROID_HOME`/`ANDROID_SDK_ROOT`, then the common SDK locations. It never
bundles or downloads adb.

Check that the phone is visible:

```bash
adb devices -l
```

The state must be `device`. `unauthorized` means the phone has not allowed
this computer; `no permissions` usually means a Linux udev/plugdev problem.

## PC master + phone worker

1. On the phone, open **AI cluster** → **Worker**.
2. On the PC, open **AI cluster** → **Master**.
3. Tap **Add over USB** and pick the phone.
4. Load a GGUF model.

PrivateLM runs:

```bash
adb -s <serial> forward tcp:50100 tcp:50052
```

and adds `127.0.0.1:50100` as a worker. Each phone gets its own local port
(50100, 50101, …). The phone's worker keeps listening on 50052 only on the
phone; the cable carries the RPC traffic and nothing is exposed on the LAN.

## Phone master + PC worker

1. On the PC, open **AI cluster** → **Worker**.
2. Tap **Connect a phone over USB** and pick the phone.
3. On the phone, open **AI cluster** → **Master** → **Enter IP** and add
   `127.0.0.1:50100` (the port is shown in the confirmation).
4. Load a GGUF model on the phone.

PrivateLM runs:

```bash
adb -s <serial> reverse tcp:50100 tcp:50052
```

so the phone's loopback reaches the worker on this PC.

## Cleanup and limits

- Mappings are saved and removed when you remove the worker, change the
  cluster role, or close the app. The next launch removes mappings left behind
  by a crash before re-creating the ones for the current role.
- The bridge exists only while PrivateLM runs.
- Unplugging the cable gives the same "worker unreachable" error as a Wi-Fi
  drop; the app keeps running.
- USB debugging is a developer setting. Turn it off when you are done if you
  do not use it.

## Troubleshooting

| Symptom | Check |
|---|---|
| "Add over USB" is missing | `adb` was not found. Install platform-tools, or set `PRIVATELM_ADB=/path/to/adb`. |
| Phone shows `unauthorized` | Unlock the phone and tap **Allow** on the USB-debugging prompt. Try `adb kill-server` then replug. |
| `no permissions` on Linux | Add your user to `plugdev` (`sudo usermod -aG plugdev $USER`), install the phone's udev rules, then log out and in. |
| `adb forward` fails | Another tool owns that port, or the phone disconnected. Replug and try again; ports are allocated automatically from 50100. |
| Phone master cannot reach `127.0.0.1:50100` | The PC must stay on the **Worker** screen (the worker process stops when you switch roles or close the app). |
| Worker disconnects mid-generation | Replug the cable, then reconnect the bridge. The app reports the unreachable worker instead of crashing. |

> **Security.** The cluster protocol has no authentication. An adb bridge is
> loopback-only and lives only while PrivateLM runs, but anyone with `adb`
> access to the phone can reach the worker while it is active. Only use cables
> and computers you trust.
