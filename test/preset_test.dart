import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:i_wanna_take_good_photos/presets/preset.dart';
import 'package:i_wanna_take_good_photos/presets/render_photo.dart';
import 'package:image/image.dart' as image;

void main() {
  test('validates and round-trips versioned preset JSON', () {
    final data = Preset(
      'Warm',
      capture: {'iso': 400},
      color: {'temperature': .5},
    ).toJson();
    expect(Preset.fromJson(data).toJson(), data);
    expect(
      () => Preset.fromJson({...data, 'schemaVersion': 1.0}),
      throwsFormatException,
    );
    expect(
      () => Preset.fromJson({
        ...data,
        'colorSettings': {'temperature': 2},
      }),
      throwsFormatException,
    );
    expect(
      () => Preset.fromJson({
        ...data,
        'captureSettings': {'iso': true},
      }),
      throwsFormatException,
    );
  });

  test(
    'saved JPEG uses the preview matrix and bakes EXIF orientation once',
    () async {
      final folder = await Directory.systemTemp.createTemp('preset-test-');
      try {
        final source = File('${folder.path}/original.jpg');
        final input = image.Image(width: 8, height: 4, numChannels: 3)
          ..exif.imageIfd.orientation = 6;
        image.fill(input, color: image.ColorRgb8(100, 100, 100));
        await source.writeAsBytes(image.encodeJpg(input));
        final matrix = Preset('Warm', color: {'temperature': 1}).matrix;
        final path = await renderPhoto(source.path, matrix);
        final saved = image.decodeJpg(await File(path).readAsBytes())!;
        expect((saved.width, saved.height), (4, 8));
        expect(saved.exif.imageIfd.hasOrientation, isFalse);
        final pixel = saved.getPixel(2, 4);
        expect(pixel.r, closeTo(124, 4));
        expect(pixel.g, closeTo(100, 4));
        expect(pixel.b, closeTo(76, 4));
      } finally {
        await folder.delete(recursive: true);
      }
    },
  );
}
