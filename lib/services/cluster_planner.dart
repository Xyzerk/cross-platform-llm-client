// Cluster load planning, kept free of Flutter/GetX so it can be tested on
// every platform (docs/windows-port-plan.md §10, Phase 7).
//
// The master runs the model; workers hold part of its layers. Devices take
// turns on every token, so the split follows memory read speed.
library;

import 'dart:math' as math;

import 'package:llama_flutter_android/llama_flutter_android.dart';

/// A device the master can put layers on, for planning a load.
class ClusterDevice {
  /// The worker this device stands for, or null for the master itself.
  final ClusterWorker? worker;
  final double capacityMb;

  /// Memory read speed in GB/s; token generation follows it closely.
  final double speed;

  /// Round-trip latency in milliseconds (Tailscale relayed peers). Null when
  /// the transport is direct (LAN, USB, adb) or unknown.
  final int? latencyMs;

  /// How much of the model this device was given, in MB.
  double assignedMb = 0;

  ClusterDevice(this.worker, this.capacityMb, this.speed, {this.latencyMs});

  /// [speed] discounted for latency: a relayed peer does less work per token
  /// than the same device on the LAN. A 150 ms relay keeps ~12% of its speed
  /// at the 20 ms constant used here.
  double get effectiveSpeed => latencyMs == null || latencyMs! <= 0
      ? speed
      : speed / (1 + latencyMs! / 20);
}

/// Fastest first, each up to its free memory, until the model is placed.
void fillFastestFirst(List<ClusterDevice> devices, double needMb) {
  final bySpeed = [...devices]
    ..sort((a, b) => b.effectiveSpeed.compareTo(a.effectiveSpeed));
  var left = needMb;
  for (final d in bySpeed) {
    d.assignedMb = math.min(d.capacityMb, left);
    left -= d.assignedMb;
  }
}

/// Shares in proportion to speed, capped at each device's free memory
/// (what a capped device can't take goes to the others).
void splitBySpeed(List<ClusterDevice> devices, double needMb) {
  var open = [...devices];
  var left = needMb;
  while (open.isNotEmpty && left > 0.5) {
    final speedSum = open.fold<double>(0, (a, d) => a + d.effectiveSpeed);
    final capped = [
      for (final d in open)
        if (d.assignedMb + left * d.effectiveSpeed / speedSum >= d.capacityMb)
          d,
    ];
    if (capped.isEmpty) {
      for (final d in open) {
        d.assignedMb += left * d.effectiveSpeed / speedSum;
      }
      left = 0;
    } else {
      for (final d in capped) {
        left -= d.capacityMb - d.assignedMb;
        d.assignedMb = d.capacityMb;
      }
      open = open.where((d) => !capped.contains(d)).toList();
    }
  }
}

/// "12.3 GB" for a size in MB.
String formatGb(double mb) => '${(mb / 1024).toStringAsFixed(1)} GB';
