import 'dart:async';
import 'dart:io' show File, InternetAddressType, NetworkInterface, Platform;
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import '../core/constants.dart';
import '../core/path_helpers.dart';
import '../core/ui.dart';
import 'app_log_service.dart';
import 'cluster_backend.dart';
import 'cluster_endpoint.dart';
import 'cluster_interface.dart';
import 'cluster_planner.dart';
import 'hive_service.dart';
import 'tailscale_service.dart';
import 'usb_bridge_service.dart';

/// What this device does in an AI cluster.
enum ClusterRole {
  off,

  /// Runs the model, with part of it on the workers.
  master,

  /// Lends its processor and memory to a master.
  worker,
}

/// One device's part of the loaded model.
class ClusterShare {
  final String name;
  final double mb;
  final bool isThisDevice;
  const ClusterShare(this.name, this.mb, {this.isThisDevice = false});
}

/// A device the master can put layers on, for planning a load.
typedef _Device = ClusterDevice;

/// AI cluster: spread a GGUF model across devices on the same network. The
/// master runs the model; workers hold part of its layers. Devices can be
/// phones or PCs, reached over Wi-Fi/LAN, a USB cable (adb) or Tailscale.
class ClusterService extends GetxService {
  ClusterService({UsbBridgeService? usb, TailscaleService? tailscale})
      : _usb = usb ?? UsbBridgeService(),
        _tailscale = tailscale ?? TailscaleService();

  final HiveService _hive = Get.find<HiveService>();

  /// USB adb bridges and Tailscale discovery, both desktop only.
  final UsbBridgeService _usb;
  final TailscaleService _tailscale;

  /// Android and iOS run the worker in the app; Windows and Linux run a
  /// separate worker process.
  static bool get isSupported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isWindows ||
          Platform.isLinux);

  /// Running a model across workers is Android and desktop for now; iOS
  /// devices can be workers (their GPU serves a master's layers).
  static bool get canBeMaster =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows || Platform.isLinux);

  /// iOS can't stop the worker without closing the app.
  static bool get workerStopsWithApp => !kIsWeb && Platform.isIOS;

  /// Windows and Linux have no camera scanner plugin; pairing there is by IP
  /// or link.
  static bool get canScanQr =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// A PC build: no camera, no battery optimization, no orientation lock.
  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);

  static bool get isLinux => !kIsWeb && Platform.isLinux;

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

  /// This device's worker service.
  final worker = const ClusterWorkerStatus(state: 'stopped').obs;
  final _workerRequested = false.obs;

  /// The API server is running (other devices, e.g. a PC, use the model).
  final serving = false.obs;

  /// This device's cluster address, or null when it isn't on a network.
  final wifiAddress = RxnString();

  /// Interfaces a cluster could run on (a PC usually has more than one).
  final interfaces = <ClusterInterface>[].obs;

  /// Phones attached over USB and the adb mappings that reach them.
  final usbDevices = <AdbDevice>[].obs;
  final usbBridges = <UsbBridge>[].obs;
  final usbAvailable = false.obs;
  final usbBusy = false.obs;

  /// Tailscale peers on this tailnet, when the CLI is installed.
  final tailscalePeers = <ClusterWorker>[].obs;
  final tailscaleAvailable = false.obs;

  /// Whether Tailscale/VPN interfaces are offered. Off by default: a tailnet
  /// is not a trusted LAN, and the RPC port has no authentication.
  final includeVpn = false.obs;

  /// Restricts the worker's RPC listener to one address instead of every
  /// interface. Null listens everywhere; takes effect on the next start.
  final workerBindHost = RxnString();

  /// The address the worker listens on and a master should use: the bound
  /// interface when set, otherwise the advertised cluster address.
  String? get workerHost => workerBindHost.value ?? wifiAddress.value;

  /// Windows: whether Windows Firewall already allows the worker port. Null
  /// where there is no firewall to configure.
  final firewallReady = RxnBool();

  /// How the loaded model is spread across devices; empty when it isn't.
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
    return split
        .map((s) => '${s.name} ${(s.mb / total * 100).round()}%')
        .join(' · ');
  }

  @override
  void onInit() {
    super.onInit();
    enabled.value =
        _hive.getSetting<bool>(AppConstants.keyClusterEnabled) ?? false;
    includeVpn.value =
        _hive.getSetting<bool>(AppConstants.keyClusterIncludeVpn) ?? false;
    final savedBind = _hive.getSetting<String>(AppConstants.keyClusterBindHost);
    workerBindHost.value =
        savedBind != null && savedBind.isNotEmpty ? savedBind : null;
    final saved =
        _hive.getSetting<List>(AppConstants.keyClusterWorkers) ?? const [];
    workers.assignAll(saved.whereType<Map>().map(ClusterWorker.fromMap));
    if (isSupported) {
      if (Platform.isWindows || Platform.isLinux) {
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
      if (isDesktop) {
        usbAvailable.value = _usb.available;
        tailscaleAvailable.value = _tailscale.available;
        unawaited(_restoreUsbBridges());
      }
    }
  }

  @override
  void onClose() {
    _statusTimer?.cancel();
    unawaited(releaseUsbBridges());
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
        showToast(
            'Still sharing', 'Close PrivateLM to stop sharing this device.');
        return;
      }
      await stopWorker();
    }
    // USB mappings only make sense for one role: drop the other direction
    // before switching so no stale adb listener is left behind.
    await _releaseUsbBridges(keep: next);
    await _setEnabled(next == ClusterRole.master);
    if (next == ClusterRole.worker) await startWorker();
    await refreshWifiAddress();
    if (isDesktop) await _restoreUsbBridges();
  }

  // ── Worker ─────────────────────────────────────────────────────────────

  /// What the master scans to add this device, once the worker is running.
  String? get workerQrData {
    final host = workerHost;
    final status = worker.value;
    if (host == null || !status.running) return null;
    return Uri(scheme: _qrScheme, host: 'worker', queryParameters: {
      'host': host,
      'port': '${ClusterBackend.defaultPort}',
      't': _advertisedTransport.wireName,
      if (deviceName.isNotEmpty) 'name': deviceName,
      if (status.ramMb > 0) 'ram': '${status.ramMb}',
      if (status.bandwidth > 0) 'bw': status.bandwidth.toStringAsFixed(1),
      if (status.id != null) 'id': status.id!,
    }).toString();
  }

  /// The link a master reaches this device over, from the chosen interface.
  ClusterTransport get _advertisedTransport {
    final kind =
        interfaces.firstWhereOrNull((i) => i.address == workerHost)?.kind;
    return switch (kind) {
      ClusterLinkKind.usb => ClusterTransport.usbTether,
      ClusterLinkKind.tailscale => ClusterTransport.tailscale,
      _ => ClusterTransport.lan,
    };
  }

  Future<void> startWorker() async {
    if (Platform.isAndroid) {
      // Unrestricted battery keeps Android (Samsung especially) from moving
      // the worker to slow cores once it gets busy.
      final status = await _backend.workerStatus();
      if (!status.batteryUnrestricted) {
        await _backend.requestBatteryUnrestricted();
      }
    }
    _workerRequested.value = true;
    worker.value = const ClusterWorkerStatus(state: 'starting');
    try {
      await _backend.startWorker(
        advertiseIp: workerHost,
        bindHost: workerBindHost.value,
      );
    } catch (e) {
      Get.find<AppLogService>()
          .error('Cluster worker failed to start', details: e);
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
      Get.find<AppLogService>()
          .error('Cluster worker status failed', details: e);
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
  /// Wi-Fi first, then Ethernet, then USB tethering; a VPN interface only when
  /// the user opted in. The chosen address is remembered across launches.
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

  /// Keeps the worker on [address] only (null listens on every interface), so
  /// another network cannot reach the unauthenticated RPC port. Takes effect
  /// the next time the worker starts.
  Future<void> setWorkerBindHost(String? address) async {
    workerBindHost.value = address;
    await _hive.setSetting(AppConstants.keyClusterBindHost, address ?? '');
    if (address != null) await setInterface(address);
  }

  /// Turns VPN/Tailscale interfaces on or off and re-picks the address.
  Future<void> setIncludeVpn(bool value) async {
    includeVpn.value = value;
    await _hive.setSetting(AppConstants.keyClusterIncludeVpn, value);
    await refreshWifiAddress();
  }

  static List<ClusterInterface> _candidates(List<NetworkInterface> all) {
    final entries = <({String name, String address})>[
      for (final interface in all)
        for (final address in interface.addresses)
          (name: interface.name, address: address.address),
    ];
    var ranked = rankInterfaces(entries,
        includeVpn: Get.isRegistered<ClusterService>()
            ? Get.find<ClusterService>().includeVpn.value
            : false);

    if (Platform.isAndroid) {
      // Wi-Fi, USB tethering and Ethernet. Mobile data (rmnet*, ccmni*) is
      // virtual in the classifier, so it is already gone.
      return ranked;
    }
    if (Platform.isIOS) {
      // en0 is Wi-Fi on iOS; the classifier cannot tell from the name alone.
      return [
        for (final c in ranked)
          if (c.name == 'en0' || c.kind == ClusterLinkKind.tailscale)
            ClusterInterface(c.name, c.address,
                c.name == 'en0' ? ClusterLinkKind.wifi : c.kind),
      ];
    }
    // A PC usually has several: Wi-Fi, Ethernet, USB tethering, Tailscale.
    return ranked;
  }

  // ── Master: workers ────────────────────────────────────────────────────

  /// Adds the worker from a scanned QR code. Returns an error message, or
  /// null on success.
  Future<String?> addFromQr(String data) async {
    final uri = Uri.tryParse(data.trim());
    final params = uri?.queryParameters ?? const {};
    final host = params['host'];
    final port = int.tryParse(params['port'] ?? '');
    if (uri == null ||
        uri.scheme != _qrScheme ||
        host == null ||
        port == null) {
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
      // Older builds send no `t`: LAN is the right default.
      transport: ClusterTransport.parse(params['t']),
      iface: params['iface'],
    ));
  }

  /// Adds a worker by address: "192.168.1.20", "192.168.1.20:50052",
  /// "[fd7a::1]:50052" or a MagicDNS host name. A pasted
  /// `privatelm://worker?...` link also works. Returns an error message, or
  /// null on success.
  Future<String?> addManual(String input) async {
    final text = input.trim();
    if (text.isEmpty) return 'Enter the worker\'s address';
    if (text.startsWith('$_qrScheme://')) return addFromQr(text);
    final ClusterEndpoint endpoint;
    try {
      endpoint = ClusterEndpoint.parse(text);
    } on FormatException catch (e) {
      return e.message;
    }
    return _add(ClusterWorker(
      name: endpoint.host,
      host: endpoint.host,
      port: endpoint.port,
    ));
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
      Get.find<AppLogService>()
          .info('AI cluster: found $moved worker(s) at a new address');
    }
    return unreachable;
  }

  Future<String?> _add(ClusterWorker worker) async {
    if (!await _backend.probe(worker.endpoint)) {
      return 'Can\'t reach ${worker.endpoint}. Check that Worker is on there '
          'and that both devices are on the same network (or USB cable).';
    }
    // The phone's USB tethering subnet is a strong hint; label it so the UI
    // shows a USB badge and the user knows the cable carries the traffic.
    final added = worker.transport == ClusterTransport.lan &&
            worker.host.startsWith('192.168.42.')
        ? worker.withTransport(ClusterTransport.usbTether)
        : worker;
    workers.removeWhere((w) => w.endpoint == added.endpoint);
    workers.add(added);
    found.removeWhere((w) => w.endpoint == added.endpoint);
    tailscalePeers.removeWhere((w) => w.endpoint == added.endpoint);
    await _save();
    return null;
  }

  Future<void> remove(ClusterWorker w) async {
    if (w.transport == ClusterTransport.usbAdb) {
      final bridge = usbBridges.firstWhereOrNull(
          (b) => !b.reverse && b.localPort == w.port && w.host == '127.0.0.1');
      if (bridge != null) {
        await _usb.removeBridgeQuietly(bridge);
        usbBridges.remove(bridge);
        await _saveUsbBridges();
      }
    }
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

  // ── USB (adb) ──────────────────────────────────────────────────────────

  /// Refreshes the attached phones and whether adb is usable. Cheap enough to
  /// call whenever the USB sheet opens.
  Future<void> refreshUsb() async {
    usbAvailable.value = _usb.available;
    if (!isDesktop || !usbAvailable.value) {
      usbDevices.clear();
      return;
    }
    try {
      usbDevices.assignAll(await _usb.devices());
    } catch (e) {
      Get.find<AppLogService>().error('Could not list USB devices', details: e);
      usbDevices.clear();
    }
  }

  /// PC master + phone worker over a cable: `adb forward` from a local port to
  /// the phone's worker, then adds 127.0.0.1:<port> as a worker.
  Future<String?> addUsbWorker(AdbDevice device) async {
    if (!isDesktop) return 'USB pairing is only available on the desktop app';
    if (!device.usable) return device.problem ?? 'That device is not ready';
    if (usbBusy.value) return 'Still connecting the previous phone';
    usbBusy.value = true;
    try {
      final port =
          UsbBridgeService.allocatePort(usbBridges.map((b) => b.localPort));
      final bridge =
          UsbBridge(serial: device.serial, localPort: port, reverse: false);
      try {
        await _usb.forward(device.serial, port);
      } catch (e) {
        return _message(e);
      }
      final error = await _add(ClusterWorker(
        name: device.label,
        host: '127.0.0.1',
        port: port,
        model: device.label,
        transport: ClusterTransport.usbAdb,
        iface: device.serial,
      ));
      if (error != null) {
        await _usb.removeBridgeQuietly(bridge);
        return error;
      }
      usbBridges.add(bridge);
      await _saveUsbBridges();
      Get.find<AppLogService>()
          .info('USB cluster bridge: ${device.label} on 127.0.0.1:$port');
      return null;
    } finally {
      usbBusy.value = false;
    }
  }

  /// Phone master + PC worker over a cable: `adb reverse` exposes this PC's
  /// worker on the phone's loopback. Returns the port the phone should add.
  Future<({int? port, String? error})> exposeWorkerToDevice(
      AdbDevice device) async {
    if (!isDesktop) {
      return (
        port: null,
        error: 'USB pairing is only available on the desktop app'
      );
    }
    if (!device.usable) {
      return (port: null, error: device.problem ?? 'That device is not ready');
    }
    if (!worker.value.running) {
      return (
        port: null,
        error: 'Turn on Worker first, then connect the phone.'
      );
    }
    if (usbBusy.value) {
      return (port: null, error: 'Still connecting the previous phone');
    }
    usbBusy.value = true;
    try {
      final used = {
        for (final b in usbBridges)
          if (b.reverse && b.serial == device.serial) b.localPort,
      };
      final port = UsbBridgeService.allocatePort(used);
      try {
        await _usb.reverse(device.serial, port);
      } catch (e) {
        return (port: null, error: _message(e));
      }
      usbBridges.add(
          UsbBridge(serial: device.serial, localPort: port, reverse: true));
      await _saveUsbBridges();
      Get.find<AppLogService>()
          .info('USB reverse bridge: ${device.label} sees 127.0.0.1:$port');
      return (port: port, error: null);
    } finally {
      usbBusy.value = false;
    }
  }

  /// Removes every adb mapping, including the synthetic workers that point at
  /// them. Safe to call on exit and when the role changes.
  Future<void> releaseUsbBridges() => _releaseUsbBridges(keep: ClusterRole.off);

  Future<void> _releaseUsbBridges({required ClusterRole keep}) async {
    if (!isDesktop || usbBridges.isEmpty) return;
    final removing = <UsbBridge>[
      for (final b in usbBridges)
        if (keep == ClusterRole.worker
            ? !b.reverse
            : keep == ClusterRole.master
                ? b.reverse
                : true)
          b,
    ];
    if (removing.isEmpty) return;
    for (final b in removing) {
      await _usb.removeBridgeQuietly(b);
    }
    final ports = {
      for (final b in removing)
        if (!b.reverse) b.localPort,
    };
    usbBridges.removeWhere(removing.contains);
    workers.removeWhere((w) =>
        w.transport == ClusterTransport.usbAdb &&
        w.host == '127.0.0.1' &&
        ports.contains(w.port));
    await _saveUsbBridges();
    await _save();
  }

  /// Recreates the saved mappings for the current role. adb listeners outlive
  /// the app, so every saved mapping is removed first: that also clears the
  /// ones left behind by a previous session.
  Future<void> _restoreUsbBridges() async {
    if (!isDesktop) return;
    final saved =
        _hive.getSetting<List>(AppConstants.keyClusterUsbBridges) ?? const [];
    usbBridges.assignAll(saved.whereType<Map>().map(UsbBridge.fromMap));
    if (usbBridges.isEmpty) return;
    for (final b in [...usbBridges]) {
      await _usb.removeBridgeQuietly(b);
    }
    if (!_usb.available) {
      await _saveUsbBridges();
      return;
    }
    final current = role;
    List<AdbDevice> attached = const [];
    try {
      attached = await _usb.devices();
    } catch (_) {
      // No adb server: leave the mappings for the next launch.
      return;
    }

    final kept = <UsbBridge>[];
    for (final b in [...usbBridges]) {
      final wanted = current == ClusterRole.worker
          ? b.reverse
          : current == ClusterRole.master
              ? !b.reverse
              : false;
      if (!wanted) continue;
      final present = attached.any((d) => d.usable && d.serial == b.serial);
      if (!present) continue;
      try {
        if (b.reverse) {
          await _usb.reverse(b.serial, b.localPort);
        } else {
          await _usb.forward(b.serial, b.localPort);
        }
        kept.add(b);
      } catch (_) {
        // Keep the worker entry? No: the bridge is what reaches it.
      }
    }

    usbBridges.assignAll(kept);
    final ports = {
      for (final b in kept)
        if (!b.reverse) b.localPort,
    };
    workers.removeWhere((w) =>
        w.transport == ClusterTransport.usbAdb &&
        w.host == '127.0.0.1' &&
        !ports.contains(w.port));
    await _saveUsbBridges();
    await _save();
  }

  Future<void> _saveUsbBridges() => _hive.setSetting(
      AppConstants.keyClusterUsbBridges,
      [for (final b in usbBridges) b.toMap()]);

  // ── Tailscale ──────────────────────────────────────────────────────────

  /// Finds online peers on this tailnet. Manual MagicDNS entry works without
  /// the CLI; the list is empty when Tailscale is not installed.
  Future<void> refreshTailscale() async {
    tailscaleAvailable.value = _tailscale.available;
    if (!isDesktop || !tailscaleAvailable.value) {
      tailscalePeers.clear();
      return;
    }
    try {
      final peers = await _tailscale.peers();
      tailscalePeers.assignAll(
          [for (final p in peers) p.toWorker()].where((w) => !isAdded(w)));
    } catch (e) {
      Get.find<AppLogService>()
          .error('Could not list Tailscale peers', details: e);
      tailscalePeers.clear();
    }
  }

  Future<String?> addTailscalePeer(ClusterWorker worker) => _add(worker);

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
  /// If the model fits on this device, asks whether to keep it here (faster:
  /// no network in the loop) or share it with the workers anyway. Otherwise
  /// the fastest devices are filled first, up to their free memory: devices
  /// take turns on every token, so the most work belongs on the fastest one,
  /// and devices that aren't needed are left out (one less network hop each).
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
    final available = workers
        .where((w) => !offline.any((o) => o.endpoint == w.endpoint))
        .toList();
    if (offline.isNotEmpty) {
      final names = offline.map((w) => w.model ?? w.name).join(', ');
      showToast('AI cluster', 'Not reachable, loading without: $names');
    }

    final modelMb = await File(modelPath).length() / (1024 * 1024);
    final needMb = modelMb * 1.1; // + KV cache and working buffers
    _localSpeed ??= await _backend.benchmark();
    // Free RAM: workers report theirs when they start. The master also runs
    // the app and the KV cache, so it offers less of its own.
    final master =
        _Device(null, await _backend.localFreeRamMb() * 0.7, _localSpeed!);
    final devices = [
      master,
      for (final w in available)
        _Device(w, (w.ramMb ?? 2000) * 0.75, w.bandwidth ?? _unknownSpeed,
            latencyMs: w.latencyMs),
    ];
    final totalMb = devices.fold<double>(0, (a, d) => a + d.capacityMb);
    if (needMb > totalMb) {
      throw Exception('This model (${formatGb(modelMb)}) is too big for these '
          '${devices.length} devices: together they have about ${formatGb(totalMb)} '
          'free.${offline.isEmpty ? '' : ' Not reachable: ${offline.map((w) => w.model ?? w.name).join(', ')}.'} '
          'Add another worker, close apps on the devices, or pick a '
          'smaller model.');
    }

    if (available.isEmpty) {
      await _backend.clear();
      return 0;
    }
    if (needMb <= master.capacityMb) {
      final share = await _askFitsHere(
          modelName ?? modelFileName(modelPath), modelMb, available.length);
      if (!share) {
        await _backend.clear();
        return 0;
      }
      splitBySpeed(devices, needMb);
    } else {
      fillFastestFirst(devices, needMb);
    }

    final used =
        devices.where((d) => d.worker != null && d.assignedMb > 0).toList();
    if (used.isEmpty) {
      await _backend.clear();
      return 0;
    }
    try {
      await _backend.setCluster(
        [for (final d in used) d.worker!],
        weights: [for (final d in used) d.assignedMb],
        localWeight: master.assignedMb,
      );
    } on PlatformException catch (e) {
      throw Exception(
          '${e.message ?? 'A worker is unreachable'}. Turn on Worker on that '
          'device, or set this device\'s cluster role to Off.');
    }
    return used.length;
  }

  /// LiteRT models can't be split across devices (the cluster is llama.cpp).
  /// When this device is a master with workers, asks before loading one here
  /// alone. True to go ahead.
  Future<bool> confirmLiteRtRunsHere(String model) async {
    final context = Get.context;
    if (role != ClusterRole.master || workers.isEmpty || context == null) {
      return true;
    }
    final go = await showAppSheet<bool>(
      context,
      title: 'This model can\'t use your workers',
      subtitle:
          '${model.replaceAll(RegExp(r'\.(litertlm|task)$'), '')} is a LiteRT '
          'model, and only GGUF models can be shared across devices. It will run '
          'on this device only. To use your workers, load a GGUF model instead.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this device only',
            icon: ClusterService.isDesktop
                ? Icons.computer_rounded
                : Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(ctx,
              label: 'Cancel', onTap: () => Navigator.pop(ctx, false)),
        ],
      ),
    );
    return go == true;
  }

  /// "Fits on this device" sheet. True to share with workers anyway.
  Future<bool> _askFitsHere(
      String model, double modelMb, int workerCount) async {
    final context = Get.context;
    if (context == null) return false;
    final share = await showAppSheet<bool>(
      context,
      title: 'This model fits on this device',
      subtitle: '${model.replaceAll(RegExp(r'\.gguf$'), '')} needs about '
          '${formatGb(modelMb)}, and this device has room for it. Running it here '
          'is faster, because sharing sends every word over Wi-Fi. Share it '
          'to free up memory on this device.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this device only',
            icon: ClusterService.isDesktop
                ? Icons.computer_rounded
                : Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(
            ctx,
            label:
                'Share with $workerCount worker${workerCount == 1 ? '' : 's'}',
            onTap: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    return share == true;
  }

  /// Reads where the model actually went after a cluster load. Workers'
  /// shares come from llama.cpp's per-device weight buffers; this device's
  /// share is the rest of the file, because its own buffers overlap (the
  /// mapped file and the CPU's repacked copy of the same weights).
  Future<void> refreshSplit(String modelPath) async {
    final buffers = await _backend.lastLoadBuffers();
    final remote = <String, double>{};
    for (final b in buffers) {
      final open = b.name.indexOf('[');
      if (open < 0) continue;
      final endpoint = b.name.substring(open + 1, b.name.lastIndexOf(']'));
      final name =
          workers.firstWhereOrNull((w) => w.endpoint == endpoint)?.model ??
              endpoint;
      remote[name] = (remote[name] ?? 0) + b.mb;
    }
    final fileMb = await File(modelPath).length() / (1024 * 1024);
    final remoteMb = remote.values.fold<double>(0, (a, b) => a + b);
    split.assignAll([
      ClusterShare(
          deviceName.isEmpty
              ? (ClusterService.isDesktop ? 'This PC' : 'This phone')
              : deviceName,
          math.max(0, fileMb - remoteMb),
          isThisDevice: true),
      for (final e in remote.entries) ClusterShare(e.key, e.value),
    ]);
  }

  void clearSplit() => split.clear();
}
