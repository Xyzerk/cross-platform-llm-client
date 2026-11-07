// Cluster load planning, kept free of Flutter/GetX so it can be tested on
// every platform (docs/windows-port-plan.md §10, Phase 7).
//
// The master runs the model; workers hold part of its layers. Devices take
// turns on every token, so the split follows memory read speed.
library;

import 'dart:math' as math;

import 'package:llama_flutter_android/llama_flutter_android.dart';

/// A device the master can put layers on, for planning a load.
class ClusterPhone {
  /// The worker this device stands for, or null for the master itself.
  final ClusterWorker? worker;
  final double capacityMb;

  /// Memory read speed in GB/s; token generation follows it closely.
  final double speed;

  /// How much of the model this device was given, in MB.
  double assignedMb = 0;

  ClusterPhone(this.worker, this.capacityMb, this.speed);
}

/// Fastest first, each up to its free memory, until the model is placed.
void fillFastestFirst(List<ClusterPhone> phones, double needMb) {
  final bySpeed = [...phones]..sort((a, b) => b.speed.compareTo(a.speed));
  var left = needMb;
  for (final p in bySpeed) {
    p.assignedMb = math.min(p.capacityMb, left);
    left -= p.assignedMb;
  }
}

/// Shares in proportion to speed, capped at each device's free memory
/// (what a capped device can't take goes to the others).
void splitBySpeed(List<ClusterPhone> phones, double needMb) {
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

/// "12.3 GB" for a size in MB.
String formatGb(double mb) => '${(mb / 1024).toStringAsFixed(1)} GB';
