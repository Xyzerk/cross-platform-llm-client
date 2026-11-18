// Desktop USB bridge over adb (Windows and Linux).
//
// A plain USB cable plus the user's `adb` is enough to put a phone in the
// cluster without tethering or root:
//
// - PC master + phone worker: `adb forward tcp:501xx tcp:50052` exposes the
//   phone's RPC worker on the PC's loopback; the phone is added as
//   127.0.0.1:501xx.
// - Phone master + PC worker: `adb reverse tcp:50100 tcp:50052` exposes the
//   PC's worker on the phone's loopback; the phone adds 127.0.0.1:50100.
//
// The bridge only exists while PrivateLM runs: mappings are persisted, removed
// on role change/device removal, and re-created on launch. The RPC protocol has
// no authentication, so the loopback indirection is also what keeps the worker
// off the LAN.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Thrown when adb is not installed or not usable.
class AdbUnavailableException implements Exception {
  final String message;
  const AdbUnavailableException(this.message);

  @override
  String toString() => message;
}

/// Thrown when an adb command fails.
class AdbCommandException implements Exception {
  final String message;
  const AdbCommandException(this.message);

  @override
  String toString() => message;
}

/// One entry of `adb devices -l`.
class AdbDevice {
  final String serial;

  /// `device`, `unauthorized`, `offline`, `no permissions`, …
  final String state;
  final String? model;
  final String? product;
  final String? device;

  const AdbDevice({
    required this.serial,
    required this.state,
    this.model,
    this.product,
    this.device,
  });

  bool get usable => state == 'device';

  /// A human name: "SM G973F", falling back to the serial.
  String get label {
    final raw = model ?? product ?? device ?? serial;
    return raw.replaceAll('_', ' ');
  }

  /// Why this device can't be used, or null when it can.
  String? get problem => switch (state) {
        'device' => null,
        'unauthorized' =>
          'Authorize this computer on the phone (Allow USB debugging).',
        'offline' => 'The phone is offline. Replug the cable and try again.',
        'no permissions' =>
          'No permission to open the USB device. On Linux, add your user to '
              'the plugdev group (or install the phone\'s udev rule).',
        _ =>
          'The phone is in "$state" state. Unlock it and enable USB debugging.',
      };

  @override
  String toString() => '$label ($serial, $state)';
}

/// One active adb mapping, persisted across launches so it can be removed.
class UsbBridge {
  final String serial;
  final int localPort;

  /// Forward: worker on the phone, master on this PC. Reverse: worker on this
  /// PC, master on the phone.
  final bool reverse;

  const UsbBridge({
    required this.serial,
    required this.localPort,
    required this.reverse,
  });

  factory UsbBridge.fromMap(Map<dynamic, dynamic> map) => UsbBridge(
        serial: map['serial'] as String,
        localPort: (map['localPort'] as num).toInt(),
        reverse: map['reverse'] as bool? ?? false,
      );

  Map<String, dynamic> toMap() =>
      {'serial': serial, 'localPort': localPort, 'reverse': reverse};

  @override
  String toString() => '${reverse ? 'reverse' : 'forward'} $serial:$localPort';
}

/// Runs adb; a single function so tests can fake the device list.
typedef AdbRunner = Future<ProcessResult> Function(
    String exe, List<String> args);

/// Locates and drives the user's adb. PrivateLM never bundles adb: it uses the
/// Android SDK the developer already has.
class UsbBridgeService {
  UsbBridgeService({String? adbPath, AdbRunner? runner})
      : _adbPath = adbPath,
        _runner = runner;

  final String? _adbPath;
  final AdbRunner? _runner;
  String? _resolved;

  /// The first local port a bridge chooses (one per phone).
  static const int firstPort = 50100;
  static const int workerPort = 50052;

  String? get adbPath {
    final path = _adbPath ?? (_resolved ??= findAdb());
    return path == null || path.isEmpty ? null : path;
  }

  bool get available => adbPath != null;

  /// Finds adb: PRIVATELM_ADB, PATH, then the Android SDK locations.
  static String? findAdb({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final exe = Platform.isWindows ? 'adb.exe' : 'adb';

    final override = env['PRIVATELM_ADB'];
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

    final roots = <String>[
      if (env['ANDROID_HOME'] case final home? when home.isNotEmpty) home,
      if (env['ANDROID_SDK_ROOT'] case final root? when root.isNotEmpty) root,
      if (env['HOME'] case final home? when home.isNotEmpty) ...[
        p.join(home, 'Android', 'Sdk'),
        p.join(home, 'Library', 'Android', 'sdk'),
      ],
      if (env['LOCALAPPDATA'] case final local? when local.isNotEmpty)
        p.join(local, 'Android', 'Sdk'),
      '/usr/lib/android-sdk',
      '/opt/android-sdk',
      '/usr/local/android-sdk',
    ];
    for (final root in roots) {
      final candidate = p.join(root, 'platform-tools', exe);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// `adb devices -l`, including phones that need authorizing.
  Future<List<AdbDevice>> devices() async {
    final result = await _run(['devices', '-l']);
    return parseDevices(result.stdout as String? ?? '');
  }

  /// Parses `adb devices -l` output. Exposed for tests.
  static List<AdbDevice> parseDevices(String output) {
    final line = RegExp(
        r'^(\S+)\s+(device|unauthorized|offline|bootloader|recovery|sideload|no permissions)\b(.*)$');
    final devices = <AdbDevice>[];
    for (final raw in const LineSplitter().convert(output)) {
      final text = raw.trim();
      if (text.isEmpty || text.startsWith('List of devices')) continue;
      final match = line.firstMatch(text);
      if (match == null) continue;
      final props = <String, String>{};
      for (final prop
          in RegExp(r'(\w+):(\S+)').allMatches(match.group(3) ?? '')) {
        props[prop.group(1)!] = prop.group(2)!;
      }
      devices.add(AdbDevice(
        serial: match.group(1)!,
        state: match.group(2)!,
        model: props['model'],
        product: props['product'],
        device: props['device'],
      ));
    }
    return devices;
  }

  /// Picks a free local port for a new phone, starting at [firstPort].
  static int allocatePort(Iterable<int> used) {
    final taken = used.toSet();
    var port = firstPort;
    while (taken.contains(port)) {
      port++;
    }
    return port;
  }

  /// Exposes a phone's worker on this PC. Call [removeBridge] to undo it.
  Future<void> forward(String serial, int localPort) => _run([
        '-s',
        serial,
        'forward',
        'tcp:$localPort',
        'tcp:$workerPort',
      ]);

  /// Exposes this PC's worker on the phone.
  Future<void> reverse(String serial, int localPort) => _run([
        '-s',
        serial,
        'reverse',
        'tcp:$localPort',
        'tcp:$workerPort',
      ]);

  Future<void> removeBridge(UsbBridge bridge) => _run([
        '-s',
        bridge.serial,
        bridge.reverse ? 'reverse' : 'forward',
        '--remove',
        'tcp:${bridge.localPort}',
      ]);

  /// Best effort: a missing phone or a restarted adb server is not an app
  /// error, and the next launch cleans the mapping up anyway.
  Future<void> removeBridgeQuietly(UsbBridge bridge) async {
    try {
      await removeBridge(bridge);
    } catch (_) {
      // Already gone.
    }
  }

  Future<ProcessResult> _run(List<String> args) async {
    final exe = adbPath;
    if (exe == null) {
      throw const AdbUnavailableException(
          'adb was not found. Install Android platform-tools and put adb on '
          'PATH, or set PRIVATELM_ADB to its location.');
    }
    final result = await (_runner?.call(exe, args) ?? Process.run(exe, args));
    if (result.exitCode != 0) {
      final stderrText = '${result.stderr}'.trim();
      final stdoutText = '${result.stdout}'.trim();
      throw AdbCommandException(stderrText.isNotEmpty
          ? stderrText
          : stdoutText.isNotEmpty
              ? stdoutText
              : 'adb ${args.first} failed (exit ${result.exitCode})');
    }
    return result;
  }
}
