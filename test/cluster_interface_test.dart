import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/cluster_interface.dart';

void main() {
  group('classifyInterface', () {
    test('recognises Wi-Fi and Ethernet names on Linux and Windows', () {
      expect(classifyInterface('wlp3s0'), ClusterLinkKind.wifi);
      expect(classifyInterface('wlan0'), ClusterLinkKind.wifi);
      expect(classifyInterface('Wi-Fi'), ClusterLinkKind.wifi);
      expect(classifyInterface('enp0s31f6'), ClusterLinkKind.ethernet);
      expect(classifyInterface('eth0'), ClusterLinkKind.ethernet);
      expect(classifyInterface('Ethernet 2'), ClusterLinkKind.ethernet);
    });

    test('recognises USB tethering names and subnet', () {
      expect(classifyInterface('usb0'), ClusterLinkKind.usb);
      expect(classifyInterface('enx001122334455'), ClusterLinkKind.usb);
      expect(classifyInterface('rndis0'), ClusterLinkKind.usb);
      expect(classifyInterface('enp0s20u1', '192.168.42.100'),
          ClusterLinkKind.usb);
    });

    test('recognises Tailscale adapters', () {
      expect(classifyInterface('tailscale0'), ClusterLinkKind.tailscale);
      expect(classifyInterface('utun3'), ClusterLinkKind.tailscale);
    });

    test('skips containers, bridges and other VPNs', () {
      for (final name in [
        'docker0',
        'veth1234',
        'virbr0',
        'br-abc',
        'vmnet8',
        'tun0',
        'tap0',
        'vEthernet (WSL)',
        'zerotier-one',
      ]) {
        expect(classifyInterface(name), ClusterLinkKind.virtual, reason: name);
      }
    });
  });

  group('rankInterfaces', () {
    final all = [
      (name: 'docker0', address: '172.17.0.1'),
      (name: 'tailscale0', address: '100.64.0.1'),
      (name: 'usb0', address: '192.168.42.100'),
      (name: 'enp0s31f6', address: '192.168.1.10'),
      (name: 'wlp3s0', address: '192.168.1.11'),
      (name: 'lo', address: '127.0.0.1'),
      (name: 'enp0s31f6', address: '169.254.10.1'),
    ];

    test('Wi-Fi, Ethernet, USB; virtual and loopback removed', () {
      final ranked = rankInterfaces(all);

      expect(ranked.map((i) => i.kind), [
        ClusterLinkKind.wifi,
        ClusterLinkKind.ethernet,
        ClusterLinkKind.usb,
      ]);
    });

    test('Tailscale is only offered when opted in', () {
      expect(
          rankInterfaces(all).any((i) => i.kind == ClusterLinkKind.tailscale),
          isFalse);
      expect(
        rankInterfaces(all, includeVpn: true).last.kind,
        ClusterLinkKind.tailscale,
      );
    });
  });
}
