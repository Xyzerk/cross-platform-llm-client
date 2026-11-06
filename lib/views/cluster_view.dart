import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/ui.dart';
import '../services/cluster_backend.dart';
import '../services/cluster_service.dart';

/// Phone cluster: pick Master (runs the model) or Worker (lends this phone),
/// and pair them by scanning the worker's QR code.
class ClusterView extends StatefulWidget {
  const ClusterView({super.key});

  @override
  State<ClusterView> createState() => _ClusterViewState();
}

class _ClusterViewState extends State<ClusterView> {
  final ClusterService cluster = Get.find<ClusterService>();
  Timer? _wifiTimer;

  @override
  void initState() {
    super.initState();
    cluster.refreshWorkerStatus();
    cluster.refreshWifiAddress();
    if (cluster.role == ClusterRole.master) cluster.relocateWorkers();
    // Pick up Wi-Fi being turned on while this screen is open.
    _wifiTimer = Timer.periodic(
        const Duration(seconds: 3), (_) => cluster.refreshWifiAddress());
  }

  @override
  void dispose() {
    _wifiTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(
          context,
          title: ClusterService.isDesktop ? 'Device cluster' : 'Phone cluster',
          showBack: true),

      body: Obx(() {
        final role = cluster.role;
        return ListView(
          padding: kPagePadding,
          children: [
            const SizedBox(height: 8),
            AppSegmented<ClusterRole>(
              items: [
                (ClusterRole.off, 'Off'),
                if (ClusterService.canBeMaster) (ClusterRole.master, 'Master'),
                (ClusterRole.worker, 'Worker'),
              ],
              selected: role,
              onChanged: cluster.setRole,
            ),
            const SizedBox(height: 16),
            if (role != ClusterRole.off && cluster.wifiAddress.value == null) ...[
              AppNotice(
                'Turn on Wi-Fi. All devices in the cluster must be on the same '
                'network.',
                icon: Icons.wifi_off_rounded,
                color: t.orange,
              ),
              const SizedBox(height: 16),
            ],
            if (cluster.interfaces.length > 1) ...[
              _interfacePicker(context),
              const SizedBox(height: 16),
            ],
            ...switch (role) {
              ClusterRole.off => _offSection(),
              ClusterRole.master => _masterSection(context),
              ClusterRole.worker => _workerSection(context),
            },
          ],
        );
      }),
    );
  }

  List<Widget> _offSection() => [
        AppNotice(
          ClusterService.canBeMaster
              ? 'Run models too big for one device by sharing the work across '
                  'devices on the same Wi-Fi or LAN.\n\n'
                  'Master: the device you chat on. It runs the model.\n'
                  'Worker: a phone or PC that lends its memory to the master.'
              : 'Help an Android phone running PrivateLM run models too big for '
                  'it alone: choose Worker, then scan this device\'s QR code '
                  'from that phone.',
          icon: Icons.hub_outlined,
        ),
      ];

  Widget _interfacePicker(BuildContext context) {
    final t = AppTokens.of(context);
    final address = cluster.wifiAddress.value;
    final name = cluster.interfaces
            .firstWhereOrNull((i) => i.address == address)
            ?.name ??
        'Network';
    return Row(children: [
      Icon(Icons.lan_rounded, size: 18, color: t.muted),
      const SizedBox(width: 8),
      Expanded(child: Text('$name · $address', style: t.caption)),
      PillButton(label: 'Change', onPressed: () => _chooseInterface(context)),
    ]);
  }

  Future<void> _chooseInterface(BuildContext context) async {
    final address = await showAppSheet<String>(
      context,
      title: 'Cluster network',
      subtitle: 'Pick the network the other devices can reach.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final interface in cluster.interfaces)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PillButton(
                label: '${interface.name} · ${interface.address}',
                primary: interface.address == cluster.wifiAddress.value,
                onPressed: () => Navigator.pop(ctx, interface.address),
              ),
            ),
        ],
      ),
    );
    if (address != null) await cluster.setInterface(address);
  }

  // ── Worker ─────────────────────────────────────────────────────────────

  List<Widget> _workerSection(BuildContext context) {
    final t = AppTokens.of(context);
    final s = cluster.worker.value;
    final qr = cluster.workerQrData;

    final Widget body;
    if (s.state == 'error') {
      body = _centered(context, [
        Icon(Icons.error_outline_rounded, size: 40, color: t.red),
        const SizedBox(height: 12),
        Text('Worker stopped', style: t.bodyStrong),
        const SizedBox(height: 4),
        Text(s.error ?? 'Unknown error', style: t.caption, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        PillButton(label: 'Try again', primary: true, onPressed: cluster.startWorker),
      ]);
    } else if (s.peer != null) {
      body = _centered(context, [
        _PulsingDot(color: t.green),
        const SizedBox(height: 14),
        Text('Sharing with master', style: t.bodyStrong.copyWith(fontSize: 18)),
        const SizedBox(height: 4),
        Text(s.peer!, style: t.caption),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: _Stat(label: 'Holding', value: _gb(s.heldMb))),
          Expanded(child: _Stat(label: 'Free at start', value: _gb(s.ramMb))),
          Expanded(child: _Stat(label: 'Memory speed', value: '${s.bandwidth.toStringAsFixed(1)} GB/s')),
        ]),
      ]);
    } else if (!s.running || qr == null) {
      body = _centered(context, [
        const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
        const SizedBox(height: 16),
        Text(
            s.running
                ? 'Waiting for a network address…'
                : ClusterService.isDesktop
                    ? 'Starting the worker…'
                    : 'Measuring this phone…',
            style: t.caption),
      ]);
    } else {
      body = _centered(context, [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: QrImageView(data: qr, size: 220, padding: EdgeInsets.zero),
        ),
        const SizedBox(height: 16),
        Text(
            ClusterService.isDesktop
                ? 'Scan this from the master, or enter this address there'
                : 'Scan this from the master phone',
            style: t.bodyStrong,
            textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Row(mainAxisSize: MainAxisSize.min, children: [
          StatusDot(t.green, size: 8),
          const SizedBox(width: 6),
          SelectableText(
              'Ready · ${cluster.wifiAddress.value}:${ClusterBackend.defaultPort}',
              style: t.caption),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _Stat(label: 'Free memory', value: _gb(s.ramMb))),
          Expanded(child: _Stat(label: 'Memory speed', value: '${s.bandwidth.toStringAsFixed(1)} GB/s')),
        ]),
      ]);
    }

    return [
      if (cluster.firewallReady.value == false) ...[
        AppNotice(
          'Windows Firewall may be blocking other devices. Allow PrivateLM '
          'through the firewall, or the master won\'t be able to connect.',
          icon: Icons.shield_outlined,
          color: t.orange,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            label: 'Allow through Windows Firewall',
            primary: true,
            onPressed: cluster.allowFirewall,
          ),
        ),
        const SizedBox(height: 16),
      ],
      if (s.throttled) ...[
        AppNotice(
          'Android is slowing this worker down (slow cores only), which slows '
          'the whole cluster. Set PrivateLM\'s battery use to Unrestricted, '
          'then turn Worker off and on.',
          icon: Icons.speed_rounded,
          color: t.orange,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            label: 'Set Unrestricted',
            primary: true,
            onPressed: _allowBattery,
          ),
        ),
        const SizedBox(height: 16),
      ],
      AppCard(padding: const EdgeInsets.fromLTRB(16, 24, 16, 20), child: body),
      SectionFootnote(ClusterService.workerStopsWithApp
          ? 'Keep this device plugged in, on the same Wi-Fi, with PrivateLM open: '
              'iOS pauses apps in the background. Close PrivateLM to stop sharing.'
          : ClusterService.isDesktop
              ? 'Keep this PC plugged in and on the same network. PrivateLM '
                  'starts a small background process for the worker and stops '
                  'it when you turn Worker off or close the app. If the master '
                  'can\'t connect, allow PrivateLM through Windows Firewall.'
              : 'Keep this phone plugged in and on the same Wi-Fi, with PrivateLM '
                  'open: the screen stays on while sharing, because Android slows '
                  'background work. Set Phone cluster to Off to stop.'),
    ];
  }

  Future<void> _allowBattery() =>
      ClusterBackend.instance.requestBatteryUnrestricted();

  Widget _centered(BuildContext context, List<Widget> children) =>
      Column(crossAxisAlignment: CrossAxisAlignment.center, children: children);

  // ── Master ─────────────────────────────────────────────────────────────

  List<Widget> _masterSection(BuildContext context) {
    final t = AppTokens.of(context);
    return [
      if (cluster.split.length > 1) ...[
        _SplitCard(shares: cluster.split),
        const SizedBox(height: 16),
      ],
      if (ClusterService.canScanQr)
        PrimaryButton(
          label: 'Scan a worker\'s QR code',
          icon: Icons.qr_code_scanner_rounded,
          onPressed: _scanQr,
        )
      else
        PrimaryButton(
          label: 'Paste a worker link',
          icon: Icons.link_rounded,
          onPressed: () => _pasteLink(context),
        ),
      SectionHeader('Workers (${cluster.workers.length})'),
      if (cluster.workers.isEmpty)
        AppGroup(children: [
          EmptyState(
            icon: Icons.devices_other_rounded,
            title: 'No workers yet',
            message: ClusterService.isDesktop
                ? 'On the other device, open the cluster screen, choose Worker, '
                    'then enter the IP and port it shows here.'
                : 'On each other device, open Phone cluster, choose Worker, '
                    'then scan the QR code it shows.',
          ),
        ])
      else
        AppGroup(dividerIndent: 60, children: [
          for (final w in cluster.workers)
            AppRow(
              icon: Icons.smartphone_rounded,
              title: w.model ?? w.name,
              subtitle: [
                w.endpoint,
                if (w.ramMb != null) '${_gb(w.ramMb!)} free',
                if (w.bandwidth != null) '${w.bandwidth!.toStringAsFixed(1)} GB/s',
              ].join(' · '),
              trailing: IconButton(
                icon: Icon(Icons.close_rounded, color: t.muted),
                tooltip: 'Remove',
                onPressed: () => cluster.remove(w),
              ),
            ),
        ]),
      const SectionFootnote(
        'Used the next time you load a GGUF model. If the model fits on this '
        'device you can keep it here, which is faster. If it doesn\'t, the '
        'fastest devices get the biggest share and the ones that aren\'t '
        'needed are left out.',
      ),
      const SectionHeader('Other ways to add'),
      Row(children: [
        PillButton(
          label: cluster.isScanning.value ? 'Searching…' : 'Find nearby',
          icon: Icons.wifi_find_rounded,
          onPressed: cluster.isScanning.value ? null : cluster.scanNearby,
        ),
        const SizedBox(width: 10),
        PillButton(
          label: 'Enter IP',
          icon: Icons.keyboard_rounded,
          onPressed: () => _enterIp(context),
        ),
      ]),
      if (cluster.found.isNotEmpty) ...[
        const SizedBox(height: 12),
        AppGroup(dividerIndent: 60, children: [
          for (final w in cluster.found)
            AppRow(
              icon: Icons.smartphone_rounded,
              title: w.model ?? w.name,
              subtitle: w.endpoint,
              trailing: PillButton(
                label: 'Add',
                primary: true,
                onPressed: () => _report(cluster.addFound(w)),
              ),
            ),
        ]),
      ],
    ];
  }

  Future<void> _scanQr() async {
    final code = await Get.to<String>(() => const _QrScanPage());
    if (code != null) await _report(cluster.addFromQr(code));
  }

  /// Desktop has no camera: the worker's link can be copied from its screen
  /// and pasted here (it carries the IP, port and worker ID).
  Future<void> _pasteLink(BuildContext context) async {
    final ctrl = TextEditingController();
    final link = await showAppSheet<String>(
      context,
      title: 'Paste a worker link',
      subtitle: 'Shown on the other device under its QR code',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            minLines: 1,
            maxLines: 3,
            keyboardType: TextInputType.url,
            decoration: appInputDecoration(ctx, hint: 'privatelm://worker?host=…'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          const SizedBox(height: 16),
          PrimaryButton(label: 'Add', onPressed: () => Navigator.pop(ctx, ctrl.text)),
        ],
      ),
    );
    ctrl.dispose();
    if (link != null) await _report(cluster.addFromQr(link));
  }

  Future<void> _enterIp(BuildContext context) async {
    final ctrl = TextEditingController();
    final input = await showAppSheet<String>(
      context,
      title: 'Enter worker IP',
      subtitle: 'Shown under the worker\'s QR code',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: appInputDecoration(ctx,
                hint: '192.168.1.20:${ClusterBackend.defaultPort}'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          const SizedBox(height: 16),
          PrimaryButton(label: 'Add', onPressed: () => Navigator.pop(ctx, ctrl.text)),
        ],
      ),
    );
    ctrl.dispose();
    if (input != null) await _report(cluster.addManual(input));
  }

  Future<void> _report(Future<String?> adding) async {
    final error = await adding;
    if (error != null) {
      showToast('Couldn\'t add worker', error, tone: ToastTone.error);
    } else {
      showToast('Worker added', 'Used the next time you load a GGUF model.',
          tone: ToastTone.success);
    }
  }
}

String _gb(num mb) => '${(mb / 1024).toStringAsFixed(1)} GB';

/// How the loaded model is spread across phones: a stacked bar and legend.
class _SplitCard extends StatelessWidget {
  final List<ClusterShare> shares;
  const _SplitCard({required this.shares});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final colors = [t.accent, t.green, t.orange, const Color(0xFFAF52DE), t.red];
    final total = shares.fold<double>(0, (a, s) => a + s.mb);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Loaded model', style: t.bodyStrong),
        const SizedBox(height: 2),
        Text(
            'Running on ${shares.length} '
            '${ClusterService.isDesktop ? 'devices' : 'phones'} · ${_gb(total)}',
            style: t.caption),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 12,
            child: Row(children: [
              for (var i = 0; i < shares.length; i++)
                Expanded(
                  flex: (shares[i].mb / total * 1000).round().clamp(1, 1000),
                  child: Container(
                    margin: EdgeInsets.only(right: i == shares.length - 1 ? 0 : 2),
                    color: colors[i % colors.length],
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        for (var i = 0; i < shares.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              StatusDot(colors[i % colors.length], size: 10),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  shares[i].isThisPhone
                      ? '${shares[i].name} '
                          '(${ClusterService.isDesktop ? 'this PC' : 'this phone'})'
                      : shares[i].name,
                  style: t.body,
                ),
              ),
              Text('${(shares[i].mb / total * 100).round()}%', style: t.bodyStrong),
              const SizedBox(width: 10),
              SizedBox(
                width: 58,
                child: Text(_gb(shares[i].mb), textAlign: TextAlign.right, style: t.caption),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      Text(value, style: t.bodyStrong),
      const SizedBox(height: 2),
      Text(label, style: t.small, textAlign: TextAlign.center),
    ]);
  }
}

/// Live indicator for an active connection.
class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 56,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Stack(alignment: Alignment.center, children: [
          Container(
            width: 24 + 32 * _c.value,
            height: 24 + 32 * _c.value,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withValues(alpha: 0.35 * (1 - _c.value)),
            ),
          ),
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
            child: const Icon(Icons.hub_rounded, size: 14, color: Colors.white),
          ),
        ]),
      ),
    );
  }
}

/// Full-screen camera that returns the first QR code it reads.
class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  final MobileScannerController _controller =
      MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final value = capture.barcodes
        .map((b) => b.rawValue ?? '')
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (value.isEmpty) return;
    _done = true;
    Get.back(result: value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan worker QR code'),
      ),
      body: Stack(children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        const Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Text(
            'Point at the QR code on the worker phone',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ]),
    );
  }
}
