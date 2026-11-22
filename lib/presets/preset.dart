import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

const colorControls = <String, String>{
  'brightness': '밝기',
  'contrast': '대비',
  'saturation': '채도',
  'temperature': '색온도',
  'highlights': '하이라이트',
  'shadows': '그림자',
};

const captureControls = {
  'zoom': ('줌 배율', 1.0, 100.0),
  'exposureEv': ('노출 보정 (EV)', -12.0, 12.0),
  'iso': ('ISO', 1.0, 102400.0),
  'shutterSeconds': ('셔터스피드 (초)', 0.00001, 120.0),
  'whiteBalanceKelvin': ('화이트밸런스 (K)', 1000.0, 20000.0),
};

class Preset {
  const Preset(this.name, {this.capture = const {}, this.color = const {}});

  final String name;
  final Map<String, double> capture;
  final Map<String, double> color;

  factory Preset.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['schemaVersion'] is! int ||
        value['schemaVersion'] != 1) {
      throw const FormatException('프리셋 버전을 지원하지 않아요.');
    }
    final name = value['name'];
    if (name is! String || name.trim().isEmpty || name.trim().length > 60) {
      throw const FormatException('이름은 1~60자로 입력해 주세요.');
    }
    return Preset(
      name.trim(),
      capture: _settings(value['captureSettings'], {
        for (final MapEntry(:key, :value) in captureControls.entries)
          key: (value.$2, value.$3),
      }),
      color: _settings(value['colorSettings'], {
        for (final key in colorControls.keys) key: (-1.0, 1.0),
      }),
    );
  }

  static Map<String, double> _settings(
    Object? value,
    Map<String, (double, double)> limits,
  ) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('설정은 JSON 객체여야 해요.');
    }
    final settings = <String, double>{};
    for (final MapEntry(key: key, value: number) in value.entries) {
      final range = limits[key];
      if (range == null ||
          number is! num ||
          !number.isFinite ||
          number < range.$1 ||
          number > range.$2) {
        throw FormatException('지원하지 않는 설정 값이에요: $key');
      }
      settings[key] = number.toDouble();
    }
    return Map.unmodifiable(settings);
  }

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'name': name,
    'captureSettings': capture,
    'colorSettings': color,
  };

  bool get hasColor => color.values.any((value) => value != 0);

  List<double> get matrix {
    final brightness = (color['brightness'] ?? 0) * 64;
    final contrast = 1 + (color['contrast'] ?? 0) * .75;
    final saturation = 1 + (color['saturation'] ?? 0);
    final temperature = (color['temperature'] ?? 0) * 24;
    final shadowShift = (color['shadows'] ?? 0) * 48;
    final highlightShift = (color['highlights'] ?? 0) * 48;
    final offset = brightness + 127.5 * (1 - contrast) + shadowShift;
    final luminanceWeight =
        (1 - saturation) * contrast + (highlightShift - shadowShift) / 255;
    final r = .2126 * luminanceWeight;
    final g = .7152 * luminanceWeight;
    final b = .0722 * luminanceWeight;
    final diagonal = saturation * contrast;
    return [
      r + diagonal,
      g,
      b,
      0,
      offset + temperature,
      r,
      g + diagonal,
      b,
      0,
      offset,
      r,
      g,
      b + diagonal,
      0,
      offset - temperature,
      0,
      0,
      0,
      1,
      0,
    ];
  }
}

class PresetStore {
  Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/camera-presets.json');
  }

  Future<List<Preset>> load() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final data = jsonDecode(await file.readAsString());
    if (data is! List<dynamic>) {
      throw const FormatException('Invalid preset library');
    }
    return data.map(Preset.fromJson).toList();
  }

  Future<void> save(List<Preset> presets) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(presets), flush: true);
    await temp.rename(file.path);
  }
}
