// Classifies network interfaces so the cluster screen never advertises a
// docker bridge, and so a USB or Tailscale link can be labelled.
library;

/// What kind of link an interface is.
enum ClusterLinkKind {
  wifi('Wi-Fi'),
  ethernet('Ethernet'),
  usb('USB'),
  tailscale('Tailscale'),
  virtual('Virtual');

  const ClusterLinkKind(this.label);

  final String label;
}

/// One address a cluster could run on.
class ClusterInterface {
  final String name;
  final String address;
  final ClusterLinkKind kind;

  const ClusterInterface(this.name, this.address, this.kind);
}

/// The kind of link [name] is, from kernel/OS naming conventions.
///
/// The USB check looks at the name and at the usual tethering subnet, so a
/// phone's `rndis0`/`usb0` and a PC's `enx…`/`usb0` are labelled even when
/// udev cannot tell us.
ClusterLinkKind classifyInterface(String name, [String address = '']) {
  final n = name.toLowerCase();
  if (n.contains('tailscale') || n.startsWith('utun')) {
    return ClusterLinkKind.tailscale;
  }
  if (n.contains('docker') ||
      n.startsWith('veth') ||
      n.startsWith('virbr') ||
      n.startsWith('br-') ||
      n.contains('vmnet') ||
      n.contains('podman') ||
      n.startsWith('tun') ||
      n.startsWith('tap') ||
      n.contains('vethernet') ||
      n.contains('hyper-v') ||
      n.contains('wsl') ||
      n.contains('virtualbox') ||
      n.contains('vmware') ||
      n.contains('loopback') ||
      n.contains('npcap') ||
      n.contains('zerotier')) {
    return ClusterLinkKind.virtual;
  }
  if (n.startsWith('wl') ||
      n.contains('wlan') ||
      n.contains('wi-fi') ||
      n.contains('wifi')) {
    return ClusterLinkKind.wifi;
  }
  if (n.startsWith('usb') ||
      n.startsWith('enx') ||
      n.contains('rndis') ||
      address.startsWith('192.168.42.')) {
    return ClusterLinkKind.usb;
  }
  if (n.startsWith('en') || n.startsWith('eth') || n.contains('ethernet')) {
    return ClusterLinkKind.ethernet;
  }
  return ClusterLinkKind.virtual;
}

/// True for addresses a cluster can use (not loopback or link-local).
bool isUsableAddress(String address) =>
    !address.startsWith('127.') &&
    !address.startsWith('169.254.') &&
    address != '::1' &&
    !address.startsWith('fe80:');

/// Like [classifyInterface], but a generic `tun*` adapter (Android VPNs,
/// including Tailscale) is offered as Tailscale only when the user opted in.
ClusterLinkKind rankKind(String name, String address, bool includeVpn) {
  final kind = classifyInterface(name, address);
  if (includeVpn &&
      kind == ClusterLinkKind.virtual &&
      name.toLowerCase().startsWith('tun')) {
    return ClusterLinkKind.tailscale;
  }
  return kind;
}

/// Ranks usable addresses: Wi-Fi first, then Ethernet, USB, and Tailscale.
/// Virtual adapters are skipped unless [includeVpn] asks for Tailscale.
List<ClusterInterface> rankInterfaces(
  Iterable<({String name, String address})> all, {
  bool includeVpn = false,
}) {
  final usable = <ClusterInterface>[
    for (final entry in all)
      if (isUsableAddress(entry.address))
        if (rankKind(entry.name, entry.address, includeVpn) case final kind
            when kind != ClusterLinkKind.virtual &&
                (includeVpn || kind != ClusterLinkKind.tailscale))
          ClusterInterface(entry.name, entry.address, kind),
  ];
  int rank(ClusterLinkKind kind) => switch (kind) {
        ClusterLinkKind.wifi => 0,
        ClusterLinkKind.ethernet => 1,
        ClusterLinkKind.usb => 2,
        ClusterLinkKind.tailscale => 3,
        ClusterLinkKind.virtual => 4,
      };
  return usable..sort((a, b) => rank(a.kind).compareTo(rank(b.kind)));
}
