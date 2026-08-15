import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fenrir/main.dart';
import 'package:fenrir/src/ui/map_view.dart';

/// Measures NFR-4 on real hardware: sustained 60 fps during pan and zoom.
///
/// A debug build's frame times prove nothing — debug mode carries assertion
/// and JIT overhead a release user never pays. This runs in `--profile` mode,
/// release-optimised with just enough instrumentation left to watch real
/// engine `FrameTiming`, and drives real gestures on a real device so the
/// frames are actually rasterised by the phone's GPU rather than simulated.
///
/// `flutter test integration_test/perf_test.dart -d <device> --profile`
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('map pan and zoom stay inside the 16.6 ms frame budget',
      (tester) async {
    await tester.pumpWidget(const FenrirApp());

    // First launch extracts ~28 MB of bundled assets and waits for a GNSS
    // fix; neither is the thing being measured, so it happens before the
    // watched section rather than inside it.
    await tester.pumpAndSettle(const Duration(seconds: 8));

    final mapFinder = find.byType(MapView);
    expect(mapFinder, findsOneWidget,
        reason: 'the map must be on screen before it can be measured');

    // A point inside the map but above the bottom sheet, so drags land on the
    // map's own gesture detector rather than the sheet's scroll view.
    const gesturePoint = Offset(200, 300);

    await binding.watchPerformance(() async {
      // Pan: a lap in each direction, the everyday interaction NFR-4 is about.
      for (var i = 0; i < 8; i++) {
        await tester.dragFrom(gesturePoint, const Offset(-140, -90));
        await tester.pump();
      }
      for (var i = 0; i < 8; i++) {
        await tester.dragFrom(gesturePoint, const Offset(140, 90));
        await tester.pump();
      }

      // Zoom, via the double-tap gesture flutter_map recognises natively. A
      // synthetic pinch needs two independent pointers, which WidgetTester's
      // high-level helpers do not expose; double-tap exercises the same
      // animated-zoom code path flutter_map runs for a pinch.
      for (var i = 0; i < 4; i++) {
        await tester.tapAt(gesturePoint);
        await tester.tapAt(gesturePoint);
        await tester.pump(const Duration(milliseconds: 300));
      }

      await tester.pumpAndSettle();
    }, reportKey: 'map_pan_zoom');

    final summary = binding.reportData?['map_pan_zoom'] as Map<String, Object?>?;
    expect(summary, isNotNull, reason: 'no frames were recorded');

    double ms(String key) => (summary![key] as num).toDouble();
    int count(String key) => (summary![key] as num).toInt();

    // ignore: avoid_print
    print(
      'NFR-4 frame budget (16.6 ms for 60 fps):\n'
      '  build    avg ${ms('average_frame_build_time_millis').toStringAsFixed(2)} ms, '
      'worst ${ms('worst_frame_build_time_millis').toStringAsFixed(2)} ms, '
      '90th ${ms('90th_percentile_frame_build_time_millis').toStringAsFixed(2)} ms\n'
      '  raster   avg ${ms('average_frame_rasterizer_time_millis').toStringAsFixed(2)} ms, '
      'worst ${ms('worst_frame_rasterizer_time_millis').toStringAsFixed(2)} ms, '
      '90th ${ms('90th_percentile_frame_rasterizer_time_millis').toStringAsFixed(2)} ms\n'
      '  frames   ${count('frame_count')} recorded, '
      'missed ${count('missed_frame_build_budget_count')} build / '
      '${count('missed_frame_rasterizer_budget_count')} raster',
    );

    // The NFR-4 assertion itself: p90 build and raster time both inside the
    // 16.6 ms budget a 60 Hz display needs.
    expect(ms('90th_percentile_frame_build_time_millis'), lessThan(16.6),
        reason: 'build phase is missing the 60 fps budget at p90');
    expect(ms('90th_percentile_frame_rasterizer_time_millis'), lessThan(16.6),
        reason: 'rasterizer is missing the 60 fps budget at p90');
  });
}
