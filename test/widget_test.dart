import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vp/screens/privacy_policy_screen.dart';

void main() {
  testWidgets('Privacy policy renders all sections', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PrivacyPolicyScreen()));

    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Version: 406'), findsOneWidget);
    expect(find.textContaining('1. Introduction'), findsOneWidget);

    // The last section is off-screen in the lazy ListView; scroll to it.
    await tester.scrollUntilVisible(
      find.textContaining('9. Contact Us'),
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(find.textContaining('9. Contact Us'), findsOneWidget);
  });
}
