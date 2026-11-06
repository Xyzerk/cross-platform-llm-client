// Android/iOS cluster transport: the plugin's foreground service, reached over
// its MethodChannel. Selected by the conditional import in cluster_backend.dart
// whenever dart:io is available (i.e. everything except web).
import 'dart:io' show Platform;

import 'package:llama_flutter_android/llama_flutter_android.dart';

import 'cluster_backend.dart';
import 'cluster_windows_backend.dart';

/// Android/iOS: everything lives in the plugin, which hosts the RPC worker in
/// a foreground service and plans the split natively.
class LlamaClusterBackend implements ClusterBackend {
  const LlamaClusterBackend();

  @override
  Future<void> startWorker({
    int port = ClusterBackend.defaultPort,
    int? threads,
    String? advertiseIp,
  }) =>
      LlamaCluster.startWorker(port: port, threads: threads);

  @override
  Future<void> stopWorker() => LlamaCluster.stopWorker();

  @override
  Future<ClusterWorkerStatus> workerStatus() => LlamaCluster.workerStatus();

  @override
  Future<void> setKeepScreenOn(bool on) => LlamaCluster.setKeepScreenOn(on);

  @override
  Future<void> requestBatteryUnrestricted() =>
      LlamaCluster.requestBatteryUnrestricted();

  @override
  Future<bool?> firewallReady() async => null;

  @override
  Future<void> allowFirewall() async {}

  @override
  Future<int> localFreeRamMb() => LlamaCluster.localFreeRamMb();

  @override
  Future<double> benchmark() => LlamaCluster.benchmark();

  @override
  Future<List<({String name, double mb})>> lastLoadBuffers() =>
      LlamaCluster.lastLoadBuffers();

  @override
  Future<List<ClusterWorker>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) =>
      LlamaCluster.discover(timeout: timeout);

  @override
  Future<bool> probe(String endpoint) => LlamaCluster.probe(endpoint);

  @override
  Future<void> setCluster(
    List<ClusterWorker> workers, {
    List<double>? weights,
    double localWeight = 1.0,
  }) =>
      LlamaCluster.setCluster(workers, weights: weights, localWeight: localWeight);

  @override
  Future<void> clear() => LlamaCluster.clear();
}

/// One instance per process: the Windows backend owns a child process, so it
/// must not be recreated on every access.
final ClusterBackend _instance =
    Platform.isWindows ? WindowsClusterBackend() : const LlamaClusterBackend();

ClusterBackend createClusterBackend() => _instance;
