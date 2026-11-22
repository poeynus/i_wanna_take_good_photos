import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:gal/gal.dart';

import 'presets/preset.dart';
import 'presets/preset_api.dart';
import 'presets/preset_screen.dart';
import 'presets/render_photo.dart';
import 'sharing/sharing_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  Future<void> _work = Future<void>.value();
  CameraController? _camera;
  List<CameraDescription> _cameras = [];
  CameraDescription? _selected;
  bool _active = true;
  bool _busy = true;
  int _generation = 0;
  String? _error;
  double _minZoom = 1, _maxZoom = 1, _zoom = 1;
  double _minExposure = 0, _maxExposure = 0, _exposure = 0;
  bool _flashSupported = false;
  double? _adjustmentDraft;
  String? _adjustmentLabel;
  Preset? _preset;
  final _sharing = const bool.fromEnvironment('CAM_ENABLE_SHARING')
      ? PresetApi.fromEnvironment()
      : null;
  bool _cameraCovered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // System permission dialogs can make the app briefly inactive.
    if (state == AppLifecycleState.inactive) return;
    final active = state == AppLifecycleState.resumed;
    if (_active == active) return;
    _active = active;
    _scheduleCamera();
  }

  void _scheduleCamera() {
    final generation = ++_generation;
    setState(() => _busy = true);
    _work = _work.then((_) async {
      final previous = _camera;
      if (mounted) setState(() => _camera = null);
      try {
        await previous?.dispose();
        if (!mounted ||
            !_active ||
            _cameraCovered ||
            generation != _generation) {
          return;
        }
        await _openCamera(generation);
      } on CameraException catch (error) {
        if (mounted && generation == _generation) {
          _error = switch (error.code) {
            'CameraAccessDenied' => '카메라 권한을 허용한 뒤 다시 시도해 주세요.',
            'CameraAccessDeniedWithoutPrompt' => '설정에서 카메라 권한을 허용해 주세요.',
            'CameraAccessRestricted' => '이 기기에서 카메라 사용이 제한돼 있어요.',
            _ => '카메라를 열 수 없어요. 다시 시도해 주세요.',
          };
        }
      } on Exception {
        if (mounted && generation == _generation) {
          _error = '카메라를 열 수 없어요. 다시 시도해 주세요.';
        }
      } finally {
        if (mounted && generation == _generation) {
          setState(() => _busy = false);
        }
      }
    });
  }

  Future<void> _openCamera(int generation) async {
    _error = null;
    if (!Platform.isAndroid && !Platform.isIOS) {
      _error = 'Android 또는 iOS 기기에서 카메라를 사용할 수 있어요.';
      return;
    }
    _cameras = await availableCameras();
    if (!mounted || !_active || generation != _generation) return;
    if (_cameras.isEmpty) {
      _error = '사용 가능한 카메라가 없어요.';
      return;
    }
    final selected = _selected;
    _selected = _cameras.contains(selected)
        ? selected
        : _cameras.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
            orElse: () => _cameras.first,
          );
    final camera = CameraController(
      _selected!,
      ResolutionPreset.high,
      enableAudio: false,
    );
    try {
      await camera.initialize();
      await _readCapabilities(camera);
      final unsupported = await _applyPresetSettings(camera);
      if (mounted && _active && generation == _generation) {
        setState(() => _camera = camera);
        if (unsupported.isNotEmpty) {
          _notice('이 기기에서 적용할 수 없는 설정: ${unsupported.join(', ')}');
        }
      }
    } finally {
      if (_camera != camera) await camera.dispose();
    }
  }

  Future<List<String>> _applyPresetSettings(CameraController camera) async {
    final unsupported = <String>[];
    for (final MapEntry(key: key, value: value)
        in (_preset?.capture ?? const <String, double>{}).entries) {
      try {
        if (key == 'zoom' && value >= _minZoom && value <= _maxZoom) {
          if (_maxZoom > _minZoom) await camera.setZoomLevel(value);
          _zoom = value;
        } else if (key == 'exposureEv' &&
            value >= _minExposure &&
            value <= _maxExposure) {
          if (_maxExposure > _minExposure) {
            _exposure = await camera.setExposureOffset(value);
          }
        } else {
          unsupported.add(key);
        }
      } on CameraException {
        unsupported.add(key);
      }
    }
    return unsupported;
  }

  Future<void> _managePresets() async {
    final zoom = _zoom;
    final exposure = _exposure;
    _cameraCovered = true;
    _scheduleCamera();
    final preset = await Navigator.of(context).push<Preset>(
      MaterialPageRoute(
        builder: (_) => PresetScreen(zoom: zoom, exposure: exposure),
      ),
    );
    if (!mounted) return;
    _cameraCovered = false;
    if (preset != null) _preset = preset;
    _scheduleCamera();
  }

  Future<void> _openSharing(PresetApi api) async {
    _cameraCovered = true;
    _scheduleCamera();
    await _work;
    if (!mounted) return;
    await Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => SharingScreen(api: api)));
    if (!mounted) return;
    _cameraCovered = false;
    _scheduleCamera();
  }

  Future<void> _readCapabilities(CameraController camera) async {
    _minZoom = _maxZoom = _zoom = 1;
    _minExposure = _maxExposure = _exposure = 0;
    _flashSupported = false;
    try {
      final min = await camera.getMinZoomLevel();
      final max = await camera.getMaxZoomLevel();
      if (min.isFinite && max.isFinite && min < max) {
        _minZoom = min;
        _maxZoom = max;
        _zoom = 1.0.clamp(min, max);
      }
    } on CameraException {
      // Some devices expose only fixed zoom.
    }
    try {
      final min = await camera.getMinExposureOffset();
      final max = await camera.getMaxExposureOffset();
      if (min.isFinite && max.isFinite && min < max) {
        _minExposure = min;
        _maxExposure = max;
        _exposure = 0.0.clamp(min, max);
      }
    } on CameraException {
      // Exposure compensation is optional.
    }
    try {
      await camera.setFlashMode(FlashMode.off);
      if (Platform.isAndroid) {
        _flashSupported =
            await const MethodChannel('camera/capabilities')
                .invokeMethod<bool>('hasFlash', camera.description.name) ??
            false;
      } else {
        await camera.setFlashMode(FlashMode.always);
        await camera.setFlashMode(FlashMode.off);
        _flashSupported = true;
      }
    } on Exception {
      _flashSupported = false;
    }
  }

  CameraDescription? get _otherLens {
    for (final camera in _cameras) {
      if (camera.lensDirection != _selected?.lensDirection &&
          camera.lensDirection != CameraLensDirection.external) {
        return camera;
      }
    }
    return null;
  }

  void _operate(Future<void> Function(CameraController) action) {
    final camera = _camera;
    if (!_active || _busy || camera == null) return;
    final generation = _generation;
    setState(() => _busy = true);
    _work = _work.then((_) async {
      try {
        if (mounted && _active && generation == _generation) {
          await action(camera);
        }
      } on Exception {
        if (generation == _generation) _notice('이 카메라 설정을 적용할 수 없어요.');
      } finally {
        if (mounted && generation == _generation) {
          setState(() => _busy = false);
        }
      }
    });
  }

  Future<void> _capture(CameraController camera) async {
    XFile photo;
    try {
      photo = await camera.takePicture();
    } on CameraException {
      _notice('사진을 촬영하지 못했어요. 다시 시도해 주세요.');
      return;
    }
    var output = photo.path;
    try {
      final preset = _preset;
      if (preset != null && preset.hasColor) {
        output = await renderPhoto(photo.path, preset.matrix);
      }
      await Gal.putImage(output);
      _notice('사진을 저장했어요.');
    } on GalException catch (error) {
      _notice(
        error.type == GalExceptionType.permissionDenied
            ? '사진을 저장하려면 사진 라이브러리 접근을 허용해 주세요.'
            : '사진을 촬영했지만 라이브러리에 저장하지 못했어요.',
      );
    } on Exception {
      _notice('사진을 촬영했지만 라이브러리에 저장하지 못했어요.');
    } finally {
      try {
        await File(photo.path).delete();
        if (output != photo.path) await File(output).delete();
      } on FileSystemException {
        // The camera writes its temporary file to the app cache.
      }
    }
  }

  void _notice(String message) {
    if (!mounted || !_active) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final camera = _camera;
    _camera = null;
    unawaited(
      _work.whenComplete(() async {
        try {
          await camera?.dispose();
        } on CameraException {
          // The platform may have already released the camera.
        }
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    final enabled = _active && !_busy && camera != null;
    final otherLens = _otherLens;
    final preset = _preset;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: camera == null
                    ? _buildStatus()
                    : ColorFiltered(
                        colorFilter: ColorFilter.matrix(
                          preset?.matrix ?? const Preset('').matrix,
                        ),
                        child: CameraPreview(
                          camera,
                          child: LayoutBuilder(
                            builder: (context, constraints) => GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown:
                                  enabled && camera.value.focusPointSupported
                                  ? (tap) {
                                      final point = Offset(
                                        (tap.localPosition.dx /
                                                constraints.maxWidth)
                                            .clamp(0.0, 1.0),
                                        (tap.localPosition.dy /
                                                constraints.maxHeight)
                                            .clamp(0.0, 1.0),
                                      );
                                      _operate(
                                        (camera) => camera.setFocusPoint(point),
                                      );
                                    }
                                  : null,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            if (camera != null && _maxZoom > _minZoom)
              _adjustment(
                '줌',
                '${_zoom.toStringAsFixed(1)}×',
                _zoom,
                _minZoom,
                _maxZoom,
                enabled,
                (value) async {
                  await camera.setZoomLevel(value);
                  _zoom = value;
                },
              ),
            if (camera != null && _maxExposure > _minExposure)
              _adjustment(
                '노출',
                '${_exposure.toStringAsFixed(1)} EV',
                _exposure,
                _minExposure,
                _maxExposure,
                enabled,
                (value) async {
                  _exposure = await camera.setExposureOffset(value);
                },
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: '플래시',
                    icon: Icon(
                      camera?.value.flashMode == FlashMode.always
                          ? Icons.flash_on
                          : Icons.flash_off,
                    ),
                    onPressed: enabled && _flashSupported
                        ? () => _operate(
                            (camera) => camera.setFlashMode(
                              camera.value.flashMode == FlashMode.always
                                  ? FlashMode.off
                                  : FlashMode.always,
                            ),
                          )
                        : null,
                  ),
                  IconButton.filled(
                    iconSize: 36,
                    tooltip: '사진 촬영',
                    onPressed: enabled ? () => _operate(_capture) : null,
                    icon: const Icon(Icons.camera_alt),
                  ),
                  IconButton(
                    tooltip: '카메라 전환',
                    icon: const Icon(Icons.cameraswitch),
                    onPressed: enabled && otherLens != null
                        ? () {
                            _selected = otherLens;
                            _scheduleCamera();
                          }
                        : null,
                  ),
                  IconButton(
                    tooltip: preset?.hasColor == true
                        ? '프리셋 · ${preset!.name}'
                        : '프리셋',
                    onPressed: _active && !_busy ? _managePresets : null,
                    icon: const Icon(Icons.tune),
                  ),
                  if (_sharing case final api?)
                    IconButton(
                      tooltip: '함께 촬영',
                      onPressed: _active && !_busy
                          ? () => _openSharing(api)
                          : null,
                      icon: const Icon(Icons.people_outline),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _adjustment(
    String label,
    String displayValue,
    double value,
    double min,
    double max,
    bool enabled,
    Future<void> Function(double) apply,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text(label),
          Expanded(
            child: Slider(
              value:
                  (_adjustmentLabel == label
                          ? _adjustmentDraft ?? value
                          : value)
                      .clamp(min, max),
              min: min,
              max: max,
              onChanged: enabled
                  ? (value) => setState(() {
                      _adjustmentLabel = label;
                      _adjustmentDraft = value;
                    })
                  : null,
              onChangeEnd: enabled
                  ? (value) {
                      _adjustmentLabel = null;
                      _adjustmentDraft = null;
                      _operate((_) => apply(value));
                    }
                  : null,
              semanticFormatterCallback: (value) =>
                  '$label ${value.toStringAsFixed(1)}',
            ),
          ),
          Text(displayValue),
        ],
      ),
    );
  }

  Widget _buildStatus() {
    if (_busy || !_active) {
      return const CircularProgressIndicator(semanticsLabel: '카메라 준비 중');
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_error ?? '카메라를 준비할 수 없어요.', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _scheduleCamera,
            child: const Text('다시 시도'),
          ),
        ],
      ),
    );
  }
}
