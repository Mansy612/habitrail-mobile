// Basic smoke test for Habitrail.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:habitrail/main.dart';

void main() {
  testWidgets('App builds without error', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const HabitrailApp());
    // First frame renders a MaterialApp (loading spinner until state loads).
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
