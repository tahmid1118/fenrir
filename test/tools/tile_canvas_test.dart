import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../tools/src/tile_canvas.dart';

void main() {
  const black = Rgb(0, 0, 0);
  const white = Rgb(255, 255, 255);
  const grey = Rgb(128, 128, 128);

  Rgb pixelAt(TileCanvas c, int x, int y) {
    final i = (y * c.width + x) * 3;
    return Rgb(c.pixels[i], c.pixels[i + 1], c.pixels[i + 2]);
  }

  Float64List rect(double l, double t, double r, double b) =>
      Float64List.fromList([l, t, r, t, r, b, l, b]);

  group('canvas basics', () {
    test('is created filled with the background', () {
      final canvas = TileCanvas(8, 8, white);
      expect(canvas.isUniform(white), isTrue);
      expect(canvas.isUniform(black), isFalse);
      expect(canvas.pixels.length, 8 * 8 * 3);
    });

    test('writes outside the canvas are ignored rather than throwing', () {
      // Geometry routinely extends beyond the tile being drawn.
      final canvas = TileCanvas(4, 4, black);
      expect(() {
        canvas.setPixel(-1, 0, white);
        canvas.setPixel(0, -1, white);
        canvas.setPixel(4, 0, white);
        canvas.setPixel(0, 4, white);
      }, returnsNormally);
      expect(canvas.isUniform(black), isTrue);
    });
  });

  group('scanline fill', () {
    test('fills a rectangle exactly', () {
      final canvas = TileCanvas(10, 10, black);
      canvas.fillRings([rect(2, 2, 8, 8)], white);

      expect(pixelAt(canvas, 5, 5), white, reason: 'inside');
      expect(pixelAt(canvas, 0, 0), black, reason: 'outside');
      expect(pixelAt(canvas, 9, 9), black, reason: 'outside');
      // Edges: the fill covers [2, 8) in both axes at pixel centres.
      expect(pixelAt(canvas, 2, 2), white);
      expect(pixelAt(canvas, 1, 5), black);
      expect(pixelAt(canvas, 8, 5), black);
    });

    test('a hole is left unpainted under the even-odd rule', () {
      // This is why rings are filled together in one pass rather than filled
      // and then painted back over: an inner ring is crossed twice, so
      // even-odd leaves it alone for free.
      final canvas = TileCanvas(20, 20, black);
      canvas.fillRings([rect(2, 2, 18, 18), rect(8, 8, 12, 12)], white);

      expect(pixelAt(canvas, 4, 4), white, reason: 'between the rings');
      expect(pixelAt(canvas, 10, 10), black, reason: 'inside the hole');
      expect(pixelAt(canvas, 0, 0), black, reason: 'outside both');
    });

    test('fills a triangle without leaking at its vertices', () {
      // The half-open scanline test exists so a vertex shared by two edges is
      // counted once. Counting it twice makes the shape leak across the row.
      final canvas = TileCanvas(20, 20, black);
      canvas.fillRings([
        Float64List.fromList([10, 2, 18, 18, 2, 18]),
      ], white);

      expect(pixelAt(canvas, 10, 15), white, reason: 'inside');
      expect(pixelAt(canvas, 1, 19), black, reason: 'outside');
      expect(pixelAt(canvas, 19, 3), black, reason: 'outside');
      // The row containing the apex must not be filled edge to edge.
      expect(pixelAt(canvas, 0, 2), black);
      expect(pixelAt(canvas, 19, 2), black);
    });

    test('geometry far outside the canvas still fills correctly', () {
      // A continent projected into one tile produces coordinates in the tens of
      // thousands. The fill must clip to the canvas rather than iterate them.
      final canvas = TileCanvas(16, 16, black);
      canvas.fillRings([rect(-50000, -50000, 50000, 50000)], white);
      expect(canvas.isUniform(white), isTrue);
    });

    test('geometry entirely off-canvas paints nothing', () {
      final canvas = TileCanvas(16, 16, black);
      canvas.fillRings([rect(100, 100, 200, 200)], white);
      canvas.fillRings([rect(-200, -200, -100, -100)], white);
      expect(canvas.isUniform(black), isTrue);
    });

    test('degenerate rings are ignored', () {
      final canvas = TileCanvas(8, 8, black);
      expect(() {
        canvas.fillRings([], white);
        canvas.fillRings([Float64List.fromList([])], white);
        canvas.fillRings([Float64List.fromList([1, 1])], white);
        canvas.fillRings([Float64List.fromList([1, 1, 2, 2])], white);
      }, returnsNormally);
      expect(canvas.isUniform(black), isTrue);
    });

    test('a horizontal-edged shape does not divide by zero', () {
      final canvas = TileCanvas(12, 12, black);
      canvas.fillRings([
        Float64List.fromList([2, 2, 10, 2, 10, 6, 2, 6]),
      ], white);
      expect(pixelAt(canvas, 6, 4), white);
      for (var i = 0; i < canvas.pixels.length; i++) {
        expect(canvas.pixels[i], isNot(isNaN));
      }
    });
  });

  group('polyline stroking', () {
    test('draws a horizontal line', () {
      final canvas = TileCanvas(16, 16, black);
      canvas.strokePolyline(Float64List.fromList([2, 8, 13, 8]), white);
      expect(pixelAt(canvas, 8, 8), white);
      expect(pixelAt(canvas, 8, 6), black);
    });

    test('thickness widens the stroke', () {
      final thin = TileCanvas(16, 16, black);
      thin.strokePolyline(Float64List.fromList([2, 8, 13, 8]), white);

      final thick = TileCanvas(16, 16, black);
      thick.strokePolyline(
        Float64List.fromList([2, 8, 13, 8]),
        white,
        thickness: 3,
      );

      expect(pixelAt(thin, 8, 7), black);
      expect(pixelAt(thick, 8, 7), white);
    });

    test('segments far off-canvas are rejected without stepping through them',
        () {
      // A border line spanning a continent would otherwise be walked pixel by
      // pixel across tens of thousands of steps for every tile it misses.
      final canvas = TileCanvas(16, 16, black);
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 1000; i++) {
        canvas.strokePolyline(
          Float64List.fromList([-900000, -900000, -800000, -800000]),
          white,
        );
      }
      stopwatch.stop();
      expect(canvas.isUniform(black), isTrue);
      expect(stopwatch.elapsedMilliseconds, lessThan(200));
    });
  });

  group('downsampling', () {
    test('halves the dimensions', () {
      final canvas = TileCanvas(16, 16, black);
      final out = canvas.downsample(2);
      expect(out.width, 8);
      expect(out.height, 8);
    });

    test('averages a hard edge into an intermediate value', () {
      // This is what removes the jagged coastlines the rasteriser would
      // otherwise produce.
      final canvas = TileCanvas(4, 4, black);
      // Fill the left half white, so each 2x2 block on that boundary is mixed.
      canvas.fillRings([rect(0, 0, 1, 4)], white);
      final out = canvas.downsample(2);

      final left = pixelAt(out, 0, 0);
      expect(left.r, greaterThan(0));
      expect(left.r, lessThan(255));
    });

    test('a factor of one returns the canvas unchanged', () {
      final canvas = TileCanvas(4, 4, grey);
      expect(identical(canvas.downsample(1), canvas), isTrue);
    });

    test('a uniform canvas stays uniform', () {
      final canvas = TileCanvas(8, 8, grey);
      expect(canvas.downsample(2).isUniform(grey), isTrue);
    });
  });

  group('Rgb', () {
    test('parses hex with and without a leading hash', () {
      expect(Rgb.hex('#0A1216'), const Rgb(10, 18, 22));
      expect(Rgb.hex('2C3E47'), const Rgb(44, 62, 71));
    });

    test('round-trips through toString', () {
      const colour = Rgb(44, 62, 71);
      expect(Rgb.hex(colour.toString()), colour);
    });
  });
}
