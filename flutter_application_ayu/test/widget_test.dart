// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:inventory_ayu/app/app.dart';
import 'package:inventory_ayu/app/router.dart';
import 'package:inventory_ayu/core/providers/auth_controller.dart';

void main() {
  test('Unauthenticated launch leaves splash for login', () {
    expect(redirectForAuth(AuthStatus.unauthenticated, '/splash'), '/login');
  });

  test('Authenticated launch leaves splash for dashboard', () {
    expect(redirectForAuth(AuthStatus.authenticated, '/splash'), '/');
  });

  test('Unknown session stays on splash while it resolves', () {
    expect(redirectForAuth(AuthStatus.unknown, '/splash'), '/splash');
  });

  test('Unauthenticated protected route redirects to login', () {
    expect(redirectForAuth(AuthStatus.unauthenticated, '/inventory'), '/login');
  });

  testWidgets('App shows config warning when Supabase is not configured', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: AyuMobileApp(configError: 'Konfigurasi belum siap'),
      ),
    );

    expect(find.text('Konfigurasi aplikasi belum siap'), findsOneWidget);
    expect(find.text('Konfigurasi belum siap'), findsOneWidget);
  });
}
