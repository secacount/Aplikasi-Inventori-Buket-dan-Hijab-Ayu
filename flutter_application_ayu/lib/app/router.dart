import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/providers/auth_controller.dart';
import '../features/auth/screens/login_screen.dart';
import '../features/business/screens/business_members_screen.dart';
import '../features/dashboard/screens/dashboard_screen.dart';
import '../features/inventory/screens/inventory_screen.dart';
import '../features/inventory/screens/stock_history_screen.dart';
import '../features/splash/screens/splash_screen.dart';

String? redirectForAuth(AuthStatus status, String location) {
  if (status == AuthStatus.unknown) return '/splash';

  final isAuthRoute = location == '/login' || location == '/splash';
  if (status == AuthStatus.authenticated) {
    return isAuthRoute ? '/' : null;
  }
  if (location == '/splash' || !isAuthRoute) return '/login';
  return null;
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final authController = ref.watch(authControllerProvider);

  final router = GoRouter(
    initialLocation: '/splash',
    refreshListenable: authController,
    redirect: (context, state) =>
        redirectForAuth(authController.status, state.matchedLocation),
    routes: [
      GoRoute(path: '/splash', builder: (_, state) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, state) => const LoginScreen()),
      GoRoute(path: '/', builder: (_, state) => const DashboardScreen()),
      GoRoute(
        path: '/members',
        builder: (_, state) => const BusinessMembersScreen(),
      ),
      GoRoute(
        path: '/inventory',
        builder: (_, state) => const InventoryScreen(),
      ),
      GoRoute(
        path: '/history',
        builder: (_, state) => const StockHistoryScreen(),
      ),
    ],
  );

  ref.onDispose(router.dispose);
  return router;
});
