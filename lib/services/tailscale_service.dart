// Tailscale peer discovery, desktop only.
//
// mDNS does not cross a tailnet, so the CLI is the discovery source. The RPC
// transport is unchanged: a peer is just another `host:50052` endpoint. The
// parser is pure so it can be tested without Tailscale installed.
import 'dart:convert';
import 'dart:io';

import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:path/path.dart' as p;

import 'cluster_backend.dart';

/// One online Tailscale peer, mapped to what the cluster screen needs.
class TailscalePeer {
  final String nodeKey;
  final String hostName;
  final String dnsName;
  final String ip;
  final String? os;
  final String? relay;

  /// True when traffic goes directly (no DERP relay).
  final bool direct;

  /// Best-effort round-trip estimate. A DERP relay is assumed slower than a
  /// direct path; the planner discounts it accordingly.
  final int? latencyMs;

  const TailscalePeer({
    required this.nodeKey,
    required this.hostName,
    required this.dnsName,
    required this.ip,
    this.os,
    this.relay,
    this.direct = true,
    this.latencyMs,
  });

  /// The peer as a worker. It is probed before it is saved, so an offline or
  /// non-cluster device is rejected like any other unreachable address.
  ClusterWorker toWorker({int port = ClusterBackend.defaultPort}) =>
      ClusterWorker(
        name: hostName.isEmpty ? dnsName : hostName,
        host: ip,
        port: port,
        model: hostName,
        id: dnsName.isEmpty ? nodeKey : dnsName,
        transport: ClusterTransport.tailscale,
        latencyMs: latencyMs,
      );
}

typedef TailscaleRunner = Future<ProcessResult> Function(
    String exe, List<String> args);

/// Finds and reads `tailscale status --json`. Never bundles or installs the
/// CLI: without it the feature is simply unavailable.
class TailscaleService {
  TailscaleService({String? exePath, TailscaleRunner? runner})
      : _exePath = exePath,
        _runner = runner;

  final String? _exePath;
  final TailscaleRunner? _runner;
  String? _resolved;

  String? get exePath {
    final path = _exePath ?? (_resolved ??= findTailscale());
    return path == null || path.isEmpty ? null : path;
  }

  bool get available => exePath != null;

  static String? findTailscale({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final exe = Platform.isWindows ? 'tailscale.exe' : 'tailscale';

    final override = env['PRIVATELM_TAILSCALE'];
    if (override != null &&
        override.isNotEmpty &&
        File(override).existsSync()) {
      return override;
    }
    final path = env['PATH'];
    if (path != null && path.isNotEmpty) {
      for (final dir in path.split(Platform.isWindows ? ';' : ':')) {
        if (dir.isEmpty) continue;
        final candidate = p.join(dir, exe);
        if (File(candidate).existsSync()) return candidate;
      }
    }
    final candidates = <String>[
      if (env['HOME'] case final home? when home.isNotEmpty) ...[
        p.join(home, 'bin', exe),
        p.join(home, '.local', 'bin', exe),
      ],
      '/usr/bin/tailscale',
      '/usr/local/bin/tailscale',
      '/snap/bin/tailscale',
      '/opt/homebrew/bin/tailscale',
      '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
      if (env['ProgramFiles'] case final programFiles?
          when programFiles.isNotEmpty)
        p.join(programFiles, 'Tailscale', exe),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Online peers on this tailnet, excluding this device.
  Future<List<TailscalePeer>> peers() async {
    final exe = exePath;
    if (exe == null) {
      throw const TailscaleUnavailableException(
          'tailscale was not found. Install Tailscale and sign in, or add a '
          'MagicDNS name by hand.');
    }
    final result = await (_runner?.call(exe, ['status', '--json']) ??
        Process.run(exe, ['status', '--json']));
    if (result.exitCode != 0) {
      throw TailscaleUnavailableException('${result.stderr}'.trim().isEmpty
          ? 'tailscale status failed (exit ${result.exitCode})'
          : '${result.stderr}'.trim());
    }
    return parseStatus(result.stdout as String? ?? '');
  }

  /// Parses `tailscale status --json`. Exposed for tests.
  static List<TailscalePeer> parseStatus(String text) {
    if (text.trim().isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      // Not JSON: an old CLI, or an error message from the daemon.
      return const [];
    }
    if (decoded is! Map<String, dynamic>) return const [];
    final peers = decoded['Peer'];
    if (peers is! Map<String, dynamic>) return const [];

    final result = <TailscalePeer>[];
    for (final entry in peers.entries) {
      final peer = entry.value;
      if (peer is! Map<String, dynamic>) continue;
      if (peer['Online'] == false) continue;
      final ips = peer['TailscaleIPs'];
      if (ips is! List) continue;
      final ip = ips.whereType<String>().firstWhere(
            (value) => !value.contains(':'),
            orElse: () => '',
          );
      if (ip.isEmpty) continue;

      final relay = _text(peer['Relay']);
      final curAddr = _text(peer['CurAddr']);
      final direct = curAddr != null && relay == null;
      final dnsName =
          (_text(peer['DNSName']) ?? '').replaceAll(RegExp(r'\.$'), '');
      final hostName = _text(peer['HostName']) ?? dnsName;
      result.add(TailscalePeer(
        nodeKey: entry.key,
        hostName: hostName,
        dnsName: dnsName,
        ip: ip,
        os: _text(peer['OS']),
        relay: relay,
        direct: direct,
        latencyMs: direct
            ? 10
            : relay != null
                ? 150
                : 50,
      ));
    }
    result.sort((a, b) => a.hostName.compareTo(b.hostName));
    return result;
  }

  /// RTT from `tailscale ping`. Null when the peer does not answer.
  Future<int?> pingMs(String host) async {
    final exe = exePath;
    if (exe == null) return null;
    try {
      final result = await (_runner
              ?.call(exe, ['ping', '-c', '1', '--timeout', '2s', host]) ??
          Process.run(exe, ['ping', '-c', '1', '--timeout', '2s', host])
              .timeout(const Duration(seconds: 4)));
      final match = RegExp(r'in ([\d.]+)\s*ms').firstMatch('${result.stdout}');
      return match == null ? null : double.parse(match.group(1)!).round();
    } catch (_) {
      return null;
    }
  }

  static String? _text(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}

class TailscaleUnavailableException implements Exception {
  final String message;
  const TailscaleUnavailableException(this.message);

  @override
  String toString() => message;
}
