// Web: there is no cluster. Kept so ClusterBackend.instance resolves on every
// build target; ClusterService.isSupported is false here, so nothing calls it.
import 'package:llama_flutter_android/llama_flutter_android.dart';

import 'cluster_backend.dart';

/// Web no-op. Every call fails loudly rather than pretending to work.
class UnsupportedClusterBackend implements ClusterBackend {
  const UnsupportedClusterBackend();

  Never _unsupported() =>
      throw UnsupportedError('Clusters need a native build of PrivateLM');

  @override
  Future<void> startWorker({
    int port = ClusterBackend.defaultPort,
    int? threads,
    String? advertiseIp,
  }) =>
      _unsupported();

  @override
  Future<void> stopWorker() => _unsupported();

  @override
  Future<ClusterWorkerStatus> workerStatus() async =>
      const ClusterWorkerStatus(state: 'stopped');

  @override
  Future<void> setKeepScreenOn(bool on) async {}

  @override
  Future<void> requestBatteryUnrestricted() async {}

  @override
  Future<bool?> firewallReady() async => null;

  @override
  Future<void> allowFirewall() async {}

  @override
  Future<int> localFreeRamMb() async => 0;

  @override
  Future<double> benchmark() async => 0;

  @override
  Future<List<({String name, double mb})>> lastLoadBuffers() async => const [];

  @override
  Future<List<ClusterWorker>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async =>
      const [];

  @override
  Future<bool> probe(String endpoint) async => false;

  @override
  Future<void> setCluster(
    List<ClusterWorker> workers, {
    List<double>? weights,
    double localWeight = 1.0,
  }) =>
      _unsupported();

  @override
  Future<void> clear() async {}
}

ClusterBackend createClusterBackend() => const UnsupportedClusterBackend();
