import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:privatelm/services/cluster_planner.dart';

ClusterWorker worker(String name) =>
    ClusterWorker(name: name, host: '192.168.1.10', port: 50052);

void main() {
  group('fillFastestFirst', () {
    test('fills the fastest devices first, up to their free memory', () {
      final devices = [
        ClusterDevice(null, 1000, 5),
        ClusterDevice(worker('fast'), 2000, 20),
        ClusterDevice(worker('slow'), 3000, 10),
      ];

      fillFastestFirst(devices, 2500);

      expect(devices[1].assignedMb, 2000);
      expect(devices[2].assignedMb, 500);
      expect(devices[0].assignedMb, 0);
    });

    test('leaves devices unused when the model fits on the fastest ones', () {
      final devices = [
        ClusterDevice(worker('fast'), 4000, 30),
        ClusterDevice(worker('slow'), 4000, 10),
      ];

      fillFastestFirst(devices, 1000);

      expect(devices[0].assignedMb, 1000);
      expect(devices[1].assignedMb, 0);
    });

    test('places the whole model when total capacity is enough', () {
      final devices = [
        ClusterDevice(null, 500, 5),
        ClusterDevice(worker('a'), 500, 20),
        ClusterDevice(worker('b'), 500, 10),
      ];

      fillFastestFirst(devices, 1200);

      expect(devices.fold<double>(0, (sum, p) => sum + p.assignedMb), 1200);
    });
  });

  group('splitBySpeed', () {
    test('shares in proportion to speed', () {
      final devices = [
        ClusterDevice(null, 10000, 30),
        ClusterDevice(worker('a'), 10000, 10),
      ];

      splitBySpeed(devices, 1000);

      expect(devices[0].assignedMb, closeTo(750, 0.01));
      expect(devices[1].assignedMb, closeTo(250, 0.01));
    });

    test('caps a device at its free memory and gives the rest to the others',
        () {
      final devices = [
        ClusterDevice(null, 100, 30),
        ClusterDevice(worker('a'), 10000, 10),
      ];

      splitBySpeed(devices, 1000);

      expect(devices[0].assignedMb, 100);
      expect(devices[1].assignedMb, closeTo(900, 0.01));
    });

    test('respects every cap', () {
      final devices = [
        ClusterDevice(null, 300, 30),
        ClusterDevice(worker('a'), 300, 20),
        ClusterDevice(worker('b'), 300, 10),
      ];

      splitBySpeed(devices, 800);

      expect(devices[0].assignedMb, 300);
      expect(devices[1].assignedMb, 300);
      expect(devices[2].assignedMb, 200);
    });

    test('does nothing when the model is already placed', () {
      final devices = [ClusterDevice(null, 1000, 10)];

      splitBySpeed(devices, 0);

      expect(devices.single.assignedMb, 0);
    });
  });

  test('latency discounts a relayed device\'s share', () {
    final devices = [
      ClusterDevice(worker('lan'), 10000, 10),
      ClusterDevice(worker('relay'), 10000, 10, latencyMs: 180),
    ];

    splitBySpeed(devices, 1000);

    expect(devices[0].assignedMb, greaterThan(devices[1].assignedMb * 5));
  });

  test('formatGb rounds to one decimal place', () {
    expect(formatGb(1024), '1.0 GB');
    expect(formatGb(1536), '1.5 GB');
    expect(formatGb(0), '0.0 GB');
  });
}
