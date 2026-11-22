import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:material_ui/material_ui.dart';

import '../presets/preset_api.dart';

final _serviceId = UUID.fromString('af907d49-2747-4a01-9ec4-345a38cf3390');
final _tokenId = UUID.fromString('af907d49-2747-4a01-9ec4-345a38cf3391');

class NearbyScreen extends StatefulWidget {
  const NearbyScreen({super.key, required this.api});
  final PresetApi api;

  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen>
    with WidgetsBindingObserver {
  final _devices = <UUID, (String, DateTime)>{};
  final _lastRead = <UUID, DateTime>{};
  CentralManager? _central;
  PeripheralManager? _peripheral;
  StreamSubscription<DiscoveredEventArgs>? _discoveries;
  StreamSubscription<GATTCharacteristicReadRequestedEventArgs>? _reads;
  StreamSubscription<BluetoothLowEnergyStateChangedEventArgs>? _stateChanges;
  Timer? _timer;
  Future<void> _cleanup = Future.value();
  String? _visibleCode;
  String? _error;
  bool _busy = false;
  bool _reading = false;
  bool _polling = false;
  bool _stopping = false;
  bool _registered = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_stop());
    }
  }

  bool _current(int generation) => mounted && generation == _generation;

  Future<void> _authorize(BluetoothLowEnergyManager manager) async {
    if (manager.state == BluetoothLowEnergyState.unknown) {
      await manager.stateChanged
          .firstWhere((event) => event.state != BluetoothLowEnergyState.unknown)
          .timeout(const Duration(seconds: 8));
    }
    if (Platform.isAndroid &&
        manager.state == BluetoothLowEnergyState.unauthorized) {
      if (!await manager.authorize()) throw StateError('Bluetooth denied');
      // The Android plugin reports the grant before refreshing cached state.
      return;
    }
    if (manager.state != BluetoothLowEnergyState.poweredOn) {
      throw StateError('Bluetooth unavailable');
    }
  }

  void _watchState(BluetoothLowEnergyManager manager) {
    _stateChanges = manager.stateChanged.listen((event) {
      if (event.state != BluetoothLowEnergyState.poweredOn) {
        unawaited(_stop(error: '블루투스가 꺼졌거나 권한이 해제됐어요.'));
      }
    });
  }

  Future<void> _scan() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    final central = CentralManager();
    try {
      await _authorize(central);
      if (!_current(generation)) return;
      _central = central;
      _watchState(central);
      _discoveries = central.discovered.listen((event) {
        unawaited(_readToken(central, event.peripheral, generation));
      });
      await central.startDiscovery(serviceUUIDs: [_serviceId]);
      if (!_current(generation)) {
        await _ignoreFailure(central.stopDiscovery);
        return;
      }
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      _timer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (!DateTime.now().isBefore(deadline)) {
          unawaited(_stop(error: '탐색 시간이 끝났어요. 다시 탐색하거나 초대 코드를 사용해 주세요.'));
        } else if (mounted) {
          setState(
            () => _devices.removeWhere(
              (_, device) =>
                  DateTime.now().difference(device.$2).inSeconds >= 20,
            ),
          );
        }
      });
      setState(() => _busy = false);
    } catch (_) {
      if (_current(generation)) {
        await _stop(error: '주변 기기를 탐색할 수 없어요. 블루투스와 권한을 확인해 주세요.');
      }
    }
  }

  Future<void> _readToken(
    CentralManager central,
    Peripheral device,
    int generation,
  ) async {
    final now = DateTime.now();
    final last = _lastRead[device.uuid];
    if (!_current(generation) ||
        _reading ||
        (last != null && now.difference(last).inSeconds < 8)) {
      return;
    }
    _reading = true;
    _lastRead[device.uuid] = now;
    try {
      await central.connect(device).timeout(const Duration(seconds: 4));
      if (!_current(generation)) return;
      final services = await central
          .discoverGATT(device)
          .timeout(const Duration(seconds: 3));
      final service = services.firstWhere((item) => item.uuid == _serviceId);
      final characteristic = service.characteristics.firstWhere(
        (item) => item.uuid == _tokenId,
      );
      final bytes = await central
          .readCharacteristic(device, characteristic)
          .timeout(const Duration(seconds: 3));
      if (_current(generation) && bytes.length == 16) {
        final token = bytes
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
        setState(() => _devices[device.uuid] = (token, DateTime.now()));
      }
    } catch (_) {
      // A peripheral can leave range before the read completes.
    } finally {
      await _ignoreFailure(() => central.disconnect(device));
      _reading = false;
    }
  }

  Future<void> _invite(String token) async {
    if (_busy) return;
    final generation = _generation;
    setState(() => _busy = true);
    try {
      final room = await widget.api.sessionRequest(
        'POST',
        '',
        body: {'token': token},
      );
      if (_current(generation)) {
        await _finish(room);
      } else {
        await _ignoreFailure(() async {
          await widget.api.sessionRequest('DELETE', '/${room['id']}');
        });
      }
    } on Exception {
      if (_current(generation)) {
        setState(() {
          _error = '요청을 보낼 수 없어요. 상대가 아직 연결을 기다리는지 확인해 주세요.';
          _busy = false;
        });
      }
    }
  }

  Future<void> _advertise() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    final peripheral = PeripheralManager();
    try {
      await _authorize(peripheral);
      if (!_current(generation)) return;
      final registration = await widget.api.discoveryRequest('POST');
      if (!_current(generation)) {
        await _ignoreFailure(_revoke);
        return;
      }
      _registered = true;
      _peripheral = peripheral;
      _watchState(peripheral);
      final token = registration['token'] as String;
      final expires = DateTime.parse(registration['expiresAt'] as String);
      final bytes = Uint8List.fromList([
        for (var i = 0; i < token.length; i += 2)
          int.parse(token.substring(i, i + 2), radix: 16),
      ]);
      _reads = peripheral.characteristicReadRequested.listen((event) {
        unawaited(
          _ignoreFailure(
            () => peripheral.respondReadRequestWithValue(
              event.request,
              value: bytes,
            ),
          ),
        );
      });
      await peripheral.addService(
        GATTService(
          uuid: _serviceId,
          isPrimary: true,
          includedServices: [],
          characteristics: [
            GATTCharacteristic.mutable(
              uuid: _tokenId,
              properties: [GATTCharacteristicProperty.read],
              permissions: [GATTCharacteristicPermission.read],
              descriptors: [],
            ),
          ],
        ),
      );
      if (!_current(generation)) {
        await _ignoreFailure(peripheral.removeAllServices);
        return;
      }
      await peripheral.startAdvertising(
        Advertisement(serviceUUIDs: [_serviceId]),
      );
      if (!_current(generation)) {
        await _ignoreFailure(peripheral.stopAdvertising);
        return;
      }
      setState(() {
        _visibleCode = token.substring(0, 6).toUpperCase();
        _busy = false;
      });
      _timer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (!DateTime.now().isBefore(expires)) {
          unawaited(_stop(error: '주변 기기 연결 대기 시간이 끝났어요.'));
        } else {
          unawaited(_poll(generation));
        }
      });
    } catch (_) {
      if (_current(generation)) {
        await _stop(error: '주변 기기에 표시할 수 없어요. 블루투스와 권한을 확인해 주세요.');
      }
    }
  }

  Future<void> _poll(int generation) async {
    if (_polling) return;
    _polling = true;
    try {
      final room = await widget.api.discoveryRequest('GET');
      if (_current(generation) && room['id'] != null) await _finish(room);
    } on Exception {
      if (_current(generation)) await _stop(error: '연결 요청을 확인할 수 없어요.');
    } finally {
      _polling = false;
    }
  }

  Future<void> _finish(Map<String, dynamic> room) async {
    // Release the radio before opening the session screen.
    await _stop();
    if (mounted) Navigator.pop(context, room);
  }

  Future<void> _revoke() async {
    await widget.api.discoveryRequest('DELETE');
  }

  Future<void> _ignoreFailure(Future<void> Function() action) async {
    try {
      await action().timeout(const Duration(seconds: 4));
    } catch (_) {
      // Both the local discovery window and server token have a time limit.
    }
  }

  Future<void> _stop({String? error}) {
    if (_stopping) return _cleanup;
    ++_generation;
    _timer?.cancel();
    _stopping = true;
    if (mounted) setState(() => _busy = true);
    final central = _central;
    final peripheral = _peripheral;
    final registered = _registered;
    _registered = false;
    _central = null;
    _peripheral = null;
    _cleanup = () async {
      await _discoveries?.cancel();
      await _reads?.cancel();
      await _stateChanges?.cancel();
      if (central != null) await _ignoreFailure(central.stopDiscovery);
      if (peripheral != null) {
        await _ignoreFailure(peripheral.stopAdvertising);
        await _ignoreFailure(peripheral.removeAllServices);
      }
      if (registered) await _ignoreFailure(_revoke);
      _devices.clear();
      _lastRead.clear();
      _visibleCode = null;
      _error = error;
      _stopping = false;
      if (mounted) setState(() => _busy = false);
    }();
    return _cleanup;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('주변 기기')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(error),
          ),
        if (_central == null && _peripheral == null) ...[
          FilledButton(
            onPressed: _busy ? null : _scan,
            child: const Text('주변 기기 찾기'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : _advertise,
            child: const Text('내 기기 표시'),
          ),
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('초대 코드 사용'),
          ),
        ],
        if (_visibleCode case final code?)
          ListTile(
            title: Text('내 기기 $code'),
            subtitle: const Text('연결 요청을 기다리는 중'),
          ),
        if (_central != null && _devices.isEmpty)
          const ListTile(title: Text('주변 기기를 찾는 중')),
        for (final (token, _) in _devices.values)
          ListTile(
            title: Text('주변 기기 ${token.substring(0, 6).toUpperCase()}'),
            onTap: _busy ? null : () => _invite(token),
            trailing: const Icon(Icons.chevron_right),
          ),
        if (_central != null || _peripheral != null)
          TextButton(
            onPressed: _busy ? null : () => _stop(),
            child: const Text('중지'),
          ),
      ],
    ),
  );
}
