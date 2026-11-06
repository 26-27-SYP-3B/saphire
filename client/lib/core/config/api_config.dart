/// Base URL of the Saphire server.
/// Override at launch: flutter run --dart-define=API_BASE_URL=http://host:8080
const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8080',
);
