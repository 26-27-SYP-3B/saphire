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

  int statusCode;
  Object body;
  final Map<String, List<String>> headers;
  RequestOptions? lastOptions;

  /// Every request, in the order the page made them. A page that fills the queue and then
  /// reads it again makes two calls, so a test that checks what it sent needs the first
  /// one, not the last.
  final List<RequestOptions> requests = [];

  /// The body as the server would receive it, so a multipart form can be checked.
  String lastBody = '';

  /// Answers taken in order for the following requests, so one batch can mix
  /// success and error. When the list is empty, the fixed answer above is used.
  /// The body is an Object rather than a Map so a test can also answer an empty list,
  /// which is what an empty library or an empty queue is.
  final List<(int, Object)> queue = [];

  /// When set, the answer is only given after it completes, so a test can look at
  /// a row while its file is still on the way.
  Future<void>? wait;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    requests.add(options);
    if (requestStream != null) {
      // The body is binary as soon as a real file is in it, so decoding it is
      // only for looking at the part names.
      // The body is read chunk by chunk, which is what Dio reports as progress.
      lastBody = utf8.decode((await requestStream.toList()).expand((chunk) => chunk).toList(), allowMalformed: true);
    }

    int status = statusCode;
    Object answer = body;
    if (queue.isNotEmpty) {
      (status, answer) = queue.removeAt(0);
    }

    if (wait != null) await wait;

    return ResponseBody.fromString(
      jsonEncode(answer),
      status,
      headers: {HttpHeaders.contentTypeHeader: ['application/json'], ...headers},
    );
  }

  @override
  void close({bool force = false}) {}
}
