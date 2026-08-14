import 'dart:convert';
import 'dart:io';

/// Readers for the GeoNames tab-separated exports.
///
/// The dumps are plain UTF-8 TSV with no quoting and no header, so they stream
/// line by line without a CSV parser. `cities500.txt` is about 39 MB
/// uncompressed, which is worth streaming rather than reading whole.

/// One row of `cities500.txt`.
///
/// The export has 19 columns; only the ones the app queries are kept. Notably
/// absent from the built database is the feature class, so the "populated
/// place" filter cannot be re-applied later — it is applied here.
class GeoNamesPlace {
  const GeoNamesPlace({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.country,
    required this.admin1Code,
    required this.admin2Code,
    required this.population,
    required this.timeZone,
  });

  final int id;
  final String name;
  final double latitude;
  final double longitude;

  /// ISO 3166-1 alpha-2.
  final String country;

  /// Division codes, resolved to display names by [AdminNames].
  final String admin1Code;
  final String admin2Code;

  final int population;
  final String timeZone;
}

/// Streams `cities500.txt`, skipping rows that are unusable.
Stream<GeoNamesPlace> readGeoNames(File source) async* {
  final lines = source
      .openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  await for (final line in lines) {
    if (line.isEmpty) continue;
    final f = line.split('\t');
    // 19 columns; anything shorter is a truncated or corrupt row.
    if (f.length < 18) continue;

    final id = int.tryParse(f[0]);
    final lat = double.tryParse(f[4]);
    final lon = double.tryParse(f[5]);
    if (id == null || lat == null || lon == null) continue;

    // Column 6 is the feature class. 'P' is populated places; the rest are
    // mountains, streams, spots and so on, which would make a nearest-place
    // lookup name a river rather than a town.
    if (f[6] != 'P') continue;

    final name = f[1].trim();
    final country = f[8].trim();
    if (name.isEmpty || country.length != 2) continue;

    yield GeoNamesPlace(
      id: id,
      name: name,
      latitude: lat,
      longitude: lon,
      country: country,
      admin1Code: f[10].trim(),
      admin2Code: f[11].trim(),
      population: int.tryParse(f[14]) ?? 0,
      timeZone: f[17].trim(),
    );
  }
}

/// Lookup tables that turn division codes into the display names the app shows.
///
/// The built database stores names rather than codes, which is why
/// `Dhaka Division` appears verbatim in a place's `admin1`. It also means the
/// source data's inconsistencies are preserved: Bangladesh carries both
/// `Chittagong` and `Khulna Division`, and nothing here normalises that,
/// because inventing a suffix would be inventing data.
abstract final class AdminNames {
  /// `admin1CodesASCII.txt`: `CC.A1 <tab> name <tab> asciiName <tab> id`.
  static Future<Map<String, String>> readAdmin1(String path) =>
      _read(path, keyParts: 1);

  /// `admin2Codes.txt`: `CC.A1.A2 <tab> name <tab> asciiName <tab> id`.
  static Future<Map<String, String>> readAdmin2(String path) =>
      _read(path, keyParts: 2);

  static Future<Map<String, String>> _read(
    String path, {
    required int keyParts,
  }) async {
    final file = File(path);
    if (!file.existsSync()) {
      // Not fatal. Without these the places still resolve, they just carry no
      // division names, so the caller is told rather than stopped.
      stderr.writeln('  note: $path not found; division names will be blank');
      return const {};
    }

    final out = <String, String>{};
    final lines = file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (line.isEmpty) continue;
      final f = line.split('\t');
      if (f.length < 2) continue;
      // The key is already dotted in the source; keyParts only documents the
      // expected shape.
      if (f[0].split('.').length != keyParts + 1) continue;
      out[f[0]] = f[1].trim();
    }
    return out;
  }
}
