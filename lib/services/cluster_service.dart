import 'dart:async';
import 'dart:io' show File, InternetAddressType, NetworkInterface, Platform;
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../core/ui.dart';
import 'app_log_service.dart';
import 'cluster_backend.dart';
import 'hive_service.dart';

/// What this phone does in a phone cluster.
enum ClusterRole {
  off,

  /// Runs the model, with part of it on the workers.
  master,

  /// Lends its processor and memory to a master.
  worker,
}

/// One phone's part of the loaded model.
class ClusterShare {
  final String name;
  final double mb;
  final bool isThisPhone;
  const ClusterShare(this.name, this.mb, {this.isThisPhone = false});
}

/// A phone the master can put layers on, for planning a load.
class _Phone {
  final ClusterWorker? worker; // null: the master itself
  final double capacityMb;
  final double speed; // GB/s
  double assignedMb = 0;
  _Phone(this.worker, this.capacityMb, this.speed);
}

/// Phone cluster: spread a GGUF model across phones on the same Wi-Fi.
/// The master runs the model; workers hold part of its layers.
class ClusterService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  /// Android and iOS run the worker in the app; Windows runs a separate
  /// worker process.
  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isWindows);

  /// Running a model across workers is Android and Windows for now; iOS
  /// devices can be workers (their GPU serves a master's layers).
  static bool get canBeMaster =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows);

  /// iOS can't stop the worker without closing the app.
  static bool get workerStopsWithApp => !kIsWeb && Platform.isIOS;

  /// Windows has no camera scanner plugin; pairing there is by IP or link.
  static bool get canScanQr =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// A PC build: no camera, no battery optimization, no orientation lock.
  static bool get isDesktop => !kIsWeb && Platform.isWindows;

  /// QR codes a worker shows: privatelm://worker?host=…&port=…
  static const _qrScheme = 'privatelm';

  /// Speed assumed for workers paired before they reported one (GB/s).
  static const _unknownSpeed = 4.0;

  /// Workers the master can use on its next GGUF load.
  final workers = <ClusterWorker>[].obs;

  /// Master mode: use [workers] when loading GGUF models.
  final enabled = false.obs;

  final found = <ClusterWorker>[].obs;
  final isScanning = false.obs;

  /// This phone's worker service.
  final worker = const ClusterWorkerStatus(state: 'stopped').obs;
  final _workerRequested = false.obs;

  /// The API server is running (other devices, e.g. a PC, use the model).
  final serving = false.obs;

  /// This phone's Wi-Fi address, or null when it isn't on Wi-Fi.
  final wifiAddress = RxnString();

  /// Interfaces a cluster could run on (a PC usually has more than one).
  final interfaces = <({String name, String address})>[].obs;

  /// Windows: whether Windows Firewall already allows the worker port. Null
  /// where there is no firewall to configure.
  final firewallReady = RxnBool();

  /// How the loaded model is spread across phones; empty when it isn't.
  final split = <ClusterShare>[].obs;

  String deviceName = '';
  double? _localSpeed;
  Timer? _statusTimer;

  ClusterRole get role => _workerRequested.value || worker.value.running
      ? ClusterRole.worker
      : enabled.value
          ? ClusterRole.master
          : ClusterRole.off;

  /// "Pixel 8 72% · POCO F1 28%", or null when the model isn't split.
  String? get splitSummary {
    final total = split.fold<double>(0, (a, s) => a + s.mb);
    if (split.length < 2 || total <= 0) return null;
    return split.map((s) => '${s.name} ${(s.mb / total * 100).round()}%').join(' · ');
  }

  @override
  void onInit() {
    super.onInit();
    enabled.value = _hive.getSetting<bool>(AppConstants.keyClusterEnabled) ?? false;
    final saved = _hive.getSetting<List>(AppConstants.keyClusterWorkers) ?? const [];
    workers.assignAll(saved.whereType<Map>().map(ClusterWorker.fromMap));
    if (isSupported) {
      if (Platform.isWindows) {
        deviceName = Platform.localHostname;
      } else if (Platform.isIOS) {
        DeviceInfoPlugin().iosInfo.then((info) => deviceName = info.modelName);
      } else {
        DeviceInfoPlugin().androidInfo.then((info) => deviceName = info.model);
      }
      refreshWorkerStatus().then((_) {
        if (worker.value.running) _watchWorker();
      });
      // A worker runs at full speed only while PrivateLM is on screen (it
      // borrows the app's priority), so keep the screen on while sharing.
      ever<ClusterWorkerStatus>(worker, (_) => _updateKeepScreenOn());
      ever<bool>(serving, (_) => _updateKeepScreenOn());
      refreshWifiAddress();
      refreshFirewall();
    }
  }

  @override
  void onClose() {
    _statusTimer?.cancel();
    super.onClose();
  }

  /// Android throttles a phone whose screen is off (slow cores, low CPU
  /// share), so keep it on while this device works for others: as a worker,
  /// or serving the model over the network.
  bool? _screenKeptOn;
  void _updateKeepScreenOn() {
    final s = worker.value;
    final on = s.running || s.starting || serving.value;
    if (on == _screenKeptOn) return;
    _screenKeptOn = on;
    _backend.setKeepScreenOn(on).catchError((_) {});
  }

  Future<void> setRole(ClusterRole next) async {
    if (next == role) return;
    if (next != ClusterRole.worker && role == ClusterRole.worker) {
      if (workerStopsWithApp) {
        showToast('Still sharing', 'Close PrivateLM to stop sharing this device.');
        return;
      }
      await stopWorker();
    }
    await _setEnabled(next == ClusterRole.master);
    if (next == ClusterRole.worker) await startWorker();
    await refreshWifiAddress();
  }

  // ── Worker ─────────────────────────────────────────────────────────────

  /// What the master scans to add this phone, once the worker is running.
  String? get workerQrData {
    final host = wifiAddress.value;
    final status = worker.value;
    if (host == null || !status.running) return null;
    return Uri(scheme: _qrScheme, host: 'worker', queryParameters: {
      'host': host,
      'port': '${ClusterBackend.defaultPort}',
      if (deviceName.isNotEmpty) 'name': deviceName,
      if (status.ramMb > 0) 'ram': '${status.ramMb}',
      if (status.bandwidth > 0) 'bw': status.bandwidth.toStringAsFixed(1),
      if (status.id != null) 'id': status.id!,
    }).toString();
  }

  Future<void> startWorker() async {
    if (Platform.isAndroid) {
      // Unrestricted battery keeps Android (Samsung especially) from moving
      // the worker to slow cores once it gets busy.
      final status = await _backend.workerStatus();
      if (!status.batteryUnrestricted) await _backend.requestBatteryUnrestricted();
    }
    _workerRequested.value = true;
    worker.value = const ClusterWorkerStatus(state: 'starting');
    try {
      await _backend.startWorker(advertiseIp: wifiAddress.value);
    } catch (e) {
      Get.find<AppLogService>().error('Cluster worker failed to start', details: e);
      worker.value = ClusterWorkerStatus(state: 'error', error: _message(e));
      return;
    }
    refreshFirewall();
    await refreshWorkerStatus();
    _watchWorker();
  }

  Future<void> stopWorker() async {
    _workerRequested.value = false;
    _statusTimer?.cancel();
    await _backend.stopWorker();
    await Future.delayed(const Duration(milliseconds: 600));
    await refreshWorkerStatus();
  }

  /// Follows the worker service (its own process) while it runs: whether a
  /// master is connected and how much it holds.
  void _watchWorker() {
    _statusTimer?.cancel();
    var checks = 0;
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await refreshWorkerStatus();
      final s = worker.value;
      // Give the service a few seconds to come up before calling it stopped.
      if (!s.running && !s.starting && ++checks > 3) {
        _workerRequested.value = false;
        _statusTimer?.cancel();
      }
    });
  }

  Future<void> refreshWorkerStatus() async {
    try {
      worker.value = await _backend.workerStatus();
    } catch (e) {
      Get.find<AppLogService>().error('Cluster worker status failed', details: e);
    }
  }

  /// The backend for this platform. One instance per process: the Windows one
  /// owns a child process.
  ClusterBackend get _backend => ClusterBackend.instance;

  /// Windows: is the worker port allowed through the firewall? Cheap enough
  /// to re-check whenever the cluster screen opens.
  Future<void> refreshFirewall() async {
    try {
      firewallReady.value = await _backend.firewallReady();
    } catch (_) {
      firewallReady.value = null;
    }
  }

  /// Windows: creates the firewall rule (one UAC prompt), then re-checks.
  Future<void> allowFirewall() async {
    await _backend.allowFirewall();
    await Future<void>.delayed(const Duration(seconds: 2));
    await refreshFirewall();
  }

  static String _message(Object error) {
    final text = error is Exception ? '$error' : error.toString();
    return text.replaceFirst(RegExp(r'^Exception: '), '');
  }

  /// Finds this device's IPv4 address on the network it should cluster on:
  /// wlan* on Android, en0 on iOS, and on Windows the interface the user
  /// picked (or the first real one, skipping Hyper-V/WSL/VirtualBox adapters).
  Future<void> refreshWifiAddress() async {
    try {
      final all = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final candidates = _candidates(all);
      interfaces.assignAll(candidates);
      if (candidates.isEmpty) {
        wifiAddress.value = null;
        return;
      }
      final saved = _hive.getSetting<String>(AppConstants.keyClusterInterface);
      final chosen = candidates.firstWhereOrNull((c) => c.address == saved);
      wifiAddress.value = (chosen ?? candidates.first).address;
    } catch (_) {
      wifiAddress.value = null;
    }
  }

  /// Picks the interface to advertise and remembers it across launches.
  Future<void> setInterface(String address) async {
    await _hive.setSetting(AppConstants.keyClusterInterface, address);
    await refreshWifiAddress();
  }

  static List<({String name, String address})> _candidates(
      List<NetworkInterface> all) {
    final usable = <({String name, String address})>[
      for (final interface in all)
        for (final address in interface.addresses)
          if (_isUsable(interface.name, address.address))
            (name: interface.name, address: address.address),
    ];
    if (Platform.isAndroid) {
      return [for (final c in usable) if (c.name.startsWith('wlan')) c];
    }
    if (Platform.isIOS) {
      return [for (final c in usable) if (c.name == 'en0') c];
    }
    // A PC usually has several: put the physical ones first.
    int rank(({String name, String address}) c) {
      final name = c.name.toLowerCase();
      if (name.contains('wi-fi') || name.contains('wifi') || name.contains('wlan')) {
        return 0;
      }
      if (name.contains('ethernet')) return 1;
      return 2;
    }

    final sorted = [...usable]..sort((a, b) => rank(a).compareTo(rank(b)));
    return sorted;
  }

  static bool _isUsable(String name, String address) {
    if (address.startsWith('127.') || address.startsWith('169.254.')) return false;
    if (Platform.isAndroid || Platform.isIOS) return true;
    // Virtual adapters answer on the host too, and picking one strands the
    // cluster on a network no other device can reach.
    const virtual = [
      'vethernet',
      'hyper-v',
      'wsl',
      'virtualbox',
      'vmware',
      'loopback',
      'npcap',
      'tailscale',
      'zerotier',
    ];
    final lower = name.toLowerCase();
    return !virtual.any(lower.contains);
  }

  // ── Master: workers ────────────────────────────────────────────────────

  /// Adds the worker from a scanned QR code. Returns an error message, or
  /// null on success.
  Future<String?> addFromQr(String data) async {
    final uri = Uri.tryParse(data.trim());
    final params = uri?.queryParameters ?? const {};
    final host = params['host'];
    final port = int.tryParse(params['port'] ?? '');
    if (uri == null || uri.scheme != _qrScheme || host == null || port == null) {
      return 'That isn\'t a PrivateLM worker code';
    }
    return _add(ClusterWorker(
      name: params['name'] ?? host,
      host: host,
      port: port,
      ramMb: int.tryParse(params['ram'] ?? ''),
      bandwidth: double.tryParse(params['bw'] ?? ''),
      model: params['name'],
      id: params['id'],
    ));
  }

  /// Adds a worker by IP ("192.168.1.20" or "192.168.1.20:50052"). Returns
  /// an error message, or null on success.
  Future<String?> addManual(String input) async {
    final text = input.trim();
    if (text.isEmpty) return 'Enter the worker\'s IP address';
    final host = text.contains(':') ? text.substring(0, text.lastIndexOf(':')) : text;
    final port = text.contains(':')
        ? int.tryParse(text.substring(text.lastIndexOf(':') + 1))
        : ClusterBackend.defaultPort;
    if (host.isEmpty || port == null) return 'Use the form 192.168.1.20:50052';
    return _add(ClusterWorker(name: host, host: host, port: port));
  }

  Future<String?> addFound(ClusterWorker w) => _add(w);

  /// Finds saved workers that no longer answer at their address (they moved
  /// to another Wi-Fi, a hotspot, or got a new IP) by their device ID on
  /// the network, and updates them. Returns the ones still unreachable.
  Future<List<ClusterWorker>> relocateWorkers() async {
    final missing = <ClusterWorker>[];
    for (final w in workers) {
      if (!await _backend.probe(w.endpoint)) missing.add(w);
    }
    if (missing.isEmpty) return const [];
    final seen = await _backend.discover();
    var moved = 0;
    final unreachable = <ClusterWorker>[];
    for (final w in missing) {
      final match = seen.firstWhereOrNull((s) => w.id != null && s.id == w.id);
      final i = workers.indexWhere((x) => x.endpoint == w.endpoint);
      if (match == null || match.endpoint == w.endpoint || i < 0) {
        unreachable.add(w);
        continue;
      }
      workers[i] = w.movedTo(match.host, match.port);
      moved++;
    }
    if (moved > 0) {
      await _save();
      Get.find<AppLogService>().info('Phone cluster: found $moved worker(s) at a new address');
    }
    return unreachable;
  }

  Future<String?> _add(ClusterWorker worker) async {
    if (!await _backend.probe(worker.endpoint)) {
      return 'Can\'t reach ${worker.endpoint}. Check that Worker is on there '
          'and that both devices are on the same Wi-Fi.';
    }
    workers.removeWhere((w) => w.endpoint == worker.endpoint);
    workers.add(worker);
    found.removeWhere((w) => w.endpoint == worker.endpoint);
    await _save();
    return null;
  }

  Future<void> remove(ClusterWorker w) async {
    workers.removeWhere((s) => s.endpoint == w.endpoint);
    await _save();
  }

  bool isAdded(ClusterWorker w) => workers.any((s) => s.endpoint == w.endpoint);

  /// Looks for workers on the Wi-Fi (doesn't work on every router).
  Future<void> scanNearby() async {
    if (isScanning.value) return;
    isScanning.value = true;
    try {
      final list = await _backend.discover();
      found.assignAll(list.where((w) => !isAdded(w)));
    } finally {
      isScanning.value = false;
    }
  }

  Future<void> _setEnabled(bool value) async {
    enabled.value = value;
    await _hive.setSetting(AppConstants.keyClusterEnabled, value);
  }

  Future<void> _save() => _hive.setSetting(
      AppConstants.keyClusterWorkers, [for (final w in workers) w.toMap()]);

  // ── Master: loading ────────────────────────────────────────────────────

  /// Plans a GGUF load right before it starts and hands the plan to the
  /// native engine (or turns cluster mode off for it). Returns the number of
  /// workers used; throws with a readable message if the model won't fit
  /// or a worker can't be reached.
  ///
  /// If the model fits on this phone, asks whether to keep it here (faster:
  /// no Wi-Fi in the loop) or share it with the workers anyway. Otherwise
  /// the fastest phones are filled first, up to their free memory: phones
  /// take turns on every token, so the most work belongs on the fastest one,
  /// and phones that aren't needed are left out (one less Wi-Fi hop each).
  Future<int> applyForNextLoad(String modelPath, {String? modelName}) async {
    split.clear();
    if (!isSupported) return 0;
    if (!enabled.value || workers.isEmpty) {
      await _backend.clear();
      return 0;
    }

    // Workers that are off or away are left out, not fatal: the model may
    // fit without them.
    final offline = await relocateWorkers();
    final available = workers.where((w) => !offline.any((o) => o.endpoint == w.endpoint)).toList();
    if (offline.isNotEmpty) {
      final names = offline.map((w) => w.model ?? w.name).join(', ');
      showToast('Phone cluster', 'Not reachable, loading without: $names');
    }

    final modelMb = await File(modelPath).length() / (1024 * 1024);
    final needMb = modelMb * 1.1; // + KV cache and working buffers
    _localSpeed ??= await _backend.benchmark();
    // Free RAM: workers report theirs when they start. The master also runs
    // the app and the KV cache, so it offers less of its own.
    final master = _Phone(null, await _backend.localFreeRamMb() * 0.7, _localSpeed!);
    final phones = [
      master,
      for (final w in available)
        _Phone(w, (w.ramMb ?? 2000) * 0.75, w.bandwidth ?? _unknownSpeed),
    ];
    final totalMb = phones.fold<double>(0, (a, p) => a + p.capacityMb);
    if (needMb > totalMb) {
      throw Exception('This model (${_gb(modelMb)}) is too big for these '
          '${phones.length} phones: together they have about ${_gb(totalMb)} '
          'free.${offline.isEmpty ? '' : ' Not reachable: ${offline.map((w) => w.model ?? w.name).join(', ')}.'} '
          'Add another worker, close apps on the phones, or pick a '
          'smaller model.');
    }

    if (available.isEmpty) {
      await _backend.clear();
      return 0;
    }
    if (needMb <= master.capacityMb) {
      final share = await _askFitsHere(
          modelName ?? p.basename(modelPath), modelMb, available.length);
      if (!share) {
        await _backend.clear();
        return 0;
      }
      _splitBySpeed(phones, needMb);
    } else {
      _fillFastestFirst(phones, needMb);
    }

    final used = phones.where((p) => p.worker != null && p.assignedMb > 0).toList();
    if (used.isEmpty) {
      await _backend.clear();
      return 0;
    }
    try {
      await _backend.setCluster(
        [for (final p in used) p.worker!],
        weights: [for (final p in used) p.assignedMb],
        localWeight: master.assignedMb,
      );
    } on PlatformException catch (e) {
      throw Exception(
          '${e.message ?? 'A worker is unreachable'}. Turn on Worker on that '
          'device, or set this device\'s cluster role to Off.');
    }
    return used.length;
  }

  /// Fastest first, each up to its free memory, until the model is placed.
  static void _fillFastestFirst(List<_Phone> phones, double needMb) {
    final bySpeed = [...phones]..sort((a, b) => b.speed.compareTo(a.speed));
    var left = needMb;
    for (final p in bySpeed) {
      p.assignedMb = math.min(p.capacityMb, left);
      left -= p.assignedMb;
    }
  }

  /// Shares in proportion to speed, capped at each phone's free memory
  /// (what a capped phone can't take goes to the others).
  static void _splitBySpeed(List<_Phone> phones, double needMb) {
    var open = [...phones];
    var left = needMb;
    while (open.isNotEmpty && left > 0.5) {
      final speedSum = open.fold<double>(0, (a, p) => a + p.speed);
      final capped = [
        for (final p in open)
          if (p.assignedMb + left * p.speed / speedSum >= p.capacityMb) p,
      ];
      if (capped.isEmpty) {
        for (final p in open) {
          p.assignedMb += left * p.speed / speedSum;
        }
        left = 0;
      } else {
        for (final p in capped) {
          left -= p.capacityMb - p.assignedMb;
          p.assignedMb = p.capacityMb;
        }
        open = open.where((p) => !capped.contains(p)).toList();
      }
    }
  }

  /// LiteRT models can't be split across phones (the cluster is llama.cpp).
  /// When this phone is a master with workers, asks before loading one here
  /// alone. True to go ahead.
  Future<bool> confirmLiteRtRunsHere(String model) async {
    final context = Get.context;
    if (role != ClusterRole.master || workers.isEmpty || context == null) return true;
    final go = await showAppSheet<bool>(
      context,
      title: 'This model can\'t use your workers',
      subtitle: '${model.replaceAll(RegExp(r'\.(litertlm|task)$'), '')} is a LiteRT '
          'model, and only GGUF models can be shared across phones. It will run '
          'on this phone only. To use your workers, load a GGUF model instead.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this phone only',
            icon: Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(ctx, label: 'Cancel', onTap: () => Navigator.pop(ctx, false)),
        ],
      ),
    );
    return go == true;
  }

  /// "Fits on this phone" sheet. True to share with workers anyway.
  Future<bool> _askFitsHere(String model, double modelMb, int workerCount) async {
    final context = Get.context;
    if (context == null) return false;
    final share = await showAppSheet<bool>(
      context,
      title: 'This model fits on this phone',
      subtitle: '${model.replaceAll(RegExp(r'\.gguf$'), '')} needs about '
          '${_gb(modelMb)}, and this phone has room for it. Running it here '
          'is faster, because sharing sends every word over Wi-Fi. Share it '
          'to free up memory on this phone.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this phone only',
            icon: Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(
            ctx,
            label: 'Share with $workerCount worker${workerCount == 1 ? '' : 's'}',
            onTap: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    return share == true;
  }

  /// Reads where the model actually went after a cluster load. Workers'
  /// shares come from llama.cpp's per-device weight buffers; this phone's
  /// share is the rest of the file, because its own buffers overlap (the
  /// mapped file and the CPU's repacked copy of the same weights).
  Future<void> refreshSplit(String modelPath) async {
    final buffers = await _backend.lastLoadBuffers();
    final remote = <String, double>{};
    for (final b in buffers) {
      final open = b.name.indexOf('[');
      if (open < 0) continue;
      final endpoint = b.name.substring(open + 1, b.name.lastIndexOf(']'));
      final name = workers.firstWhereOrNull((w) => w.endpoint == endpoint)?.model ?? endpoint;
      remote[name] = (remote[name] ?? 0) + b.mb;
    }
    final fileMb = await File(modelPath).length() / (1024 * 1024);
    final remoteMb = remote.values.fold<double>(0, (a, b) => a + b);
    split.assignAll([
      ClusterShare(deviceName.isEmpty ? 'This phone' : deviceName,
          math.max(0, fileMb - remoteMb), isThisPhone: true),
      for (final e in remote.entries) ClusterShare(e.key, e.value),
    ]);
  }

  void clearSplit() => split.clear();

  static String _gb(double mb) => '${(mb / 1024).toStringAsFixed(1)} GB';
}
