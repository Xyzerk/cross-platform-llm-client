// Cluster transport, per platform.
//
// Android and iOS talk to the plugin's foreground service over a
// MethodChannel; Windows has no service host, so it runs
// `privatelm_rpc_worker.exe` and talks to the same native engine through the
// plugin DLL. Web has no cluster support at all.
//
// Callers only ever use [ClusterBackend.instance], so nothing outside this
// file (and its two implementations) imports a platform-specific cluster API.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:llama_flutter_android/llama_flutter_android.dart';

import 'cluster_backend_stub.dart'
    if (dart.library.io) 'cluster_backend_io.dart';

/// What this device can do in a cluster. Mirrors `LlamaCluster` so the rest of
/// the app doesn't care which platform it runs on.
abstract class ClusterBackend {
  /// The port llama.cpp's RPC server listens on, on every platform.
  static const int defaultPort = 50052;

  /// Test seam: while set, [instance] returns this instead of the platform
  /// backend. Tests set it to a fake and restore it to null in teardown.
  @visibleForTesting
  static ClusterBackend? overrideForTesting;

  /// The backend for the platform this build runs on.
  static ClusterBackend get instance =>
      overrideForTesting ?? createClusterBackend();

  /// Starts serving this device's CPU to a master.
  ///
  /// [advertiseIp] is the LAN address to put in mDNS advertisements; platforms
  /// with their own service host may ignore it.
  Future<void> startWorker({
    int port = defaultPort,
    int? threads,
    String? advertiseIp,
  });

  Future<void> stopWorker();

  Future<ClusterWorkerStatus> workerStatus();

  /// Keeps this device awake while it works for others.
  Future<void> setKeepScreenOn(bool on);

  /// Asks to exempt the app from battery optimization (Android). No-op
  /// elsewhere.
  Future<void> requestBatteryUnrestricted();

  /// Windows only: whether Windows Firewall already lets a master reach this
  /// device's worker. Null where there is no firewall to configure.
  Future<bool?> firewallReady();

  /// Windows only: asks Windows to allow the worker port (one UAC prompt).
  /// No-op elsewhere.
  Future<void> allowFirewall();

  Future<int> localFreeRamMb();

  /// This device's memory read speed in GB/s (~0.2 s to measure).
  Future<double> benchmark();

  /// Where the last model load put its weights: llama.cpp buffer name
  /// ("CPU_Mapped", "RPC0[host:port]", …) and size in MB.
  Future<List<({String name, double mb})>> lastLoadBuffers();

  /// Looks for workers on the local network for [timeout].
  Future<List<ClusterWorker>> discover({
    Duration timeout = const Duration(seconds: 4),
  });

  /// Whether something answers on [endpoint] ("host:port").
  Future<bool> probe(String endpoint);

  /// Uses [workers] for the next GGUF model load. Throws a PlatformException
  /// (code UNREACHABLE) if any worker doesn't answer. An empty list turns
  /// cluster mode off.
  Future<void> setCluster(
    List<ClusterWorker> workers, {
    List<double>? weights,
    double localWeight = 1.0,
  });

  Future<void> clear();
}
