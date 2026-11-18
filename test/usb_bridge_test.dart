import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/usb_bridge_service.dart';

void main() {
  group('UsbBridgeService.parseDevices', () {
    test('reads serial, state and properties', () {
      final devices = UsbBridgeService.parseDevices('''
List of devices attached
R58M123ABC            device product:beyond1q model:SM_G973F device:beyond1q transport_id:3
emulator-5554         device product:sdk_gphone64 model:sdk_gphone64 transport_id:1

''');

      expect(devices, hasLength(2));
      expect(devices.first.serial, 'R58M123ABC');
      expect(devices.first.usable, isTrue);
      expect(devices.first.label, 'SM G973F');
      expect(devices.last.state, 'device');
    });

    test('keeps unauthorized and no-permission devices with a reason', () {
      final devices = UsbBridgeService.parseDevices('''
List of devices attached
ABC123	unauthorized usb:1-1 transport_id:2
????????????	no permissions (user in plugdev group; are your udev rules wrong?); see [http://developer.android.com/tools/device.html]
''');

      expect(devices, hasLength(2));
      expect(devices[0].state, 'unauthorized');
      expect(devices[0].usable, isFalse);
      expect(devices[0].problem, contains('Authorize'));
      expect(devices[1].state, 'no permissions');
      expect(devices[1].problem, contains('plugdev'));
    });

    test('ignores headings and blank lines', () {
      expect(UsbBridgeService.parseDevices('List of devices attached\n\n'),
          isEmpty);
    });
  });

  test('allocatePort skips ports already in use', () {
    expect(UsbBridgeService.allocatePort(const []), 50100);
    expect(UsbBridgeService.allocatePort(const [50100, 50101]), 50102);
    expect(UsbBridgeService.allocatePort(const [50102, 50100]), 50101);
  });

  group('commands', () {
    late List<List<String>> calls;

    UsbBridgeService service({int exitCode = 0}) {
      calls = [];
      return UsbBridgeService(
        adbPath: '/usr/bin/adb',
        runner: (exe, args) async {
          calls.add([exe, ...args]);
          return ProcessResult(
              1, exitCode, '', exitCode == 0 ? '' : 'error text');
        },
      );
    }

    test('forward and reverse map the worker port', () async {
      final adb = service();
      await adb.forward('SERIAL', 50102);
      await adb.reverse('SERIAL', 50100);

      expect(calls[0], [
        '/usr/bin/adb',
        '-s',
        'SERIAL',
        'forward',
        'tcp:50102',
        'tcp:50052'
      ]);
      expect(calls[1], [
        '/usr/bin/adb',
        '-s',
        'SERIAL',
        'reverse',
        'tcp:50100',
        'tcp:50052'
      ]);
    });

    test('removeBridge uses the right direction', () async {
      final adb = service();
      await adb.removeBridge(
          const UsbBridge(serial: 'S', localPort: 50101, reverse: false));
      await adb.removeBridge(
          const UsbBridge(serial: 'S', localPort: 50102, reverse: true));

      expect(calls[0],
          ['/usr/bin/adb', '-s', 'S', 'forward', '--remove', 'tcp:50101']);
      expect(calls[1],
          ['/usr/bin/adb', '-s', 'S', 'reverse', '--remove', 'tcp:50102']);
    });

    test('a failed adb command is reported, not swallowed', () async {
      final adb = service(exitCode: 1);

      await expectLater(
        adb.forward('SERIAL', 50100),
        throwsA(isA<AdbCommandException>()),
      );
    });

    test('missing adb is a clear error', () async {
      final adb = UsbBridgeService(adbPath: '');

      expect(adb.available, isFalse);
      await expectLater(adb.devices(), throwsA(isA<AdbUnavailableException>()));
    });
  });

  test('UsbBridge maps round-trip', () {
    const bridge = UsbBridge(serial: 'S', localPort: 50100, reverse: true);

    final copy = UsbBridge.fromMap(bridge.toMap());

    expect(copy.serial, 'S');
    expect(copy.localPort, 50100);
    expect(copy.reverse, isTrue);
  });
}
