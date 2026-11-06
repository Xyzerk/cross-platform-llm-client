// Windows cluster transport.
//
// Android and iOS host the RPC worker inside the app's own process tree (a
// foreground service). Windows can't: ggml_backend_rpc_start_server blocks
// forever and has no stop call, so the worker lives in
// `privatelm_rpc_worker.exe` and this class just starts, watches and kills it.
//
// The worker writes a small JSON status file every second (it can't talk to
// Dart), which is what workerStatus() reads. Everything else goes through the
// plugin DLL, the same native engine the app runs models with.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import 'cluster_backend.dart';
import 'hive_service.dart';

/// Windows: runs this PC as a cluster worker, and can plan a load across
/// workers the way the Android backend does.
class WindowsClusterBackend implements ClusterBackend {
  WindowsClusterBackend({String? workerExe}) : _workerExeOverride = workerExe;

  /// Test/developer override for the worker binary.
  final String? _workerExeOverride;

  static const _exeName = 'privatelm_rpc_worker.exe';
  static const _dllName = 'llama_flutter_android.dll';

  /// The DNS-SD type every PrivateLM worker advertises.
  static const _serviceType = '_privatelm._tcp.local';

  /// The Windows Firewall rule the "Allow" button creates.
  static const _firewallRule = 'PrivateLM Cluster';

  /// How long the worker may take to bind its port and report "running".
  static const _startTimeout = Duration(seconds: 10);

  /// The worker rewrites its status file every second. An older one belongs to
  /// a worker that died (or to a previous app session).
  static const _staleAfter = Duration(seconds: 6);

  int? _pid;
  Process? _process;
  Pointer<Void> _job = nullptr;
  bool _keepAwake = false;
  String? _fallbackId;

  // ── Worker ─────────────────────────────────────────────────────────────

  @override
  Future<void> startWorker({
    int port = ClusterBackend.defaultPort,
    int? threads,
    String? advertiseIp,
  }) async {
    if (await _isRunning()) return;

    final exe = _workerExe();
    if (exe == null) {
      throw Exception('$_exeName is missing next to PrivateLM. Reinstall the '
          'app, or run a full `flutter build windows`.');
    }

    Directory(_cacheDir).createSync(recursive: true);
    // A file left by a dead worker would look alive to the status poller.
    _deleteStatusFile();

    final args = <String>[
      '--host', '0.0.0.0',
      '--port', '$port',
      // 0 lets the worker pick one thread per core, capped at 16.
      '--threads', '${threads ?? 0}',
      '--cache-dir', _cacheDir,
      '--status-file', _statusPath,
      '--id', await _workerId(),
      '--model', Platform.localHostname,
      '--parent-pid', '$pid',
      if (advertiseIp != null && advertiseIp.isNotEmpty) ...[
        '--advertise-ip', advertiseIp,
      ],
    ];

    final process =
        await Process.start(exe, args, mode: ProcessStartMode.detached);
    _process = process;
    _pid = process.pid;
    _assignToJob(process.pid);

    final deadline = DateTime.now().add(_startTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final file = await _readWorkerFile();
      if (file == null) continue;
      final error = _text(file.json['error']);
      if (_stateOf(file.json) == 'running' && error == null) return;
      if (error != null) {
        // Leave the status file in place: it is what the UI shows (and it
        // keeps the OS message) until the next start.
        await _kill();
        throw Exception(error);
      }
    }

    await _kill();
    throw Exception('The cluster worker did not start within '
        '${_startTimeout.inSeconds} seconds. Allow PrivateLM through Windows '
        'Firewall, then try again.');
  }

  @override
  Future<void> stopWorker() async {
    await _kill();
    _deleteStatusFile();
  }

  /// Ends the worker process and its job object, keeping the status file.
  Future<void> _kill() async {
    final process = _process;
    final pid = _pid ?? _pidFromStatus();
    _process = null;
    _pid = null;
    try {
      process?.kill();
    } catch (_) {
      // Already gone.
    }
    if (pid != null) {
      try {
        Process.killPid(pid);
      } catch (_) {
        // Already gone.
      }
      // Wait for the port to be released before a restart can claim it.
      for (var i = 0; i < 20 && _pidAlive(pid); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    _releaseJob();
  }

  @override
  Future<ClusterWorkerStatus> workerStatus() async {
    final file = await _readWorkerFile();
    if (file == null) return const ClusterWorkerStatus(state: 'stopped');
    final state = _stateOf(file.json);
    // An error is terminal until the next start, so it never goes stale; a
    // "running" file nobody updates means the worker died.
    if (state != 'error' &&
        DateTime.now().difference(file.modified) >= _staleAfter) {
      return const ClusterWorkerStatus(state: 'stopped');
    }
    final error = _text(file.json['error']);
    return ClusterWorkerStatus(
      // A worker that reported a reason never got as far as running.
      state: error != null && state != 'running' ? 'error' : state,
      error: error,
      peer: _text(file.json['peer']),
      heldMb: (file.json['heldMb'] as num?)?.toInt() ?? 0,
      ramMb: (file.json['ramMb'] as num?)?.toInt() ?? 0,
      bandwidth: (file.json['bandwidth'] as num?)?.toDouble() ?? 0,
      id: _text(file.json['id']),
    );
  }

  /// A PC has no battery optimization to opt out of.
  @override
  Future<void> requestBatteryUnrestricted() async {}

  /// Windows Firewall blocks inbound connections by default, which is the
  /// most common reason a master can't reach this PC. The rule is named after
  /// the app so the check is cheap and repeatable.
  @override
  Future<bool?> firewallReady() async {
    if (!Platform.isWindows) return null;
    try {
      final result = await Process.run(
          'netsh', ['advfirewall', 'firewall', 'show', 'rule', 'name=$_firewallRule']);
      return result.exitCode == 0;
    } catch (_) {
      // Can't tell: don't nag with a warning that may be wrong.
      return null;
    }
  }

  @override
  Future<void> allowFirewall() async {
    if (!Platform.isWindows) return;
    // netsh needs elevation; PowerShell shows the UAC prompt and waits, so
    // the caller can re-check the rule afterwards.
    await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Start-Process -FilePath netsh -Verb RunAs -Wait '
          '-ArgumentList \'advfirewall firewall add rule name="$_firewallRule" '
          'dir=in action=allow protocol=TCP '
          'localport=${ClusterBackend.defaultPort}\'',
    ]);
  }

  /// Keeps the machine (and so the worker) from idling while it serves a
  /// master. ES_CONTINUOUS makes the flag stick until it is cleared.
  @override
  Future<void> setKeepScreenOn(bool on) async {
    if (_keepAwake == on) return;
    _keepAwake = on;
    final kernel = _kernel32;
    if (kernel == null) return;
    kernel.setThreadExecutionState(on ? 0x80000001 : 0x80000000);
  }

  // ── Master: this PC's own numbers ──────────────────────────────────────

  @override
  Future<int> localFreeRamMb() async => _engine.freeRamMb();

  @override
  Future<double> benchmark() async => _engine.benchmark();

  @override
  Future<List<({String name, double mb})>> lastLoadBuffers() async {
    final pointer = _engine.lastLoadBuffers();
    if (pointer == nullptr) return const [];
    try {
      final buffers = <({String name, double mb})>[];
      for (final line in const LineSplitter().convert(pointer.toDartString())) {
        final tab = line.lastIndexOf('\t');
        if (tab <= 0) continue;
        final mb = double.tryParse(line.substring(tab + 1));
        if (mb == null) continue;
        buffers.add((name: line.substring(0, tab), mb: mb));
      }
      return buffers;
    } finally {
      _engine.freeString(pointer);
    }
  }

  @override
  Future<List<ClusterWorker>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final client = MDnsClient();
    final names = <String>{};
    StreamSubscription<PtrResourceRecord>? pointers;
    try {
      await client.start();
      pointers = client
          .lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer(_serviceType))
          .listen((record) => names.add(record.domainName));
      await Future<void>.delayed(timeout);
      await pointers.cancel();
      pointers = null;

      final found = <ClusterWorker>[];
      final seen = <String>{};
      for (final name in names) {
        final worker = await _resolve(client, name);
        if (worker == null) continue;
        if (!seen.add(worker.id ?? worker.endpoint)) continue;
        found.add(worker);
      }
      return found;
    } catch (_) {
      // Discovery is a convenience; pairing by IP always works.
      return const [];
    } finally {
      await pointers?.cancel();
      try {
        client.stop();
      } catch (_) {
        // Failed before it finished starting.
      }
    }
  }

  @override
  Future<bool> probe(String endpoint) async {
    final colon = endpoint.lastIndexOf(':');
    if (colon <= 0) return false;
    final port = int.tryParse(endpoint.substring(colon + 1));
    if (port == null) return false;
    try {
      final socket = await Socket.connect(endpoint.substring(0, colon), port,
          timeout: const Duration(seconds: 2));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> setCluster(
    List<ClusterWorker> workers, {
    List<double>? weights,
    double localWeight = 1.0,
  }) async {
    if (workers.isEmpty) {
      _engine.setCluster(nullptr, nullptr, 0, localWeight);
      return;
    }

    // llama.cpp aborts the whole app on an unreachable worker, so refuse the
    // cluster unless every worker answers right now (same rule as Android).
    final unreachable = <String>[];
    for (final worker in workers) {
      if (!await probe(worker.endpoint)) unreachable.add(worker.endpoint);
    }
    if (unreachable.isNotEmpty) {
      throw PlatformException(
        code: 'UNREACHABLE',
        message: "Can't reach ${unreachable.join(', ')}",
      );
    }

    final count = workers.length;
    final endpoints = calloc<Pointer<Utf8>>(count);
    final shares = calloc<Float>(count);
    try {
      for (var i = 0; i < count; i++) {
        endpoints[i] = workers[i].endpoint.toNativeUtf8();
        final weight = weights != null && i < weights.length ? weights[i] : 1.0;
        shares[i] = weight > 0 ? weight : 1.0;
      }
      _engine.setCluster(endpoints, shares, count, localWeight);
    } finally {
      for (var i = 0; i < count; i++) {
        if (endpoints[i] != nullptr) calloc.free(endpoints[i]);
      }
      calloc.free(endpoints);
      calloc.free(shares);
    }
  }

  @override
  Future<void> clear() => setCluster(const []);

  // ── Files ──────────────────────────────────────────────────────────────

  String get _baseDir {
    final local = Platform.environment['LOCALAPPDATA'];
    final root = local == null || local.isEmpty
        ? Directory.systemTemp.path
        : p.join(local, 'PrivateLM');
    return p.join(root, 'cluster');
  }

  String get _statusPath => p.join(_baseDir, 'worker.json');

  String get _cacheDir => p.join(_baseDir, 'cache');

  String? _workerExe() {
    if (_workerExeOverride != null) return _workerExeOverride;
    final override = Platform.environment['PRIVATELM_TEST_WORKER'];
    if (override != null && override.isNotEmpty) return override;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    for (final dir in [exeDir, Directory.current.path]) {
      final candidate = p.join(dir, _exeName);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  Future<_WorkerFile?> _readWorkerFile() async {
    try {
      final file = File(_statusPath);
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      if (text.trim().isEmpty) return null;
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return null;
      return _WorkerFile(json, await file.lastModified());
    } catch (_) {
      // Replaced while reading: the next poll gets the whole document.
      return null;
    }
  }

  Future<bool> _isRunning() async {
    final file = await _readWorkerFile();
    if (file == null || _stateOf(file.json) != 'running') return false;
    return DateTime.now().difference(file.modified) < _staleAfter;
  }

  int? _pidFromStatus() {
    try {
      final file = File(_statusPath);
      if (!file.existsSync()) return null;
      // Only trust a pid the worker itself is still refreshing: a stale one
      // may have been recycled by an unrelated process.
      if (DateTime.now().difference(file.lastModifiedSync()) >= _staleAfter) {
        return null;
      }
      final json = jsonDecode(file.readAsStringSync());
      if (json is Map<String, dynamic> && json['state'] == 'running') {
        return (json['pid'] as num?)?.toInt();
      }
    } catch (_) {
      // No file, or a worker that already exited.
    }
    return null;
  }

  void _deleteStatusFile() {
    try {
      final file = File(_statusPath);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // Locked for a moment by a dying worker; the staleness check covers it.
    }
  }

  static String _stateOf(Map<String, dynamic> json) =>
      json['state'] as String? ?? 'stopped';

  static String? _text(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  Future<String> _workerId() async {
    if (Get.isRegistered<HiveService>()) {
      final hive = Get.find<HiveService>();
      final saved = hive.getSetting<String>(AppConstants.keyClusterWorkerId);
      if (saved != null && saved.isNotEmpty) return saved;
      final id = const Uuid().v4();
      await hive.setSetting(AppConstants.keyClusterWorkerId, id);
      return id;
    }
    // No Hive (tests): still give the worker a stable ID for this process.
    return _fallbackId ??= const Uuid().v4();
  }

  // ── mDNS browse ────────────────────────────────────────────────────────

  Future<ClusterWorker?> _resolve(MDnsClient client, String name) async {
    final SrvResourceRecord service;
    try {
      service = await client
          .lookup<SrvResourceRecord>(ResourceRecordQuery.service(name))
          .first
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }

    var host = service.target;
    try {
      final address = await client
          .lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(service.target))
          .first
          .timeout(const Duration(seconds: 2));
      host = address.address.address;
    } catch (_) {
      // Keep the host name: probe() still has a chance to resolve it.
    }

    final txt = <String, String>{};
    try {
      final record = await client
          .lookup<TxtResourceRecord>(ResourceRecordQuery.text(name))
          .first
          .timeout(const Duration(seconds: 2));
      for (final line in const LineSplitter().convert(record.text)) {
        final eq = line.indexOf('=');
        if (eq > 0) txt[line.substring(0, eq)] = line.substring(eq + 1);
      }
    } catch (_) {
      // TXT is optional: it only carries the worker's numbers.
    }
    // A worker from a different llama.cpp build can't serve this one's layers.
    if (txt['v'] != null && txt['v'] != 'rpc7') return null;

    const suffix = '.$_serviceType';
    final instance =
        name.endsWith(suffix) ? name.substring(0, name.length - suffix.length) : name;
    return ClusterWorker(
      name: instance,
      host: host,
      port: service.port,
      ramMb: int.tryParse(txt['ram'] ?? ''),
      bandwidth: double.tryParse(txt['bw'] ?? ''),
      model: txt['model'] ?? instance,
      id: txt['id'],
    );
  }

  // ── Native helpers ─────────────────────────────────────────────────────

  _Engine? _engineInstance;
  _Engine get _engine => _engineInstance ??= _Engine.open();

  _Kernel32? _kernel32Instance;
  _Kernel32? get _kernel32 {
    if (!Platform.isWindows) return null;
    return _kernel32Instance ??= _Kernel32(DynamicLibrary.open('kernel32.dll'));
  }

  /// Puts the worker in a job object that kills it when this app exits. Best
  /// effort: the worker's own `--parent-pid` watchdog covers the rest.
  void _assignToJob(int childPid) {
    final kernel = _kernel32;
    if (kernel == null) return;
    try {
      if (_job == nullptr) {
        final job = kernel.createJobObject(nullptr, nullptr);
        if (job == nullptr) return;
        final info = calloc<_JobExtendedLimit>();
        try {
          // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
          info.ref.basicLimitInformation.limitFlags = 0x2000;
          final ok = kernel.setInformationJobObject(
              job, 9 /* JobObjectExtendedLimitInformation */, info.cast(),
              sizeOf<_JobExtendedLimit>());
          if (ok == 0) {
            kernel.closeHandle(job);
            return;
          }
        } finally {
          calloc.free(info);
        }
        _job = job;
      }

      // PROCESS_SET_QUOTA | PROCESS_TERMINATE
      final handle = kernel.openProcess(0x0101, 0, childPid);
      if (handle == nullptr) return;
      kernel.assignProcessToJobObject(_job, handle);
      kernel.closeHandle(handle);
    } catch (_) {
      // No job object: the parent-pid watchdog still stops the worker.
    }
  }

  void _releaseJob() {
    if (_job == nullptr) return;
    _kernel32?.closeHandle(_job);
    _job = nullptr;
  }

  bool _pidAlive(int childPid) {
    final kernel = _kernel32;
    if (kernel == null) return false;
    final handle = kernel.openProcess(0x00100000 /* SYNCHRONIZE */, 0, childPid);
    if (handle == nullptr) return false;
    final result = kernel.waitForSingleObject(handle, 0);
    kernel.closeHandle(handle);
    return result == 0x00000102; // WAIT_TIMEOUT
  }
}

/// One poll of the worker's status file.
class _WorkerFile {
  const _WorkerFile(this.json, this.modified);

  final Map<String, dynamic> json;
  final DateTime modified;
}

/// The parts of `llama_flutter_android.dll` the cluster needs.
class _Engine {
  _Engine(this._library);

  factory _Engine.open() {
    final override = Platform.environment['PRIVATELM_TEST_DLL'];
    if (override != null && override.isNotEmpty) {
      return _Engine(DynamicLibrary.open(override));
    }
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = p.join(exeDir, WindowsClusterBackend._dllName);
    return _Engine(DynamicLibrary.open(
        File(bundled).existsSync() ? bundled : WindowsClusterBackend._dllName));
  }

  final DynamicLibrary _library;

  late final int Function() freeRamMb =
      _library.lookupFunction<Int32 Function(), int Function()>(
          'plm_free_ram_mb');

  late final double Function() benchmark =
      _library.lookupFunction<Double Function(), double Function()>(
          'plm_benchmark_bandwidth');

  late final Pointer<Utf8> Function() lastLoadBuffers =
      _library.lookupFunction<Pointer<Utf8> Function(),
          Pointer<Utf8> Function()>('plm_last_load_buffers');

  late final void Function(Pointer<Utf8>) freeString =
      _library.lookupFunction<Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)>('plm_free_string');

  late final void Function(
      Pointer<Pointer<Utf8>>, Pointer<Float>, int, double) setCluster =
      _library.lookupFunction<
          Void Function(Pointer<Pointer<Utf8>>, Pointer<Float>, Int32, Float),
          void Function(Pointer<Pointer<Utf8>>, Pointer<Float>, int,
              double)>('plm_set_cluster');
}

/// The three kernel32 calls the cluster needs: a job object to kill the worker
/// with the app, and liveness/awake helpers.
class _Kernel32 {
  _Kernel32(this._library);

  final DynamicLibrary _library;

  late final Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>)
      createJobObject = _library.lookupFunction<
          Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>),
          Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>)>(
      'CreateJobObjectW');

  late final int Function(Pointer<Void>, int, Pointer<Void>, int)
      setInformationJobObject = _library.lookupFunction<
          Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Int32),
          int Function(Pointer<Void>, int, Pointer<Void>,
              int)>('SetInformationJobObject');

  late final int Function(Pointer<Void>, Pointer<Void>)
      assignProcessToJobObject = _library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Void>),
          int Function(Pointer<Void>, Pointer<Void>)>(
      'AssignProcessToJobObject');

  late final Pointer<Void> Function(int, int, int) openProcess =
      _library.lookupFunction<Pointer<Void> Function(Int32, Int32, Int32),
          Pointer<Void> Function(int, int, int)>('OpenProcess');

  late final int Function(Pointer<Void>, int) waitForSingleObject =
      _library.lookupFunction<Int32 Function(Pointer<Void>, Int32),
          int Function(Pointer<Void>, int)>('WaitForSingleObject');

  late final int Function(Pointer<Void>) closeHandle =
      _library.lookupFunction<Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)>('CloseHandle');

  late final int Function(int) setThreadExecutionState =
      _library.lookupFunction<Uint32 Function(Uint32), int Function(int)>(
          'SetThreadExecutionState');
}

// JOBOBJECT_BASIC_LIMIT_INFORMATION / JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
// exactly as winnt.h lays them out on 64-bit Windows.
final class _JobBasicLimit extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;

  @Int64()
  external int perJobUserTimeLimit;

  @Uint32()
  external int limitFlags;

  @UintPtr()
  external int minimumWorkingSetSize;

  @UintPtr()
  external int maximumWorkingSetSize;

  @Uint32()
  external int activeProcessLimit;

  @UintPtr()
  external int affinity;

  @Uint32()
  external int priorityClass;

  @Uint32()
  external int schedulingClass;
}

final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;

  @Uint64()
  external int writeOperationCount;

  @Uint64()
  external int otherOperationCount;

  @Uint64()
  external int readTransferCount;

  @Uint64()
  external int writeTransferCount;

  @Uint64()
  external int otherTransferCount;
}

final class _JobExtendedLimit extends Struct {
  external _JobBasicLimit basicLimitInformation;

  external _IoCounters ioInfo;

  @UintPtr()
  external int processMemoryLimit;

  @UintPtr()
  external int jobMemoryLimit;

  @UintPtr()
  external int peakProcessMemoryUsed;

  @UintPtr()
  external int peakJobMemoryUsed;
}
