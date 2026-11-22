import 'dart:io';
import 'dart:isolate';

import 'package:image/image.dart' as image;

Future<String> renderPhoto(String source, List<double> matrix) =>
    Isolate.run(() {
      final bytes = File(source).readAsBytesSync();
      final photo = image.decodeJpg(bytes);
      if (photo == null) throw const FormatException('Invalid camera JPEG');
      for (final pixel in photo) {
        final r = pixel.r;
        final g = pixel.g;
        final b = pixel.b;
        int channel(int row) =>
            (matrix[row] * r +
                    matrix[row + 1] * g +
                    matrix[row + 2] * b +
                    matrix[row + 4])
                .round()
                .clamp(0, 255);
        pixel.setRgb(channel(0), channel(5), channel(10));
      }
      final output = File('$source.filtered.jpg');
      output.writeAsBytesSync(image.encodeJpg(photo, quality: 95));
      return output.path;
    });
