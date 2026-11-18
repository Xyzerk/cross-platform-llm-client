// Parses the "address" the user types to add a worker.
//
// Accepts `host`, `host:port`, `[ipv6]:port`, a bare IPv6 address and
// MagicDNS/Tailscale names. The port defaults to llama.cpp's RPC port.
library;

import 'package:llama_flutter_android/llama_flutter_android.dart';

/// A worker address: a host (name, IPv4 or IPv6) and a TCP port.
class ClusterEndpoint {
  final String host;
  final int port;

  const ClusterEndpoint(this.host, this.port);

  static const int defaultPort = 50052;

  /// Throws [FormatException] with a user-readable message when [input] is not
  /// an address.
  factory ClusterEndpoint.parse(
    String input, {
    int defaultPort = defaultPort,
  }) {
    var text = input.trim();
    if (text.isEmpty) {
      throw const FormatException('Enter the worker\'s address');
    }

    // Tolerate a pasted URL: keep only the authority.
    final scheme = text.indexOf('://');
    if (scheme >= 0) text = text.substring(scheme + 3);
    if (text.contains('/')) text = text.substring(0, text.indexOf('/'));

    if (text.startsWith('[')) {
      // [IPv6] or [IPv6]:port
      final close = text.indexOf(']');
      if (close < 0) {
        throw const FormatException('Use the form [::1]:50052');
      }
      final host = text.substring(1, close);
      final rest = text.substring(close + 1);
      if (host.isEmpty) throw const FormatException('Enter a host name or IP');
      if (rest.isEmpty) return ClusterEndpoint(host, defaultPort);
      if (!rest.startsWith(':')) {
        throw const FormatException('Use the form [::1]:50052');
      }
      return ClusterEndpoint(host, _parsePort(rest.substring(1)));
    }

    final colons = ':'.allMatches(text).length;
    if (colons > 1) {
      // A bare IPv6 address: no port was given.
      return ClusterEndpoint(text, defaultPort);
    }
    if (colons == 1) {
      final host = text.substring(0, text.indexOf(':'));
      if (host.isEmpty) throw const FormatException('Enter a host name or IP');
      return ClusterEndpoint(
          host, _parsePort(text.substring(text.indexOf(':') + 1)));
    }
    return ClusterEndpoint(text, defaultPort);
  }

  /// `host:port`, with IPv6 hosts in brackets (what sockets and RPC accept).
  String get authority => ClusterWorker.formatEndpoint(host, port);

  static int _parsePort(String text) {
    final port = int.tryParse(text);
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('Port must be a number between 1 and 65535');
    }
    return port;
  }

  @override
  String toString() => authority;
}
