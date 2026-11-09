class AppConfig {
  const AppConfig({required this.supabaseUrl, required this.supabasePublishableKey});

  final String supabaseUrl;
  final String supabasePublishableKey;

  factory AppConfig.fromEnvironment() {
    return const AppConfig(
      supabaseUrl: String.fromEnvironment('SUPABASE_URL', defaultValue: ''),
      supabasePublishableKey: String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY', defaultValue: ''),
    );
  }

  bool get isValid => supabaseUrl.trim().isNotEmpty && supabasePublishableKey.trim().isNotEmpty;

  String get validationError {
    if (supabaseUrl.trim().isEmpty) {
      return 'SUPABASE_URL belum diisi. Gunakan --dart-define-from-file=config/dev.json.';
    }
    if (supabasePublishableKey.trim().isEmpty) {
      return 'SUPABASE_PUBLISHABLE_KEY belum diisi. Gunakan --dart-define-from-file=config/dev.json.';
    }
    return '';
  }
}
