import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gal/gal.dart';
import 'package:material_ui/material_ui.dart';

import '../presets/preset_api.dart';
import 'nearby_screen.dart';

class SharingScreen extends StatefulWidget {
  const SharingScreen({super.key, required this.api});
  final PresetApi api;

  @override
  State<SharingScreen> createState() => _SharingScreenState();
}

class _SharingScreenState extends State<SharingScreen>
    with WidgetsBindingObserver {
  final _code = TextEditingController();
  final _renderer = RTCVideoRenderer();
  final _pendingIce = <RTCIceCandidate>[];
  Future<void> _events = Future.value();
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  RTCPeerConnection? _peer;
  MediaStream? _camera;
  String? _id;
  String? _inviteCode;
  String? _error;
  bool _host = false;
  bool _nearby = false;
  bool _busy = false;
  bool _rendererReady = false;
  bool _viewerJoined = false;
  bool _accepted = false;
  bool _peerOnline = false;
  String? _peerEpoch;
  bool _descriptionSet = false;
  bool _connected = false;
  bool _takingFrame = false;
  int _generation = 0;
  Timer? _connectionTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_end());
    }
  }

  Future<void> _enter({required bool host}) async {
    if (_busy || _id != null) return;
    final code = _code.text.trim().toUpperCase();
    if (!host &&
        !RegExp(r'^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$').hasMatch(code)) {
      setState(() => _error = '8자리 초대 코드를 입력해 주세요.');
      return;
    }
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _host = host;
    });
    try {
      final room = await widget.api.sessionRequest(
        'POST',
        host ? '' : '/join',
        body: host ? null : {'code': code},
      );
      final id = room['id'] as String;
      if (!mounted || generation != _generation) {
        await _endServer(id);
        return;
      }
      await _openRoom(room, generation);
    } on Exception {
      if (generation == _generation) {
        await _end(error: '공유 세션에 연결하지 못했어요. 코드를 확인하고 다시 시도해 주세요.');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _openRoom(Map<String, dynamic> room, int generation) async {
    final id = room['id'] as String;
    _id = id;
    _host = room['role'] == 'host';
    _nearby = room['nearby'] == true;
    _inviteCode = room['code'] as String?;
    _viewerJoined = room['viewerJoined'] as bool;
    _accepted = room['state'] == 'accepted';
    await _connectSignaling(id, generation);
  }

  Future<void> _openNearby() async {
    final room = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => NearbyScreen(api: widget.api)),
    );
    if (!mounted || room == null) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _openRoom(room, generation);
    } on Exception {
      if (generation == _generation) {
        await _end(error: '주변 기기와 연결하지 못했어요.');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _connectSignaling(String id, int generation) async {
    final socket = await widget.api.openSignaling(id);
    if (!mounted || generation != _generation) {
      await socket.close();
      return;
    }
    _socket = socket;
    socket.pingInterval = const Duration(seconds: 10);
    _subscription = socket.listen(
      (event) {
        _events = _events.then((_) async {
          if (!mounted || generation != _generation) return;
          try {
            await _handleEvent(
              jsonDecode(event as String) as Map<String, dynamic>,
              generation,
            );
          } on Exception {
            await _end(error: '영상 연결을 시작하지 못했어요.');
          }
        });
      },
      onError: (Object _) => unawaited(_reconnect(generation)),
      onDone: () => unawaited(_reconnect(generation)),
      cancelOnError: true,
    );
  }

  Future<void> _reconnect(int generation) async {
    final id = _id;
    if (!mounted ||
        id == null ||
        generation != _generation ||
        _socket == null) {
      return;
    }
    _socket = null;
    await _subscription?.cancel();
    _subscription = null;
    await _events;
    if (!mounted || generation != _generation) return;
    await _closePeer();
    for (var attempt = 0; attempt < 2; attempt++) {
      await Future<void>.delayed(Duration(seconds: attempt + 1));
      if (!mounted || generation != _generation) return;
      try {
        final room = await widget.api.sessionRequest('GET', '/$id');
        if (room['state'] == 'ended') break;
        await _connectSignaling(id, generation);
        return;
      } on Exception {
        // The second attempt may succeed after a brief network interruption.
      }
    }
    if (generation == _generation) await _end(error: '공유 연결이 끊겼어요.');
  }

  Future<void> _handleEvent(
    Map<String, dynamic> message,
    int generation,
  ) async {
    switch (message['type']) {
      case 'state':
        if (message['state'] == 'ended') {
          await _end(notifyServer: false, error: '공유가 종료됐어요.');
          return;
        }
        final online = message['peerOnline'] == true;
        final epoch = message['peerEpoch'] as String?;
        if (_peerEpoch != null && _peerEpoch != epoch) {
          await _closePeer();
          if (!mounted || generation != _generation) return;
        }
        _peerEpoch = epoch;
        setState(() {
          _viewerJoined = message['viewerJoined'] == true;
          _accepted = message['state'] == 'accepted';
          _peerOnline = online;
        });
        if (!online) {
          await _closePeer();
          return;
        }
        if (_accepted && _host && _peer == null) {
          final peer = await _openPeer(generation);
          if (peer == null) return;
          final offer = await peer.createOffer();
          await peer.setLocalDescription(offer);
          _send({'type': 'offer', 'sdp': offer.sdp});
        }
      case 'offer':
        if (_host) return;
        final peer = _peer ?? await _openPeer(generation);
        if (peer == null) return;
        await _setRemote(peer, message['sdp'] as String, 'offer');
        final answer = await peer.createAnswer();
        await peer.setLocalDescription(answer);
        _send({'type': 'answer', 'sdp': answer.sdp});
      case 'answer':
        if (_peer case final peer?) {
          await _setRemote(peer, message['sdp'] as String, 'answer');
        }
      case 'ice':
        final candidate = message['candidate'] as Map<String, dynamic>;
        final ice = RTCIceCandidate(
          candidate['candidate'] as String?,
          candidate['sdpMid'] as String?,
          candidate['sdpMLineIndex'] as int?,
        );
        if (_peer case final peer? when _descriptionSet) {
          await peer.addCandidate(ice);
        } else if (_pendingIce.length < 64) {
          _pendingIce.add(ice);
        }
    }
  }

  Future<RTCPeerConnection?> _openPeer(int generation) async {
    final id = _id;
    if (id == null) return null;
    if (!_rendererReady) {
      await _renderer.initialize();
      if (!mounted || generation != _generation) {
        await _renderer.dispose();
        return null;
      }
      _rendererReady = true;
    }
    final ice = await widget.api.sessionRequest('GET', '/$id/ice-config');
    final peer = await createPeerConnection({
      'sdpSemantics': 'unified-plan',
      'iceServers': ice['iceServers'],
    });
    if (!mounted || generation != _generation) {
      await peer.dispose();
      return null;
    }
    _peer = peer;
    peer.onTrack = (event) {
      if (_peer != peer ||
          _host ||
          event.track.kind != 'video' ||
          event.streams.isEmpty) {
        return;
      }
      _renderer.srcObject = event.streams.first;
      if (mounted) setState(() {});
    };
    peer.onIceCandidate = (candidate) {
      if (_peer == peer && candidate.candidate?.isNotEmpty == true) {
        _send({'type': 'ice', 'candidate': candidate.toMap()});
      }
    };
    peer.onConnectionState = (state) {
      if (_peer != peer || !mounted) return;
      final up =
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
      setState(() => _connected = up);
      _connectionTimer?.cancel();
      if (!up) _watchConnection(generation);
    };
    _watchConnection(generation);
    if (_host) {
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'facingMode': 'environment',
          'width': {'ideal': 960},
          'height': {'ideal': 540},
          'frameRate': {'ideal': 24, 'max': 30},
        },
      });
      if (!mounted || generation != _generation || _peer != peer) {
        await _disposeStream(stream);
        return null;
      }
      _camera = stream;
      _renderer.srcObject = stream;
      for (final track in stream.getVideoTracks()) {
        await peer.addTrack(track, stream);
      }
      if (mounted) setState(() {});
    }
    return peer;
  }

  void _watchConnection(int generation) {
    _connectionTimer?.cancel();
    _connectionTimer = Timer(const Duration(seconds: 20), () {
      if (generation == _generation && !_connected) {
        unawaited(_end(error: '영상 연결 시간이 초과됐어요.'));
      }
    });
  }

  Future<void> _setRemote(
    RTCPeerConnection peer,
    String sdp,
    String type,
  ) async {
    await peer.setRemoteDescription(RTCSessionDescription(sdp, type));
    if (_peer != peer) return;
    _descriptionSet = true;
    final pending = [..._pendingIce];
    _pendingIce.clear();
    for (final candidate in pending) {
      await peer.addCandidate(candidate);
    }
  }

  void _send(Map<String, dynamic> message) {
    final socket = _socket;
    if (socket?.readyState == WebSocket.open) socket!.add(jsonEncode(message));
  }

  Future<void> _approve() async {
    final id = _id;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.sessionRequest('POST', '/$id/accept');
    } on Exception {
      await _end(error: '공유 요청을 수락하지 못했어요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveFrame() async {
    final stream = _camera;
    if (stream == null || _takingFrame) return;
    setState(() => _takingFrame = true);
    try {
      final buffer = await stream
          .getVideoTracks()
          .single
          .captureFrame()
          .timeout(const Duration(seconds: 5));
      await Gal.putImageBytes(
        buffer.asUint8List(),
        name: 'camera-${DateTime.now().millisecondsSinceEpoch}',
      );
      _notice('공유 영상의 프레임을 저장했어요.');
    } on Exception {
      _notice('영상 프레임을 저장하지 못했어요.');
    } finally {
      if (mounted) setState(() => _takingFrame = false);
    }
  }

  void _notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _closePeer() async {
    final camera = _camera;
    final peer = _peer;
    _camera = null;
    _peer = null;
    _connectionTimer?.cancel();
    _pendingIce.clear();
    _descriptionSet = false;
    _connected = false;
    if (_rendererReady) _renderer.srcObject = null;
    if (camera != null) await _disposeStream(camera);
    await peer?.dispose();
    if (mounted) setState(() {});
  }

  Future<void> _disposeStream(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }

  Future<void> _endServer(String id) async {
    try {
      await widget.api.sessionRequest('DELETE', '/$id');
    } on Exception {
      // The server also expires sessions when the client is offline.
    }
  }

  Future<void> _end({bool notifyServer = true, String? error}) async {
    final id = _id;
    if (id == null && !_busy) return;
    ++_generation;
    final socket = _socket;
    final subscription = _subscription;
    _socket = null;
    _subscription = null;
    _id = null;
    _inviteCode = null;
    _error = error;
    _viewerJoined = _accepted = _peerOnline = _connected = false;
    _peerEpoch = null;
    _busy = true;
    if (mounted) setState(() {});
    try {
      await subscription?.cancel();
      unawaited(socket?.close());
      await _closePeer();
      if (id != null && notifyServer) await _endServer(id);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _code.dispose();
    unawaited(
      _end().whenComplete(() async {
        if (_rendererReady) await _renderer.dispose();
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = _id;
    final canApprove =
        _viewerJoined && !_accepted && (_nearby ? !_host : _host);
    return PopScope(
      canPop: id == null && !_busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && id != null && !_busy) {
          await _end();
          if (context.mounted) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('함께 촬영')),
        body: SafeArea(
          child: Column(
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error case final error?)
                Padding(padding: const EdgeInsets.all(16), child: Text(error)),
              if (id == null) ...[
                const SizedBox(height: 16),
                if (const bool.fromEnvironment('CAM_ENABLE_BLE'))
                  TextButton.icon(
                    onPressed: _busy ? null : _openNearby,
                    icon: const Icon(Icons.bluetooth_searching),
                    label: const Text('주변 기기 연결'),
                  ),
                FilledButton(
                  onPressed: _busy ? null : () => _enter(host: true),
                  child: const Text('초대 코드 만들기'),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _code,
                    enabled: !_busy,
                    maxLength: 8,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(labelText: '초대 코드'),
                  ),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _enter(host: false),
                  child: const Text('구도 보기 요청'),
                ),
              ] else ...[
                if (_inviteCode case final code?)
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: code));
                      _notice('초대 코드를 복사했어요.');
                    },
                    icon: const Icon(Icons.copy),
                    label: Text(code),
                  ),
                if (canApprove)
                  FilledButton(
                    onPressed: _busy ? null : _approve,
                    child: Text(_host ? '요청 수락 및 카메라 공유' : '수락하고 구도 보기'),
                  ),
                Expanded(
                  child: _rendererReady && _renderer.srcObject != null
                      ? Semantics(
                          label: _host ? '공유 중인 카메라 미리보기' : '상대방의 카메라 미리보기',
                          child: RTCVideoView(_renderer),
                        )
                      : Center(
                          child: Text(
                            !_viewerJoined
                                ? '상대방을 기다리는 중'
                                : !_accepted
                                ? (_nearby
                                      ? '수신 기기의 수락을 기다리는 중'
                                      : '촬영자의 수락을 기다리는 중')
                                : !_peerOnline
                                ? '상대 기기의 연결을 기다리는 중'
                                : '영상 연결 중',
                          ),
                        ),
                ),
                if (_host && _connected)
                  TextButton(
                    onPressed: _takingFrame ? null : _saveFrame,
                    child: const Text('공유 영상 프레임 저장'),
                  ),
                TextButton(
                  onPressed: _busy ? null : () => _end(),
                  child: const Text('공유 종료'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
