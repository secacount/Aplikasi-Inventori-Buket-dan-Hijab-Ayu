import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

class AuthController extends ChangeNotifier {
  AuthController() {
    final currentSession = _client.auth.currentSession;
    _status = currentSession == null ? AuthStatus.unauthenticated : AuthStatus.authenticated;
    _session = currentSession;

    _sub = _client.auth.onAuthStateChange.listen((authState) {
      final session = authState.session;
      _session = session;
      _status = session == null ? AuthStatus.unauthenticated : AuthStatus.authenticated;
      notifyListeners();
    });
  }

  final SupabaseClient _client = Supabase.instance.client;
  StreamSubscription<dynamic>? _sub;

  AuthStatus _status = AuthStatus.unknown;
  Session? _session;

  AuthStatus get status => _status;
  Session? get session => _session;
  bool get isAuthenticated => _status == AuthStatus.authenticated && _session != null;

  Future<void> signInWithPassword({required String email, required String password}) async {
    final response = await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    _session = response.session;
    _status = response.session == null ? AuthStatus.unauthenticated : AuthStatus.authenticated;
    notifyListeners();
  }

  Future<AuthResponse> signUpWithPassword({required String email, required String password}) {
    return _client.auth.signUp(
      email: email.trim(),
      password: password,
    );
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
    _session = null;
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final authControllerProvider = Provider<AuthController>((ref) {
  final controller = AuthController();
  ref.onDispose(controller.dispose);
  return controller;
});
