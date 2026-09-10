import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Every failure the API can hand back, in the one shape the server promises:
/// `ok`, `error`, `message`, and `errors` on validation only.
///
/// The server documents that contract in API-Reference_v1.md §1, and a test
/// walks the route table to keep it honest — so parsing one shape here is safe
/// rather than optimistic.
class ApiException implements Exception {
  ApiException({
    required this.error,
    required this.message,
    this.statusCode,
    this.fieldErrors = const {},
  });

  final String error;
  final String message;
  final int? statusCode;

  /// Per-field detail. Populated for `validation_failed` and nothing else.
  final Map<String, List<String>> fieldErrors;

  /// The token is gone, revoked, or was never valid. The app has to sign out
  /// rather than retry — retrying a dead token just burns rate limit.
  bool get isUnauthenticated => error == 'unauthenticated';

  /// Within the punch cooldown. The reference is explicit that this reads as
  /// success to the person holding the phone: the punch they wanted is on
  /// record, they just tapped twice.
  bool get isDuplicateScan => error == 'duplicate_scan';

  bool get isRateLimited => error == 'too_many_requests';

  /// The request never reached the server — no signal, a captive portal, or a
  /// server that is down.
  ///
  /// The distinction that matters for B2.4: a punch that was *refused* is
  /// settled and must not be queued, while one that never arrived is not the
  /// person's fault and must not be lost. Set by the client itself in [_send],
  /// so it never collides with a code the server could return.
  bool get isNetworkFailure =>
      error == 'network_unreachable' || error == 'network_error';

  /// First message for a given field, for showing under a form input.
  String? fieldError(String field) {
    final list = fieldErrors[field];
    return (list == null || list.isEmpty) ? null : list.first;
  }

  /// The server's own words for this failure, ready to show.
  ///
  /// **Not the whole answer to "what do I put on screen".** The codes the
  /// client raises itself have no server text behind them and are translated
  /// by `ApiErrorText.text` in core/l10n.dart, which every screen calls
  /// instead of this. Empty when the server named no message: there is nothing
  /// to show, and inventing an English sentence here would put one language
  /// past the translation layer.
  ///
  /// Validation failures carry a generic top-line ("The given data was
  /// invalid") and the useful text sits in the field detail, so prefer that
  /// when there is exactly one.
  String get displayMessage {
    if (error == 'validation_failed' && fieldErrors.length == 1) {
      final only = fieldErrors.values.first;
      if (only.isNotEmpty) return only.first;
    }
    return message;
  }

  @override
  String toString() => 'ApiException($error): $message';
}

/// Thin wrapper over the v1 API.
///
/// Deliberately not a generated client: the surface is 22 endpoints and the
/// response shape is uniform, so hand-writing it costs less than keeping a
/// generator in the build.
class ApiClient {
  ApiClient({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  /// 10.0.2.2 is the host machine as seen from inside the Android emulator —
  /// `localhost` there is the emulator itself, which serves nothing.
  ///
  /// Override for a real device or a deployed server:
  ///   flutter run --dart-define=API_BASE=https://emp.klutchcleaning.com/api/v1
  static const String baseUrl = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'http://10.0.2.2:8000/api/v1',
  );

  /// The public site behind the API — where the privacy policy and the account
  /// deletion page are served from.
  ///
  /// Derived from [baseUrl] rather than configured separately: both stores
  /// compare the policy the app links to against the one on the listing, and two
  /// independent settings would eventually point at two different servers.
  static String get siteUrl {
    final apiSegment = baseUrl.indexOf('/api/');

    return apiSegment == -1 ? baseUrl : baseUrl.substring(0, apiSegment);
  }

  /// Refuse to run a release build that still points at the development server.
  ///
  /// Nothing else catches this. dart:io opens its own sockets, so it consults
  /// neither Android's network security config nor iOS App Transport Security —
  /// both platforms will happily let a shipped build speak plain HTTP. And the
  /// symptom is not an error but a hang: 10.0.2.2 means nothing on a real
  /// handset, so every screen sits on a spinner until the socket times out.
  ///
  /// Whoever forgot the --dart-define needs to hear about it at the first
  /// launch on a test device, not from a reviewer.
  static void assertSecureBaseUrl() {
    if (kReleaseMode && !baseUrl.startsWith('https://')) {
      throw StateError(
        'This release build would talk to "$baseUrl". Rebuild with '
        '--dart-define=API_BASE=https://emp.klutchcleaning.com/api/v1',
      );
    }
  }

  /// The Sanctum bearer token, or null when signed out. Set by [Session] on
  /// login and on session restore; cleared on logout.
  String? token;

  /// The language this handset is reading the app in (B6.2), for
  /// `Accept-Language`. Set by [Session] from `AppLocale`, and kept in step
  /// with it — a header naming a language the person switched away from an
  /// hour ago is worse than no header.
  String? acceptLanguage;

  Map<String, String> _headers({bool withBody = false}) => {
        // Without this Laravel may answer a failure with an HTML redirect
        // instead of the JSON error shape. The reference calls this out
        // specifically, and it is the single easiest way to break the client.
        'Accept': 'application/json',
        // What language to answer in, when the server has an answer in it. It
        // does not yet — every message it sends is English — so this changes
        // nothing today and is the only thing that will have to be true on the
        // day it does. Sent on every request rather than only the ones that can
        // fail: a rejection is not the only thing with words in it.
        if (acceptLanguage != null) 'Accept-Language': acceptLanguage!,
        if (withBody) 'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) =>
      _send(() {
        final uri = Uri.parse('$baseUrl$path').replace(
          queryParameters: query?.map((k, v) => MapEntry(k, '$v')),
        );
        return _http.get(uri, headers: _headers());
      });

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
  }) =>
      _send(() => _http.post(
            Uri.parse('$baseUrl$path'),
            headers: _headers(withBody: true),
            body: jsonEncode(body ?? const {}),
          ));

  Future<Map<String, dynamic>> put(
    String path, {
    Map<String, dynamic>? body,
  }) =>
      _send(() => _http.put(
            Uri.parse('$baseUrl$path'),
            headers: _headers(withBody: true),
            body: jsonEncode(body ?? const {}),
          ));

  Future<Map<String, dynamic>> delete(
    String path, {
    Map<String, dynamic>? body,
  }) =>
      _send(() => _http.delete(
            Uri.parse('$baseUrl$path'),
            headers: _headers(withBody: true),
            body: jsonEncode(body ?? const {}),
          ));

  /// Fetch a file rather than JSON.
  ///
  /// `GET /documents/{id}` is the one endpoint whose success body is not JSON —
  /// it is the document. Failures still are, so this decodes only when the
  /// status says something went wrong, and hands back the bytes otherwise.
  ///
  /// Deliberately not routed through [_send]: that decodes every response, and
  /// running a PDF through jsonDecode would report "not JSON" for a file that
  /// arrived perfectly.
  ///
  /// Longer timeout than the JSON calls. Twenty seconds is generous for a
  /// status payload and mean for a ten-megabyte contract over hotel wifi.
  Future<({List<int> bytes, String? filename})> getFile(String path) async {
    late final http.Response response;

    try {
      response = await _http
          .get(Uri.parse('$baseUrl$path'), headers: _headers())
          .timeout(const Duration(seconds: 90));
    } on SocketException {
      throw ApiException(
        error: 'network_unreachable',
        message: 'Cannot reach the server. Is it running, and bound to 0.0.0.0?',
      );
    } catch (e) {
      throw ApiException(
        error: 'network_error',
        message: 'Network problem: $e',
      );
    }

    if (response.statusCode >= 400) {
      Map<String, dynamic> decoded = const {};
      try {
        final raw = jsonDecode(response.body);
        if (raw is Map<String, dynamic>) decoded = raw;
      } on FormatException {
        // A failure that is not JSON either — a web-server error page.
      }

      throw ApiException(
        error: '${decoded['error'] ?? 'download_failed'}',
        // Empty rather than an English sentence when the server named none:
        // see [ApiException.displayMessage].
        message: '${decoded['message'] ?? ''}',
        statusCode: response.statusCode,
      );
    }

    return (
      bytes: response.bodyBytes,
      filename: _filenameFrom(response.headers['content-disposition']),
    );
  }

  /// The name the server sent, from `Content-Disposition`.
  ///
  /// Best effort: the header is the server's word for what the file is called,
  /// and the caller has the document's own `original_name` to fall back on.
  static String? _filenameFrom(String? disposition) {
    if (disposition == null) return null;

    final match = RegExp(r'filename\*?=(?:UTF-8'
            r"''"
            r')?"?([^";]+)"?')
        .firstMatch(disposition);

    final name = match?.group(1)?.trim();

    return (name == null || name.isEmpty) ? null : Uri.decodeComponent(name);
  }

  Future<Map<String, dynamic>> _send(
    Future<http.Response> Function() request,
  ) async {
    late final http.Response response;

    try {
      response = await request().timeout(const Duration(seconds: 20));
    } on SocketException {
      // The most common failure in development by a wide margin: the Laravel
      // server is not running, or is bound to 127.0.0.1 where the emulator
      // cannot reach it. Say so plainly rather than showing a stack trace.
      throw ApiException(
        error: 'network_unreachable',
        message: 'Cannot reach the server. Is it running, and bound to 0.0.0.0?',
      );
    } on HttpException {
      throw ApiException(
        error: 'network_error',
        message: 'The connection failed. Please try again.',
      );
    } catch (e) {
      throw ApiException(
        error: 'network_error',
        message: 'Network problem: $e',
      );
    }

    Map<String, dynamic> decoded;
    try {
      final raw = jsonDecode(response.body);
      decoded = raw is Map<String, dynamic> ? raw : <String, dynamic>{};
    } on FormatException {
      // Non-JSON where JSON was promised: almost always an HTML error page
      // from the web server rather than the application.
      throw ApiException(
        error: 'bad_response',
        message: 'The server returned something that was not JSON (HTTP ${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }

    if (decoded['ok'] == true) return decoded;

    throw ApiException(
      error: (decoded['error'] as String?) ?? 'server_error',
      message: (decoded['message'] as String?) ?? '',
      statusCode: response.statusCode,
      fieldErrors: _parseFieldErrors(decoded['errors']),
    );
  }

  Map<String, List<String>> _parseFieldErrors(Object? raw) {
    if (raw is! Map) return const {};
    return raw.map(
      (key, value) => MapEntry(
        '$key',
        value is List ? value.map((e) => '$e').toList() : <String>['$value'],
      ),
    );
  }

  void close() => _http.close();
}

/// What the server calls the platform this build is running on.
///
/// One definition, because two endpoints send it — the app gate reads it to
/// pick a store link, and a crash report carries it — and two copies would
/// eventually disagree about the spelling of a value the server matches on
/// exactly. Null on anything else: a desktop build has no store and no store
/// column, and the server answers such a request as though no platform were
/// sent, which is the honest outcome.
String? apiPlatformName() => switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      _ => null,
    };
