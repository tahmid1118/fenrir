import 'dart:typed_data';

/// A minimal RGBA raster with a scanline polygon filler.
///
/// The `image` package is used for PNG encoding, but not for drawing. Its
/// `fillPolygon` ray-casts once per pixel per vertex, so filling a coastline
/// with a few thousand vertices into a supersampled tile costs on the order of
/// a billion operations — multiplied by 1,365 tiles, that is hours of work.
///
/// The scanline algorithm here is O(scanlines x edges) instead, and it fills
/// several rings in one pass under the even-odd rule, so polygon holes come out
/// correctly without a second pass to paint them back over.
class TileCanvas {
  TileCanvas(this.width, this.height, Rgb background)
      : pixels = Uint8List(width * height * 3) {
    fill(background);
  }

  final int width;
  final int height;

  /// Tightly packed RGB, three bytes per pixel. No alpha: every tile is fully
  /// opaque, and dropping the channel keeps the PNGs smaller.
  final Uint8List pixels;

  void fill(Rgb color) {
    for (var i = 0; i < pixels.length; i += 3) {
      pixels[i] = color.r;
      pixels[i + 1] = color.g;
      pixels[i + 2] = color.b;
    }
  }

  void setPixel(int x, int y, Rgb color) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    final i = (y * width + x) * 3;
    pixels[i] = color.r;
    pixels[i + 1] = color.g;
    pixels[i + 2] = color.b;
  }

  /// Fills the area enclosed by [rings] using the even-odd rule.
  ///
  /// Pass a polygon's exterior ring and its holes together: under even-odd a
  /// hole is crossed twice and so is left unpainted, which is exactly the
  /// desired result and costs nothing extra.
  ///
  /// Each ring is a flat `[x0, y0, x1, y1, ...]` list in pixel space.
  void fillRings(List<Float64List> rings, Rgb color) {
    if (rings.isEmpty) return;

    // Build an edge table. Horizontal edges are skipped: they contribute no
    // crossings and would divide by zero.
    final edgeX0 = <double>[];
    final edgeY0 = <double>[];
    final edgeX1 = <double>[];
    final edgeY1 = <double>[];

    var minY = double.infinity;
    var maxY = double.negativeInfinity;

    for (final ring in rings) {
      final count = ring.length ~/ 2;
      if (count < 3) continue;
      for (var i = 0; i < count; i++) {
        final j = (i + 1) % count;
        final ax = ring[i * 2];
        final ay = ring[i * 2 + 1];
        final bx = ring[j * 2];
        final by = ring[j * 2 + 1];
        if (ay == by) continue;
        edgeX0.add(ax);
        edgeY0.add(ay);
        edgeX1.add(bx);
        edgeY1.add(by);
        if (ay < minY) minY = ay;
        if (by < minY) minY = by;
        if (ay > maxY) maxY = ay;
        if (by > maxY) maxY = by;
      }
    }
    if (edgeX0.isEmpty) return;

    var yStart = minY.floor();
    var yEnd = maxY.ceil();
    if (yStart < 0) yStart = 0;
    if (yEnd > height - 1) yEnd = height - 1;

    final crossings = <double>[];

    for (var py = yStart; py <= yEnd; py++) {
      // Sample at pixel centres so that an edge landing exactly on an integer
      // boundary does not produce a doubled or missing crossing.
      final sy = py + 0.5;
      crossings.clear();

      for (var e = 0; e < edgeX0.length; e++) {
        final ay = edgeY0[e];
        final by = edgeY1[e];
        // Half-open test: a vertex shared by two edges is counted once, which
        // is what keeps a shape from leaking at its local minima and maxima.
        if ((ay <= sy && by > sy) || (by <= sy && ay > sy)) {
          final t = (sy - ay) / (by - ay);
          crossings.add(edgeX0[e] + t * (edgeX1[e] - edgeX0[e]));
        }
      }
      if (crossings.length < 2) continue;
      crossings.sort();

      for (var i = 0; i + 1 < crossings.length; i += 2) {
        var xa = crossings[i];
        var xb = crossings[i + 1];
        if (xb < 0 || xa > width) continue;
        if (xa < 0) xa = 0;
        if (xb > width) xb = width.toDouble();

        final pxStart = xa.round();
        final pxEnd = xb.round();
        final rowBase = py * width;
        for (var px = pxStart; px < pxEnd; px++) {
          if (px < 0 || px >= width) continue;
          final k = (rowBase + px) * 3;
          pixels[k] = color.r;
          pixels[k + 1] = color.g;
          pixels[k + 2] = color.b;
        }
      }
    }
  }

  /// Draws a polyline in pixel space, one segment at a time.
  void strokePolyline(Float64List points, Rgb color, {int thickness = 1}) {
    final count = points.length ~/ 2;
    for (var i = 0; i + 1 < count; i++) {
      _line(
        points[i * 2],
        points[i * 2 + 1],
        points[i * 2 + 2],
        points[i * 2 + 3],
        color,
        thickness,
      );
    }
  }

  void _line(double x0, double y0, double x1, double y1, Rgb color, int t) {
    // Reject segments that cannot touch the canvas before stepping along them;
    // geometry routinely runs far outside the tile being drawn.
    final loX = x0 < x1 ? x0 : x1;
    final hiX = x0 < x1 ? x1 : x0;
    final loY = y0 < y1 ? y0 : y1;
    final hiY = y0 < y1 ? y1 : y0;
    if (hiX < -t || loX > width + t || hiY < -t || loY > height + t) return;

    final dx = (x1 - x0).abs();
    final dy = (y1 - y0).abs();
    final steps = (dx > dy ? dx : dy).ceil();
    if (steps == 0) {
      _dot(x0.round(), y0.round(), color, t);
      return;
    }
    for (var i = 0; i <= steps; i++) {
      final f = i / steps;
      _dot(
        (x0 + (x1 - x0) * f).round(),
        (y0 + (y1 - y0) * f).round(),
        color,
        t,
      );
    }
  }

  void _dot(int x, int y, Rgb color, int thickness) {
    if (thickness <= 1) {
      setPixel(x, y, color);
      return;
    }
    final half = thickness ~/ 2;
    for (var oy = -half; oy <= half; oy++) {
      for (var ox = -half; ox <= half; ox++) {
        setPixel(x + ox, y + oy, color);
      }
    }
  }

  /// Box-downsamples by [factor], which is how the tiles get antialiased.
  ///
  /// The rasteriser above writes hard-edged pixels, so coastlines rendered at
  /// final size look visibly jagged. Drawing at a multiple and averaging down
  /// is the cheapest fix and needs no filtering library.
  TileCanvas downsample(int factor) {
    if (factor <= 1) return this;
    final outW = width ~/ factor;
    final outH = height ~/ factor;
    final out = TileCanvas(outW, outH, const Rgb(0, 0, 0));
    final samples = factor * factor;

    for (var y = 0; y < outH; y++) {
      for (var x = 0; x < outW; x++) {
        var r = 0, g = 0, b = 0;
        for (var sy = 0; sy < factor; sy++) {
          final row = (y * factor + sy) * width;
          for (var sx = 0; sx < factor; sx++) {
            final k = (row + x * factor + sx) * 3;
            r += pixels[k];
            g += pixels[k + 1];
            b += pixels[k + 2];
          }
        }
        final k = (y * outW + x) * 3;
        out.pixels[k] = r ~/ samples;
        out.pixels[k + 1] = g ~/ samples;
        out.pixels[k + 2] = b ~/ samples;
      }
    }
    return out;
  }

  /// True when every pixel is [color]. Used to detect uniform ocean tiles.
  bool isUniform(Rgb color) {
    for (var i = 0; i < pixels.length; i += 3) {
      if (pixels[i] != color.r ||
          pixels[i + 1] != color.g ||
          pixels[i + 2] != color.b) {
        return false;
      }
    }
    return true;
  }
}

/// An opaque colour.
class Rgb {
  const Rgb(this.r, this.g, this.b);

  /// Parses `#rrggbb`.
  factory Rgb.hex(String hex) {
    final v = int.parse(hex.replaceFirst('#', ''), radix: 16);
    return Rgb((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
  }

  final int r;
  final int g;
  final int b;

  @override
  bool operator ==(Object other) =>
      other is Rgb && r == other.r && g == other.g && b == other.b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() =>
      '#${r.toRadixString(16).padLeft(2, '0')}'
      '${g.toRadixString(16).padLeft(2, '0')}'
      '${b.toRadixString(16).padLeft(2, '0')}';
}
