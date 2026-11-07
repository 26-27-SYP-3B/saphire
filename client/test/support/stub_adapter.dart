import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

/// Adapter that returns one fixed answer instead of going to the network, and
/// remembers the last request so the headers and the body can be checked.
class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.statusCode, this.body, {Map<String, List<String>>? headers})
      : headers = headers ?? const {},
        lastOptions = null,
        lastBody = '';

  final int statusCode;
  final Object body;
  final Map<String, List<String>> headers;
  RequestOptions? lastOptions;

  /// The body as the server would receive it, so a multipart form can be checked.
  String lastBody = '';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    if (requestStream != null) {
      // The body is binary as soon as a real file is in it, so decoding it is
      // only for looking at the part names.
      lastBody = utf8.decode((await requestStream.toList()).expand((chunk) => chunk).toList(), allowMalformed: true);
    }

    return ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {HttpHeaders.contentTypeHeader: ['application/json'], ...headers},
    );
  }

  @override
  void close({bool force = false}) {}
}
