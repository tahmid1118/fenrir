import 'package:integration_test/integration_test_driver.dart';

/// The `flutter drive` side of the perf test in `integration_test/perf_test.dart`.
///
/// `--profile` is only honoured by `flutter drive`, not by `flutter test`, so
/// this thin driver is what makes a real profile-mode measurement possible:
///
///     flutter drive \
///       --driver=test_driver/integration_test.dart \
///       --target=integration_test/perf_test.dart \
///       --profile -d <device>
Future<void> main() => integrationDriver();
