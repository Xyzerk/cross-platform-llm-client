import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:privatelm/services/cluster_planner.dart';

ClusterWorker worker(String name) =>
    ClusterWorker(name: name, host: '192.168.1.10', port: 50052);

void main() {
  group('fillFastestFirst', () {
    test('fills the fastest devices first, up to their free memory', () {
      final phones = [
        ClusterPhone(null, 1000, 5),
        ClusterPhone(worker('fast'), 2000, 20),
        ClusterPhone(worker('slow'), 3000, 10),
      ];

      fillFastestFirst(phones, 2500);

      expect(phones[1].assignedMb, 2000);
      expect(phones[2].assignedMb, 500);
      expect(phones[0].assignedMb, 0);
    });

    test('leaves devices unused when the model fits on the fastest ones', () {
      final phones = [
        ClusterPhone(worker('fast'), 4000, 30),
        ClusterPhone(worker('slow'), 4000, 10),
      ];

      fillFastestFirst(phones, 1000);

      expect(phones[0].assignedMb, 1000);
      expect(phones[1].assignedMb, 0);
    });

    test('places the whole model when total capacity is enough', () {
      final phones = [
        ClusterPhone(null, 500, 5),
        ClusterPhone(worker('a'), 500, 20),
        ClusterPhone(worker('b'), 500, 10),
      ];

      fillFastestFirst(phones, 1200);

      expect(phones.fold<double>(0, (sum, p) => sum + p.assignedMb), 1200);
    });
  });

  group('splitBySpeed', () {
    test('shares in proportion to speed', () {
      final phones = [
        ClusterPhone(null, 10000, 30),
        ClusterPhone(worker('a'), 10000, 10),
      ];

      splitBySpeed(phones, 1000);

      expect(phones[0].assignedMb, closeTo(750, 0.01));
      expect(phones[1].assignedMb, closeTo(250, 0.01));
    });

    test('caps a device at its free memory and gives the rest to the others',
        () {
      final phones = [
        ClusterPhone(null, 100, 30),
        ClusterPhone(worker('a'), 10000, 10),
      ];

      splitBySpeed(phones, 1000);

      expect(phones[0].assignedMb, 100);
      expect(phones[1].assignedMb, closeTo(900, 0.01));
    });

    test('respects every cap', () {
      final phones = [
        ClusterPhone(null, 300, 30),
        ClusterPhone(worker('a'), 300, 20),
        ClusterPhone(worker('b'), 300, 10),
      ];

      splitBySpeed(phones, 800);

      expect(phones[0].assignedMb, 300);
      expect(phones[1].assignedMb, 300);
      expect(phones[2].assignedMb, 200);
    });

    test('does nothing when the model is already placed', () {
      final phones = [ClusterPhone(null, 1000, 10)];

      splitBySpeed(phones, 0);

      expect(phones.single.assignedMb, 0);
    });
  });

  test('formatGb rounds to one decimal place', () {
    expect(formatGb(1024), '1.0 GB');
    expect(formatGb(1536), '1.5 GB');
    expect(formatGb(0), '0.0 GB');
  });
}
