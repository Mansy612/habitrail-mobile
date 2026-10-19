// Basic smoke test for Habitrail.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:habitrail/main.dart';

void main() {
  testWidgets('App renders the Habitrail title', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const HabitrailApp());
    expect(find.text('Habitrail'), findsOneWidget);
  });
}
