import 'package:flutter_test/flutter_test.dart';

import 'package:eng_pulse_mobile/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const EngPulseApp());

    // Verify app title is displayed
    expect(find.text('Eng Pulse'), findsOneWidget);
  });
}
