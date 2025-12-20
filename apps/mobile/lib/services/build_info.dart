/// Build information injected at compile time
class BuildInfo {
  /// Git commit hash (short), passed via --dart-define=GIT_COMMIT=xxx
  static const String gitCommit = String.fromEnvironment(
    'GIT_COMMIT',
    defaultValue: 'dev',
  );

  /// Build timestamp, passed via --dart-define=BUILD_TIME=xxx
  static const String buildTime = String.fromEnvironment(
    'BUILD_TIME',
    defaultValue: 'local',
  );

  /// App version
  static const String version = '1.0.0';

  /// Full version string for display
  static String get fullVersion => '$version ($gitCommit)';
}
