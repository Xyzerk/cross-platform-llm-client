import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:privatelm/services/tailscale_service.dart';

void main() {
  group('TailscaleService.parseStatus', () {
    const status = '''
{
  "Self": {"HostName": "this-pc", "DNSName": "this-pc.tail.ts.net.", "TailscaleIPs": ["100.64.0.1"]},
  "Peer": {
    "nodekey:aaa": {
      "HostName": "direct-pc",
      "DNSName": "direct-pc.tail.ts.net.",
      "TailscaleIPs": ["100.64.0.2", "fd7a:115c:a1e0::2"],
      "Online": true,
      "OS": "linux",
      "CurAddr": "192.168.1.5:41641",
      "Relay": "",
      "Tags": ["tag:cluster"]
    },
    "nodekey:bbb": {
      "HostName": "relay-pc",
      "DNSName": "relay-pc.tail.ts.net.",
      "TailscaleIPs": ["100.64.0.3"],
      "Online": true,
      "OS": "windows",
      "CurAddr": "",
      "Relay": "fra"
    },
    "nodekey:ccc": {
      "HostName": "offline-pc",
      "DNSName": "offline-pc.tail.ts.net.",
      "TailscaleIPs": ["100.64.0.4"],
      "Online": false,
      "CurAddr": "",
      "Relay": "ams"
    }
  }
}
''';

    test('keeps online peers with an IPv4 address, self excluded', () {
      final peers = TailscaleService.parseStatus(status);

      expect(peers.map((p) => p.hostName), ['direct-pc', 'relay-pc']);
      expect(peers.every((p) => !p.ip.contains(':')), isTrue);
    });

    test('direct peers are not treated as relays', () {
      final direct = TailscaleService.parseStatus(status).first;

      expect(direct.direct, isTrue);
      expect(direct.latencyMs, 10);
      expect(direct.dnsName, 'direct-pc.tail.ts.net');
    });

    test('a DERP peer carries a higher latency estimate', () {
      final relay = TailscaleService.parseStatus(status).last;

      expect(relay.direct, isFalse);
      expect(relay.relay, 'fra');
      expect(relay.latencyMs, 150);
    });

    test('empty and malformed status is an empty list', () {
      expect(TailscaleService.parseStatus(''), isEmpty);
      expect(TailscaleService.parseStatus('{}'), isEmpty);
      expect(TailscaleService.parseStatus('not json'), isEmpty);
    });
  });

  test('a peer becomes a Tailscale worker with the default port', () {
    final peers = TailscaleService.parseStatus('''
{"Peer": {"k": {"HostName": "pc", "DNSName": "pc.tail.ts.net.",
 "TailscaleIPs": ["100.64.0.9"], "Online": true, "CurAddr": "1.2.3.4:1", "Relay": ""}}}
''');

    final worker = peers.single.toWorker();

    expect(worker.transport, ClusterTransport.tailscale);
    expect(worker.endpoint, '100.64.0.9:50052');
    expect(worker.id, 'pc.tail.ts.net');
    expect(worker.latencyMs, 10);
  });

  test('a missing CLI is reported clearly', () async {
    final tailscale = TailscaleService(exePath: '');

    expect(tailscale.available, isFalse);
    await expectLater(
        tailscale.peers(), throwsA(isA<TailscaleUnavailableException>()));
  });

  test('findTailscale honours PRIVATELM_TAILSCALE', () {
    final file = File('/tmp/privatelm-tailscale-test');
    file.writeAsStringSync('');
    addTearDown(() => file.deleteSync());

    final found = TailscaleService.findTailscale(environment: {
      'PRIVATELM_TAILSCALE': file.path,
      'PATH': '',
    });

    expect(found, file.path);
  });
}
