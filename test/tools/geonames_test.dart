import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tools/src/geonames.dart';

/// Builds a `cities500.txt` row. The export has 19 tab-separated columns.
String row({
  String id = '1185241',
  String name = 'Dhaka',
  String lat = '23.7104',
  String lon = '90.40744',
  String featureClass = 'P',
  String country = 'BD',
  String admin1 = '81',
  String admin2 = '3117',
  String population = '10356500',
  String timeZone = 'Asia/Dhaka',
}) {
  final f = List.filled(19, '');
  f[0] = id;
  f[1] = name;
  f[2] = name; // ascii name
  f[4] = lat;
  f[5] = lon;
  f[6] = featureClass;
  f[7] = 'PPLC'; // feature code
  f[8] = country;
  f[10] = admin1;
  f[11] = admin2;
  f[14] = population;
  f[17] = timeZone;
  return f.join('\t');
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fenrir_geonames_test');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<List<GeoNamesPlace>> parse(List<String> lines) async {
    final file = File('${temp.path}/cities.txt');
    await file.writeAsString(lines.join('\n'));
    return readGeoNames(file).toList();
  }

  group('reading cities500', () {
    test('parses a well-formed row', () async {
      final places = await parse([row()]);
      expect(places, hasLength(1));

      final place = places.single;
      expect(place.id, 1185241);
      expect(place.name, 'Dhaka');
      expect(place.latitude, 23.7104);
      expect(place.longitude, 90.40744);
      expect(place.country, 'BD');
      expect(place.admin1Code, '81');
      expect(place.admin2Code, '3117');
      expect(place.population, 10356500);
      expect(place.timeZone, 'Asia/Dhaka');
    });

    test('keeps only populated places', () async {
      // The built database has no feature-class column, so this filter cannot
      // be re-applied later. A mountain or a stream left in here would let the
      // app tell the user they are standing on a river.
      final places = await parse([
        row(name: 'A town', featureClass: 'P'),
        row(name: 'A mountain', featureClass: 'T'),
        row(name: 'A stream', featureClass: 'H'),
        row(name: 'A spot', featureClass: 'S'),
      ]);
      expect(places.map((p) => p.name), ['A town']);
    });

    test('skips rows that cannot be trusted', () async {
      final places = await parse([
        '',
        'truncated\trow',
        row(id: 'not-a-number'),
        row(lat: ''),
        row(lon: 'x'),
        row(name: ''),
        row(country: 'BGD'), // not alpha-2
        row(name: 'Good'),
      ]);
      expect(places.map((p) => p.name), ['Good']);
    });

    test('a missing population reads as zero, not as a failure', () async {
      // 30,661 rows in the shipped database have a population of zero.
      final places = await parse([row(population: '')]);
      expect(places.single.population, 0);
    });

    test('handles non-ASCII names', () async {
      final places = await parse([
        row(name: 'Boneh-ye ‘Alvān'),
        row(name: 'Şobḩān'),
        row(name: '上海'),
      ]);
      expect(
        places.map((p) => p.name),
        ['Boneh-ye ‘Alvān', 'Şobḩān', '上海'],
      );
    });

    test('southern and western coordinates keep their sign', () async {
      final places = await parse([row(lat: '-33.86785', lon: '-70.1234')]);
      expect(places.single.latitude, -33.86785);
      expect(places.single.longitude, -70.1234);
    });
  });

  group('division name lookups', () {
    test('reads first-level codes', () async {
      final file = File('${temp.path}/admin1.txt');
      await file.writeAsString([
        'BD.81\tDhaka Division\tDhaka Division\t1185241',
        'BD.84\tChittagong\tChittagong\t1205733',
        'US.CA\tCalifornia\tCalifornia\t5332921',
      ].join('\n'));

      final names = await AdminNames.readAdmin1(file.path);
      expect(names['BD.81'], 'Dhaka Division');
      // The source is inconsistent -- some divisions carry the suffix and some
      // do not. Nothing normalises it, because inventing a suffix would be
      // inventing data.
      expect(names['BD.84'], 'Chittagong');
      expect(names['US.CA'], 'California');
    });

    test('reads second-level codes and ignores first-level keys', () async {
      final file = File('${temp.path}/admin2.txt');
      await file.writeAsString([
        'BD.81.3117\tDhaka\tDhaka\t1185241',
        'BD.81\tshould be ignored\tx\t0',
        'US.CA.075\tSan Francisco County\tSan Francisco County\t0',
      ].join('\n'));

      final names = await AdminNames.readAdmin2(file.path);
      expect(names['BD.81.3117'], 'Dhaka');
      expect(names['US.CA.075'], 'San Francisco County');
      expect(names.containsKey('BD.81'), isFalse);
    });

    test('a missing file yields empty names rather than failing the build',
        () async {
      // Places still resolve without division names; stopping the whole build
      // over a missing lookup table would be worse than a blank field.
      final names = await AdminNames.readAdmin1('${temp.path}/absent.txt');
      expect(names, isEmpty);
    });
  });
}
