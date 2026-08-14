import 'package:flutter_test/flutter_test.dart';

import '../../tools/src/mercator.dart';

void main() {
  group('Web Mercator projection', () {
    test('the world corners map to the unit square', () {
      expect(lonToWorldX(-180), closeTo(0.0, 1e-12));
      expect(lonToWorldX(0), closeTo(0.5, 1e-12));
      expect(lonToWorldX(180), closeTo(1.0, 1e-12));

      expect(latToWorldY(webMercatorMaxLatitude), closeTo(0.0, 1e-9));
      expect(latToWorldY(0), closeTo(0.5, 1e-12));
      expect(latToWorldY(-webMercatorMaxLatitude), closeTo(1.0, 1e-9));
    });

    test('latitude is clamped rather than sent to infinity', () {
      // The projection diverges at the poles. Every slippy map truncates it,
      // and an unclamped value would produce a NaN pixel coordinate.
      expect(latToWorldY(90).isFinite, isTrue);
      expect(latToWorldY(-90).isFinite, isTrue);
      expect(latToWorldY(90), closeTo(latToWorldY(webMercatorMaxLatitude), 1e-12));
      expect(latToWorldY(-90),
          closeTo(latToWorldY(-webMercatorMaxLatitude), 1e-12));
    });

    test('projection round-trips', () {
      for (final lon in [-180.0, -73.9, 0.0, 2.2945, 90.3742, 179.9]) {
        expect(worldXToLon(lonToWorldX(lon)), closeTo(lon, 1e-9));
      }
      for (final lat in [-84.0, -33.87, 0.0, 23.7461, 51.5, 84.0]) {
        expect(worldYToLat(latToWorldY(lat)), closeTo(lat, 1e-9));
      }
    });

    test('north is up: higher latitude gives a smaller y', () {
      expect(latToWorldY(60), lessThan(latToWorldY(30)));
      expect(latToWorldY(0), lessThan(latToWorldY(-30)));
    });
  });

  group('tile arithmetic', () {
    test('tile counts follow the quadtree', () {
      expect(tilesPerAxis(0), 1);
      expect(tilesPerAxis(5), 32);
      // 1 + 4 + 16 + 64 + 256 + 1024
      expect(totalTiles(5), 1365);
      expect(totalTiles(0), 1);
      expect(totalTiles(4), 341);
    });

    test('the single zoom 0 tile covers the whole world', () {
      final bounds = tileBounds(0, 0, 0);
      expect(bounds.west, closeTo(-180, 1e-9));
      expect(bounds.east, closeTo(180, 1e-9));
      expect(bounds.north, closeTo(webMercatorMaxLatitude, 1e-6));
      expect(bounds.south, closeTo(-webMercatorMaxLatitude, 1e-6));
    });

    test('tiles tile: neighbours share an edge and do not overlap', () {
      const z = 3;
      for (var x = 0; x < tilesPerAxis(z) - 1; x++) {
        expect(tileBounds(z, x, 0).east,
            closeTo(tileBounds(z, x + 1, 0).west, 1e-9));
      }
      for (var y = 0; y < tilesPerAxis(z) - 1; y++) {
        expect(tileBounds(z, 0, y).south,
            closeTo(tileBounds(z, 0, y + 1).north, 1e-9));
      }
    });
  });

  group('the TMS row flip', () {
    test('inverts the row index within the zoom level', () {
      // MBTiles numbers rows from the south, slippy-map XYZ from the north.
      // Reversing this renders the world upside down, and it is symmetric
      // enough to look plausible in a single tile, so it gets its own test.
      expect(tmsRow(0, 0), 0);
      expect(tmsRow(1, 0), 1);
      expect(tmsRow(1, 1), 0);
      expect(tmsRow(5, 0), 31);
      expect(tmsRow(5, 31), 0);
    });

    test('is its own inverse', () {
      for (var z = 0; z <= 5; z++) {
        for (var y = 0; y < tilesPerAxis(z); y++) {
          expect(tmsRow(z, tmsRow(z, y)), y);
        }
      }
    });

    test('the northernmost XYZ row becomes the highest TMS row', () {
      // A concrete orientation check: XYZ y=0 is the Arctic, and in TMS the
      // Arctic must be the largest row number.
      const z = 4;
      expect(tileBounds(z, 0, 0).north, greaterThan(0));
      expect(tmsRow(z, 0), tilesPerAxis(z) - 1);
    });
  });

  group('TileProjector', () {
    test('maps a tile onto its own pixel grid', () {
      const size = 256;
      final projector = TileProjector(zoom: 0, x: 0, y: 0, size: size);

      expect(projector.projectX(-180), closeTo(0, 1e-9));
      expect(projector.projectX(180), closeTo(size, 1e-9));
      expect(projector.projectX(0), closeTo(size / 2, 1e-9));
      expect(projector.projectY(0), closeTo(size / 2, 1e-9));
      expect(projector.projectY(webMercatorMaxLatitude), closeTo(0, 1e-6));
    });

    test('a tile at depth places its own corner at the origin', () {
      const z = 5;
      const x = 20;
      const y = 12;
      const size = 256;
      final projector = TileProjector(zoom: z, x: x, y: y, size: size);
      final bounds = tileBounds(z, x, y);

      expect(projector.projectX(bounds.west), closeTo(0, 1e-6));
      expect(projector.projectX(bounds.east), closeTo(size, 1e-6));
      expect(projector.projectY(bounds.north), closeTo(0, 1e-6));
      expect(projector.projectY(bounds.south), closeTo(size, 1e-6));
    });

    test('geometry outside the tile keeps true off-canvas coordinates', () {
      // The rasteriser needs the real position of an off-tile vertex to get the
      // slope of an edge right where it crosses the boundary. Clamping here
      // would bend coastlines at every tile seam.
      final projector = TileProjector(zoom: 5, x: 20, y: 12, size: 256);
      final bounds = tileBounds(5, 20, 12);
      expect(projector.projectX(bounds.west - 20), lessThan(0));
      expect(projector.projectY(bounds.north + 10), lessThan(0));
    });
  });

  group('bounds intersection', () {
    test('detects overlap and rejects misses', () {
      final bounds = tileBounds(2, 1, 1);
      expect(
        bounds.intersects(bounds.west, bounds.south, bounds.east, bounds.north),
        isTrue,
      );
      // Far away in both axes.
      expect(bounds.intersects(-179, -80, -178, -79), isFalse);
      // Touching exactly on an edge still counts, so nothing is dropped at a
      // seam.
      expect(
        bounds.intersects(bounds.east, bounds.south, bounds.east + 1,
            bounds.north),
        isTrue,
      );
    });
  });
}
