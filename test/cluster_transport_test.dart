// Transport metadata in saved workers and QR links. Older builds sent no
// `transport` field, so everything unknown must fall back to LAN rather than
// dropping the worker (users would lose their saved cluster).

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

void main() {
  test('wire names stay short and stable for QR links', () {
    expect(ClusterTransport.lan.wireName, 'lan');
    expect(ClusterTransport.usbAdb.wireName, 'usb');
    expect(ClusterTransport.usbTether.wireName, 'usbtether');
    expect(ClusterTransport.tailscale.wireName, 'tailscale');
  });

  test('parse accepts current and older spellings', () {
    expect(ClusterTransport.parse('usb'), ClusterTransport.usbAdb);
    expect(ClusterTransport.parse('usbadb'), ClusterTransport.usbAdb);
    expect(ClusterTransport.parse('usbtether'), ClusterTransport.usbTether);
    expect(ClusterTransport.parse('tether'), ClusterTransport.usbTether);
    expect(ClusterTransport.parse('tailscale'), ClusterTransport.tailscale);
    expect(ClusterTransport.parse('lan'), ClusterTransport.lan);
  });

  test('missing or unknown transports fall back to LAN', () {
    expect(ClusterTransport.parse(null), ClusterTransport.lan);
    expect(ClusterTransport.parse(''), ClusterTransport.lan);
    expect(ClusterTransport.parse('bluetooth'), ClusterTransport.lan);
  });

  test('a worker map round-trips transport, iface and latency', () {
    const worker = ClusterWorker(
      name: 'Pixel',
      host: '100.64.0.7',
      port: 50052,
      ramMb: 4096,
      bandwidth: 12.5,
      id: 'abc',
      transport: ClusterTransport.tailscale,
      iface: 'tailscale0',
      latencyMs: 150,
    );

    final copy = ClusterWorker.fromMap(worker.toMap());
    expect(copy.name, 'Pixel');
    expect(copy.host, '100.64.0.7');
    expect(copy.transport, ClusterTransport.tailscale);
    expect(copy.iface, 'tailscale0');
    expect(copy.latencyMs, 150);
    expect(copy.endpoint, '100.64.0.7:50052');
  });

  test('a worker saved before transports existed still loads as LAN', () {
    final old = ClusterWorker.fromMap(const {
      'name': 'Old phone',
      'host': '192.168.1.20',
      'port': 50052,
      'ramMb': 2048,
      'bandwidth': 8.0,
      'id': 'old-id',
    });

    expect(old.transport, ClusterTransport.lan);
    expect(old.iface, isNull);
    expect(old.latencyMs, isNull);
    expect(old.endpoint, '192.168.1.20:50052');
  });

  test('movedTo keeps the transport and iface', () {
    const worker = ClusterWorker(
      name: 'PC',
      host: '192.168.42.10',
      port: 50052,
      transport: ClusterTransport.usbTether,
      iface: 'enx001122334455',
    );

    final moved = worker.movedTo('192.168.42.11', 50052);
    expect(moved.transport, ClusterTransport.usbTether);
    expect(moved.iface, 'enx001122334455');
    expect(moved.endpoint, '192.168.42.11:50052');
  });

  test('IPv6 endpoints are bracketed once', () {
    expect(ClusterWorker.formatEndpoint('fd7a::1', 50052), '[fd7a::1]:50052');
    expect(
        ClusterWorker.formatEndpoint('[fd7a::1]', 50052), '[fd7a::1]:50052');
    expect(ClusterWorker.formatEndpoint('100.64.0.7', 50052),
        '100.64.0.7:50052');
  });
}
