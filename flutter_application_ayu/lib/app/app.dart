import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme.dart';

class AyuMobileApp extends ConsumerWidget {
  const AyuMobileApp({super.key, this.configError});

  final String? configError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (configError != null && configError!.isNotEmpty) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Konfigurasi aplikasi belum siap',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 16),
                      Text(configError!),
                      const SizedBox(height: 12),
                      const Text(
                        'Gunakan perintah: flutter run --dart-define-from-file=config/dev.json',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'inventory_ayu',
      theme: AppTheme.lightTheme,
      routerConfig: router,
    );
  }
}
