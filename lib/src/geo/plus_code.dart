/// Open Location Code (Plus Codes) — offline encoding and decoding.
///
/// FR-2.2 requires a Plus Code for the current position, chosen over
/// what3words because it is an open standard with no licence fee. It is purely
/// algorithmic: no dataset, no network, valid on every square metre of the
/// planet. That is the point spec section 2.4 makes — anything that can be
/// computed rather than looked up should be.
///
/// This is a Dart implementation of the reference algorithm published by
/// Google at https://github.com/google/open-location-code, which is licensed
/// under the Apache License 2.0. It is implemented here rather than taken from
/// the `open_location_code` package because that package requires
/// `latlong2: ^0.9.0`, which cannot resolve against the `^0.10.1` that
/// `flutter_map` needs.
///
/// The arithmetic deliberately works in integers, converting to degrees only
/// at the very end. Doing it in floating point accumulates representation
/// error and produces off-by-one results in the final digit — which is why the
/// reference implementations moved to integers, and why this one follows them
/// closely. Correctness is graded against the project's official test vectors
/// in `test/geo/fixtures/`.
///
/// Shortening and recovery relative to a reference location are not
/// implemented: no in-scope requirement needs them.
library;

/// Separates the two halves of a code. Always at index 8 in a full code.
const String _separator = '+';
const int _separatorPosition = 8;

/// Stands in for digits that a lower-precision code does not specify.
const String _padding = '0';

/// The code alphabet, chosen to avoid characters that form recognisable words.
const String _alphabet = '23456789CFGHJMPQRVWX';
const int _encodingBase = 20; // _alphabet.length

const int _latitudeMax = 90;
const int _longitudeMax = 180;

const int _minDigitCount = 2;
const int _maxDigitCount = 15;

/// The first ten digits are latitude/longitude pairs in base 20.
const int _pairCodeLength = 10;
const int _pairFirstPlaceValue = 160000; // 20^(10/2 - 1)
const int _pairPrecision = 8000; // 20^3

/// Beyond ten digits the algorithm switches to a 4x5 grid, so that precision
/// can be refined one character at a time instead of two.
const int _gridCodeLength = 5; // _maxDigitCount - _pairCodeLength
const int _gridColumns = 4;
const int _gridRows = 5;
const int _gridLatFirstPlaceValue = 625; // 5^4
const int _gridLngFirstPlaceValue = 256; // 4^4

/// Multipliers that turn degrees into the integer space the algorithm works in.
const int _finalLatPrecision = 25000000; // 8000 * 5^5
const int _finalLngPrecision = 8192000; // 8000 * 4^5

/// The default number of digits generated for a position.
///
/// Eleven digits describes roughly a 2.8 x 3.5 metre box, finer than a GNSS
/// fix is usually worth. The extra digit costs one character and keeps the
/// code useful when the fix is good; the honesty about how good the fix
/// actually is belongs to the accuracy radius shown alongside it (FR-1.2), not
/// to silently truncating the code.
const int defaultCodeLength = 11;

/// The rectangular area a Plus Code refers to.
///
/// Codes name areas, not points, and the area grows as the code shortens. The
/// bounds are carried rather than just a centre so that a decoded code can be
/// drawn honestly on the map.
class PlusCodeArea {
  const PlusCodeArea({
    required this.latitudeLo,
    required this.longitudeLo,
    required this.latitudeHi,
    required this.longitudeHi,
    required this.codeLength,
  });

  /// Latitude of the south-west corner, in degrees.
  final double latitudeLo;

  /// Longitude of the south-west corner, in degrees.
  final double longitudeLo;

  /// Latitude of the north-east corner, in degrees.
  final double latitudeHi;

  /// Longitude of the north-east corner, in degrees.
  final double longitudeHi;

  /// Number of digits in the code this area came from.
  final int codeLength;

  double get latitudeCenter {
    final c = latitudeLo + (latitudeHi - latitudeLo) / 2;
    return c < _latitudeMax ? c : _latitudeMax.toDouble();
  }

  double get longitudeCenter {
    final c = longitudeLo + (longitudeHi - longitudeLo) / 2;
    return c < _longitudeMax ? c : _longitudeMax.toDouble();
  }

  @override
  String toString() =>
      'PlusCodeArea($latitudeLo, $longitudeLo, $latitudeHi, $longitudeHi, '
      'len $codeLength)';
}

/// Thrown when a code or code length is not usable.
class PlusCodeException implements Exception {
  const PlusCodeException(this.message);
  final String message;
  @override
  String toString() => 'PlusCodeException: $message';
}

/// Multiplies a coordinate into the integer space and floors it, absorbing
/// floating-point representation error on the way.
///
/// A plain `(value * precision).floor()` is wrong for inputs whose product
/// lands a hair below an integer. Longitude -54.8019 times 25,000,000 evaluates
/// to -1370047500.0000002, and flooring that gives -1370047501 — a whole unit
/// out, which shifts the final digit of the code and can put the decoded area
/// beside the position instead of around it.
///
/// Rounding at a scale a million times finer first snaps such values back onto
/// the integer they were meant to be, while leaving genuine half-way values
/// (x.5, which must floor downward) untouched. This mirrors what the reference
/// implementations do.
int _scaleAndFloor(double value, int precision) {
  return ((value * precision * 1e6).round() / 1e6).floor();
}

/// Converts a position into the integer space the encoder works in.
///
/// Latitude is clamped to the valid range; a position exactly at the north
/// pole is pulled one unit south so the code it produces can still be decoded.
/// Longitude wraps, so 181 degrees and -179 describe the same meridian.
(int, int) locationToIntegers(double latitude, double longitude) {
  var latVal = _scaleAndFloor(latitude, _finalLatPrecision);
  latVal += _latitudeMax * _finalLatPrecision;
  if (latVal < 0) {
    latVal = 0;
  } else if (latVal >= 2 * _latitudeMax * _finalLatPrecision) {
    latVal = 2 * _latitudeMax * _finalLatPrecision - 1;
  }

  var lngVal = _scaleAndFloor(longitude, _finalLngPrecision);
  lngVal += _longitudeMax * _finalLngPrecision;
  const lngRange = 2 * _longitudeMax * _finalLngPrecision;
  if (lngVal < 0) {
    // `remainder` keeps the sign of the dividend, matching the reference
    // implementation. Dart's `%` would already return a non-negative result
    // and so would differ from it at exact multiples of the range.
    lngVal = lngVal.remainder(lngRange) + lngRange;
  } else if (lngVal >= lngRange) {
    lngVal = lngVal.remainder(lngRange);
  }

  return (latVal, lngVal);
}

/// Encodes a position as a Plus Code.
///
/// [codeLength] counts digits, not characters: a ten-digit code renders as
/// eleven characters, because of the separator. Lengths below ten must be
/// even, since an odd length would describe a box with sides in a 20:1 ratio.
String encodePlusCode(
  double latitude,
  double longitude, {
  int codeLength = defaultCodeLength,
}) {
  final (latInt, lngInt) = locationToIntegers(latitude, longitude);
  return encodePlusCodeIntegers(latInt, lngInt, codeLength: codeLength);
}

/// Encodes a position already converted to the integer space.
///
/// Exposed because the project's official encoding vectors supply these
/// integers directly, which separates a fault in the digit arithmetic from a
/// fault in the degrees-to-integer conversion.
String encodePlusCodeIntegers(
  int latInt,
  int lngInt, {
  int codeLength = defaultCodeLength,
}) {
  var length = codeLength;
  if (length > _maxDigitCount) length = _maxDigitCount;

  if (length < _minDigitCount ||
      (length < _pairCodeLength && length.isOdd)) {
    throw PlusCodeException('Invalid Open Location Code length: $codeLength');
  }

  var lat = latInt;
  var lng = lngInt;

  // Sixteen slots: eight pair digits, the separator, two more pair digits,
  // then five grid digits.
  final code = List<String>.filled(_maxDigitCount + 1, '');
  code[_separatorPosition] = _separator;

  if (length > _pairCodeLength) {
    for (var i = _gridCodeLength; i >= 1; i--) {
      final latDigit = lat % _gridRows;
      final lngDigit = lng % _gridColumns;
      code[_separatorPosition + 2 + i] =
          _alphabet[latDigit * _gridColumns + lngDigit];
      lat = lat ~/ _gridRows;
      lng = lng ~/ _gridColumns;
    }
  } else {
    // Discard the grid-precision part wholesale.
    for (var i = 0; i < _gridCodeLength; i++) {
      lat = lat ~/ _gridRows;
      lng = lng ~/ _gridColumns;
    }
  }

  // The pair that follows the separator.
  code[_separatorPosition + 1] = _alphabet[lat % _encodingBase];
  code[_separatorPosition + 2] = _alphabet[lng % _encodingBase];
  lat = lat ~/ _encodingBase;
  lng = lng ~/ _encodingBase;

  // The eight pair digits that precede it, most significant last.
  for (var i = _pairCodeLength ~/ 2 + 1; i >= 0; i -= 2) {
    code[i] = _alphabet[lat % _encodingBase];
    code[i + 1] = _alphabet[lng % _encodingBase];
    lat = lat ~/ _encodingBase;
    lng = lng ~/ _encodingBase;
  }

  if (length >= _separatorPosition) {
    return code.sublist(0, length + 1).join();
  }
  return code.sublist(0, length).join() +
      _padding * (_separatorPosition - length) +
      _separator;
}

/// Decodes a full Plus Code into the area it describes.
///
/// Throws [PlusCodeException] if the code is not a valid full code. Short
/// codes cannot be decoded on their own — they are meaningless without the
/// reference location they were shortened against.
PlusCodeArea decodePlusCode(String code) {
  if (!isFullPlusCode(code)) {
    throw PlusCodeException('Not a valid full Plus Code: $code');
  }

  final clean = code.replaceAll(_separator, '').replaceAll(_padding, '').toUpperCase();

  var normalLat = -_latitudeMax * _pairPrecision;
  var normalLng = -_longitudeMax * _pairPrecision;
  var gridLat = 0;
  var gridLng = 0;

  var digits = clean.length < _pairCodeLength ? clean.length : _pairCodeLength;
  var pv = _pairFirstPlaceValue;
  for (var i = 0; i < digits; i += 2) {
    normalLat += _alphabet.indexOf(clean[i]) * pv;
    normalLng += _alphabet.indexOf(clean[i + 1]) * pv;
    if (i < digits - 2) pv = pv ~/ _encodingBase;
  }

  var latPrecision = pv / _pairPrecision;
  var lngPrecision = pv / _pairPrecision;

  if (clean.length > _pairCodeLength) {
    var rowpv = _gridLatFirstPlaceValue;
    var colpv = _gridLngFirstPlaceValue;
    digits = clean.length < _maxDigitCount ? clean.length : _maxDigitCount;
    for (var i = _pairCodeLength; i < digits; i++) {
      final digitVal = _alphabet.indexOf(clean[i]);
      gridLat += (digitVal ~/ _gridColumns) * rowpv;
      gridLng += (digitVal % _gridColumns) * colpv;
      if (i < digits - 1) {
        rowpv = rowpv ~/ _gridRows;
        colpv = colpv ~/ _gridColumns;
      }
    }
    latPrecision = rowpv / _finalLatPrecision;
    lngPrecision = colpv / _finalLngPrecision;
  }

  final lat = normalLat / _pairPrecision + gridLat / _finalLatPrecision;
  final lng = normalLng / _pairPrecision + gridLng / _finalLngPrecision;

  return PlusCodeArea(
    latitudeLo: lat,
    longitudeLo: lng,
    latitudeHi: lat + latPrecision,
    longitudeHi: lng + lngPrecision,
    codeLength:
        clean.length < _maxDigitCount ? clean.length : _maxDigitCount,
  );
}

/// Whether [code] is a well-formed Plus Code, full or short.
bool isValidPlusCode(String code) {
  if (code.isEmpty || code.length == 1) return false;

  final sepIndex = code.indexOf(_separator);
  if (sepIndex == -1) return false;
  if (sepIndex != code.lastIndexOf(_separator)) return false;
  if (sepIndex > _separatorPosition || sepIndex.isOdd) return false;

  final padIndex = code.indexOf(_padding);
  if (padIndex > -1) {
    // Short codes cannot carry padding.
    if (sepIndex < _separatorPosition) return false;
    if (padIndex == 0) return false;

    // Padding must form a single run of even length, and the code must then
    // end at the separator.
    final runs = RegExp('$_padding+').allMatches(code).toList();
    if (runs.length > 1) return false;
    final runLength = runs.first.end - runs.first.start;
    if (runLength.isOdd || runLength > _separatorPosition - 2) return false;
    if (!code.endsWith(_separator)) return false;
  }

  // A single character after the separator is not a legal code.
  if (code.length - sepIndex - 1 == 1) return false;

  final stripped = code
      .replaceFirst(RegExp(r'\++'), '')
      .replaceFirst(RegExp('$_padding+'), '');
  for (var i = 0; i < stripped.length; i++) {
    final ch = stripped[i].toUpperCase();
    if (ch != _separator && !_alphabet.contains(ch)) return false;
  }
  return true;
}

/// Whether [code] has been shortened relative to some reference location, and
/// so cannot be decoded on its own.
bool isShortPlusCode(String code) {
  if (!isValidPlusCode(code)) return false;
  final sepIndex = code.indexOf(_separator);
  return sepIndex >= 0 && sepIndex < _separatorPosition;
}

/// Whether [code] is a complete code that decodes without a reference location.
bool isFullPlusCode(String code) {
  if (!isValidPlusCode(code)) return false;
  if (isShortPlusCode(code)) return false;

  // The leading digit bounds the latitude; a value past 90 degrees is not a
  // position anywhere on Earth.
  final firstLatValue =
      _alphabet.indexOf(code[0].toUpperCase()) * _encodingBase;
  if (firstLatValue >= _latitudeMax * 2) return false;

  if (code.length > 1) {
    final firstLngValue =
        _alphabet.indexOf(code[1].toUpperCase()) * _encodingBase;
    if (firstLngValue >= _longitudeMax * 2) return false;
  }
  return true;
}
