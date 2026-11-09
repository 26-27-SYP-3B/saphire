/// Base URL of the Saphire server. The default comes from --dart-define; the URL the
/// guided setup saved replaces it when the app starts.
var apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://127.0.0.1:8080');
