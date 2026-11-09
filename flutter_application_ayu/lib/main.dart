import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('id_ID');

  final appConfig = AppConfig.fromEnvironment();

  if (!appConfig.isValid) {
    runApp(
      const ProviderScope(
        child: AyuMobileApp(
          configError: 'Konfigurasi Supabase belum siap. Pastikan file config/dev.json berisi SUPABASE_URL dan SUPABASE_PUBLISHABLE_KEY.',
        ),
      ),
    );
    return;
  }

  await Supabase.initialize(
    url: appConfig.supabaseUrl,
    publishableKey: appConfig.supabasePublishableKey,
  );

  runApp(const ProviderScope(child: AyuMobileApp()));
}
