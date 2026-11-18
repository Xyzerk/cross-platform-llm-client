import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/cluster_endpoint.dart';

void main() {
  group('ClusterEndpoint.parse', () {
    test('a bare host uses the default port', () {
      final endpoint = ClusterEndpoint.parse('192.168.1.20');

      expect(endpoint.host, '192.168.1.20');
      expect(endpoint.port, 50052);
      expect(endpoint.authority, '192.168.1.20:50052');
    });

    test('host:port is honoured', () {
      final endpoint = ClusterEndpoint.parse('worker.local:50100');

      expect(endpoint.host, 'worker.local');
      expect(endpoint.port, 50100);
    });

    test('bracketed IPv6 keeps the brackets in the authority', () {
      final endpoint = ClusterEndpoint.parse('[fd7a:115c:a1e0::1]:50052');

      expect(endpoint.host, 'fd7a:115c:a1e0::1');
      expect(endpoint.port, 50052);
      expect(endpoint.authority, '[fd7a:115c:a1e0::1]:50052');
    });

    test('a bare IPv6 address uses the default port', () {
      final endpoint = ClusterEndpoint.parse('fd7a:115c:a1e0::1');

      expect(endpoint.host, 'fd7a:115c:a1e0::1');
      expect(endpoint.port, 50052);
    });

    test('a pasted URL is reduced to its authority', () {
      final endpoint = ClusterEndpoint.parse('http://100.64.0.2:50052/path');

      expect(endpoint.host, '100.64.0.2');
      expect(endpoint.port, 50052);
    });

    test('rejects empty input, a missing host and bad ports', () {
      expect(() => ClusterEndpoint.parse('  '), throwsFormatException);
      expect(() => ClusterEndpoint.parse(':50052'), throwsFormatException);
      expect(() => ClusterEndpoint.parse('host:0'), throwsFormatException);
      expect(() => ClusterEndpoint.parse('host:99999'), throwsFormatException);
      expect(() => ClusterEndpoint.parse('host:abc'), throwsFormatException);
    });
  });
}
