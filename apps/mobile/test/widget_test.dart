import 'package:flutter_test/flutter_test.dart';

import 'package:eng_pulse_mobile/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const EngPulseApp());

    // Verify app title is displayed on splash screen
    expect(find.text('Eng Pulse'), findsOneWidget);

    // Pump through the splash screen timer (2s) and transition animation (500ms)
    // to complete navigation and avoid "Timer is still pending" error
    await tester.pump(const Duration(milliseconds: 2100));
    await tester.pump(const Duration(milliseconds: 600));

    // Allow any remaining frames to settle
    await tester.pump();
  });
}
