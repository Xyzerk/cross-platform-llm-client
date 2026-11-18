import 'package:flutter/services.dart';

/// How a worker is reached. The RPC protocol is the same TCP stream in every
/// case; the transport only changes pairing, discovery and UI copy.
enum ClusterTransport {
  /// Same Wi-Fi/LAN, or an address the user typed.
  lan('lan', 'Wi-Fi'),

  /// A phone reached through `adb forward` over a USB cable.
  usbAdb('usb', 'USB · adb'),

  /// A device on the phone's USB tethering network.
  usbTether('usbtether', 'USB tether'),

  /// A device on the same Tailscale tailnet.
  tailscale('tailscale', 'Tailscale');

  const ClusterTransport(this.wireName, this.label);

  /// Short name used in QR links (`t=usb`). Older builds ignore it.
  final String wireName;

  /// What the cluster screen shows next to the worker.
  final String label;

  static ClusterTransport parse(String? value) => switch (value) {
        'usb' || 'usbadb' => ClusterTransport.usbAdb,
        'usbtether' || 'tether' => ClusterTransport.usbTether,
        'tailscale' => ClusterTransport.tailscale,
        _ => ClusterTransport.lan,
      };
}

/// A device running as a cluster worker, found on the local network, scanned
/// from its QR code, added over USB, or added by hand.
class ClusterWorker {
  final String name;
  final String host;
  final int port;

  /// Free RAM the worker reported when it started, in MB (null if unknown).
  final int? ramMb;

  /// Memory read speed the worker measured, in GB/s (null if unknown).
  /// Token generation speed follows this closely.
  final double? bandwidth;
  final String? model;

  /// The worker device's lasting ID: finds it again when its IP changes.
  final String? id;

  /// How this worker is reached (defaults to LAN for saved/older links).
  final ClusterTransport transport;

  /// Network interface or adb serial it was paired through, when known.
  final String? iface;

  /// Round-trip latency in milliseconds, when the transport can measure it
  /// (Tailscale). Used to discount relayed peers when planning a split.
  final int? latencyMs;

  const ClusterWorker({
    required this.name,
    required this.host,
    required this.port,
    this.ramMb,
    this.bandwidth,
    this.model,
    this.id,
    this.transport = ClusterTransport.lan,
    this.iface,
    this.latencyMs,
  });

  /// `host:port`, with IPv6 hosts in brackets.
  static String formatEndpoint(String host, int port) {
    final bare = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    return bare.contains(':') ? '[$bare]:$port' : '$bare:$port';
  }

  String get endpoint => formatEndpoint(host, port);

  factory ClusterWorker.fromMap(Map<dynamic, dynamic> map) => ClusterWorker(
        name: map['name'] as String? ?? '${map['host']}',
        host: map['host'] as String,
        port: map['port'] as int,
        ramMb: (map['ramMb'] as num?)?.toInt(),
        bandwidth: (map['bandwidth'] as num?)?.toDouble(),
        model: map['model'] as String?,
        id: map['id'] as String?,
        transport: ClusterTransport.parse(map['transport'] as String?),
        iface: map['iface'] as String?,
        latencyMs: (map['latencyMs'] as num?)?.toInt(),
      );

  /// The same device at a new address.
  ClusterWorker movedTo(String host, int port) => ClusterWorker(
        name: name,
        host: host,
        port: port,
        ramMb: ramMb,
        bandwidth: bandwidth,
        model: model,
        id: id,
        transport: transport,
        iface: iface,
        latencyMs: latencyMs,
      );

  ClusterWorker withTransport(ClusterTransport transport, {String? iface}) =>
      ClusterWorker(
        name: name,
        host: host,
        port: port,
        ramMb: ramMb,
        bandwidth: bandwidth,
        model: model,
        id: id,
        transport: transport,
        iface: iface ?? this.iface,
        latencyMs: latencyMs,
      );

  Map<String, dynamic> toMap() => {
        'name': name,
        'host': host,
        'port': port,
        'ramMb': ramMb,
        'bandwidth': bandwidth,
        'model': model,
        'id': id,
        'transport': transport.wireName,
        'iface': iface,
        'latencyMs': latencyMs,
      };
}

/// State of this device's worker service.
class ClusterWorkerStatus {
  /// starting, running, stopped or error.
  final String state;
  final String? error;

  /// Address of the master using this worker right now, if any.
  final String? peer;

  /// Memory this worker holds, mostly the master's model layers.
  final int heldMb;
  final int ramMb;
  final double bandwidth;

  /// Android is throttling the worker (slow cores, low CPU share).
  final bool throttled;

  /// The app is exempt from battery optimization (Android).
  final bool batteryUnrestricted;

  /// This device's lasting worker ID (put in its QR code).
  final String? id;

  const ClusterWorkerStatus({
    required this.state,
    this.error,
    this.peer,
    this.heldMb = 0,
    this.ramMb = 0,
    this.bandwidth = 0,
    this.throttled = false,
    this.batteryUnrestricted = true,
    this.id,
  });

  /// Reads the map the platform channel returns, and the status JSON the
  /// desktop worker writes. Empty strings count as absent.
  factory ClusterWorkerStatus.fromMap(Map<String, dynamic> m) {
    String? text(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    final state = m['state'] as String? ?? 'stopped';
    final error = text(m['error']);
    return ClusterWorkerStatus(
      // A worker that reported a reason never got as far as running.
      state: error != null && state != 'running' ? 'error' : state,
      error: error,
      peer: text(m['peer']),
      heldMb: (m['heldMb'] as num?)?.toInt() ?? 0,
      ramMb: (m['ramMb'] as num?)?.toInt() ?? 0,
      bandwidth: (m['bandwidth'] as num?)?.toDouble() ?? 0,
      throttled: m['throttled'] as bool? ?? false,
      batteryUnrestricted: m['batteryUnrestricted'] as bool? ?? true,
      id: text(m['id']),
    );
  }

  bool get running => state == 'running';
  bool get starting => state == 'starting';
}

/// AI cluster: one device (the master) runs a model whose layers are spread
/// across other devices (workers) over TCP, using llama.cpp's RPC backend.
/// Android, iOS (worker only), Windows and Linux.
///
/// The RPC protocol has no authentication: only run workers on a network you
/// trust.
class LlamaCluster {
  static const _channel = MethodChannel('llama_flutter_android/cluster');
  static const defaultPort = 50052;

  /// Starts serving this device's CPU to a master (Android/iOS: in a
  /// foreground service that keeps running in the background).
  ///
  /// [host] binds the RPC listener to one address; null listens everywhere.
  static Future<void> startWorker(
          {int port = defaultPort, int? threads, String? host}) =>
      _channel.invokeMethod(
          'startWorker', {'port': port, 'threads': threads, 'host': host});

  static Future<void> stopWorker() => _channel.invokeMethod('stopWorker');

  static Future<ClusterWorkerStatus> workerStatus() async {
    final m =
        await _channel.invokeMapMethod<String, dynamic>('workerStatus') ?? {};
    return ClusterWorkerStatus.fromMap(m);
  }

  /// Android: asks to exempt the app from battery optimization, so a busy
  /// worker isn't moved to slow cores. No-op if already exempt.
  static Future<void> requestBatteryUnrestricted() =>
      _channel.invokeMethod('requestBatteryUnrestricted');

  /// Keeps this device's screen on (a worker runs at full speed only while
  /// PrivateLM is on screen).
  static Future<void> setKeepScreenOn(bool on) =>
      _channel.invokeMethod('setKeepScreenOn', {'on': on});

  static Future<int> localFreeRamMb() async =>
      await _channel.invokeMethod<int>('localFreeRamMb') ?? 0;

  /// This device's memory read speed in GB/s (~0.2 s to measure).
  static Future<double> benchmark() async =>
      await _channel.invokeMethod<double>('benchmark') ?? 0;

  /// Where the last model load put its weights: llama.cpp buffer name
  /// ("CPU_Mapped", "RPC0[host:port]", …) and size in MB.
  static Future<List<({String name, double mb})>> lastLoadBuffers() async {
    final list = await _channel
        .invokeListMethod<Map<dynamic, dynamic>>('lastLoadBuffers');
    return [
      for (final m in list ?? const [])
        (name: m['name'] as String, mb: (m['mb'] as num).toDouble()),
    ];
  }

  /// Looks for workers on the local network for [timeout].
  static Future<List<ClusterWorker>> discover(
      {Duration timeout = const Duration(seconds: 4)}) async {
    final list = await _channel.invokeListMethod<Map<dynamic, dynamic>>(
        'discover', {'timeoutMs': timeout.inMilliseconds});
    return (list ?? const []).map(ClusterWorker.fromMap).toList();
  }

  /// Whether something answers on [endpoint] ("host:port").
  static Future<bool> probe(String endpoint) async =>
      await _channel.invokeMethod<bool>('probe', {'endpoint': endpoint}) ??
      false;

  /// Uses [workers] for the next GGUF model load. Layers are split by
  /// [weights] (one per worker, e.g. MB to hold), with this device keeping a
  /// share by [localWeight]. Throws a [PlatformException] (code UNREACHABLE)
  /// if any worker doesn't answer. An empty list turns cluster mode off.
  static Future<void> setCluster(
    List<ClusterWorker> workers, {
    List<double>? weights,
    double localWeight = 1.0,
  }) =>
      _channel.invokeMethod('setCluster', {
        'endpoints': [for (final w in workers) w.endpoint],
        'weights': weights ?? List.filled(workers.length, 1.0),
        'localWeight': localWeight,
      });

  static Future<void> clear() => setCluster(const []);
}
