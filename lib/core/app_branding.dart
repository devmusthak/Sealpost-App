/// User-visible app name and wordmark (home screen, splash, notifications, legal copy).
abstract final class AppBranding {
  static const String displayName = 'LivConnect';
  static const String wordmark = 'LIVCONNECT';
  static const String defaultUserLabel = 'LivConnect User';

  static String settingsPermissionHint(String permission) =>
      'Enable it in Settings > $displayName > $permission.';
}
