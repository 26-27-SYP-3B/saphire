import 'package:dio/dio.dart';

/// What the setup and the settings say about an address.
const emptyMessage = 'Server-Adresse: eine Adresse angeben.';
const invalidMessage = 'Server-Adresse: http:// oder https:// mit Host';
const unreachableMessage = 'Der Server ist nicht erreichbar.';
const busyMessage = 'Der Server ist erreichbar, aber gerade ausgelastet. Versuche es gleich noch einmal.';
const notSaphireMessage = 'Die Adresse antwortet nicht wie ein Saphire-Server.';

/// The base without trailing slashes: every path is built as base + '/api/...',
/// and with a slash the server would see '//api/...' instead of the check.
String normalizeBase(String url) => url.replaceAll(RegExp(r'/+$'), '');

/// Check an address the documented way (api-docs.md): GET /api/session without a
/// token answers 401 with the JSON error shape. Only that answer confirms a Saphire
/// server; a 404 page or a 429 from the rate limiter is not one. Every answer is
/// read, so only a failing transport is "unreachable". Returns null when the
/// address confirmed itself, otherwise the message to show.
Future<String?> checkServer(Dio dio, String base) async {
  Response response;
  try {
    response = await dio.get(
      '$base/api/session',
      options: Options(
        validateStatus: (status) => true,
        // A hanging address would otherwise block the correction for as long as
        // the OS waits, and the field stays locked while the check runs.
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ),
    );
  } on DioException {
    // With validateStatus always true, only the transport can fail here.
    return unreachableMessage;
  }

  final data = response.data;
  if (response.statusCode == 401 && data is Map && data['error'] is String) return null;
  // The session check is rate-limited, so a correct server can answer 429.
  if (response.statusCode == 429) return busyMessage;
  return notSaphireMessage;
}
