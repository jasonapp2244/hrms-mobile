import 'dart:convert';
import 'dart:io';

import 'package:attendance/core/api_client.dart';
import 'package:attendance/core/locale.dart';
// `show`, because models.dart exports a Directory of its own — an office
// location — and importing it whole shadows dart:io's for the whole file.
import 'package:attendance/core/models.dart' show LeaveRequest;
import 'package:attendance/core/offline_cache.dart';
import 'package:attendance/core/session.dart';
import 'package:attendance/core/theme.dart';
import 'package:attendance/l10n/generated/app_localizations.dart';
import 'package:attendance/main.dart';
import 'package:attendance/screens/leave_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/settle.dart';

/// Attaching a file to a leave request (B4.1).
///
/// `leave_requests.attachment` had existed since the table was created and
/// nothing had ever written to it. What is tested here is the wire: the request
/// has to leave the handset as **multipart**, with the ordinary fields beside
/// the file, because `Request::boolean()` and `validate()` on the server read
/// form fields and the file arrives as a part rather than as base64 in a JSON
/// body.
///
/// The picker itself is a platform dialog and is not driven here — what it
/// hands back is a path, and this exercises everything from that path onwards.
void main() {
  late Directory dir;
  late List<http.BaseRequest> sent;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('leave_attachment_test');
    FlutterSecureStorage.setMockInitialValues({});
    sent = <http.BaseRequest>[];
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // The cache writes without the test awaiting it, so on Windows the file
      // can still be held open when the test ends. Harness tidying.
    }
  });

  Session recordingSession() {
    final calls = sent;

    final api = ApiClient(
      client: MockClient((request) async {
        calls.add(request);

        if (request.url.path.endsWith('/leave/requests') && request.method == 'POST') {
          return http.Response(
            jsonEncode({
              'ok': true,
              'request': {
                'id': 7,
                'leave_type': 'Annual Leave',
                'start_date': '2026-08-10',
                'end_date': '2026-08-12',
                'days': 3,
                'status': 'pending',
                'stage': 'Awaiting Manager',
                'can_cancel': true,
                'has_attachment': true,
                'attachment_name': 'sick-note.pdf',
              },
              'message': 'Submitted.',
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }

        return http.Response(
          jsonEncode({'ok': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    return Session(api: api, cache: OfflineCache(directory: dir));
  }

  test('a leave request leaves the handset as multipart, file and all', () async {
    final session = recordingSession();
    final note = File('${dir.path}${Platform.pathSeparator}sick-note.pdf');
    await note.writeAsString('not really a pdf');

    await session.api.postMultipart(
      '/leave/requests',
      fields: {
        'leave_type_id': '1',
        'start_date': '2026-08-10',
        'end_date': '2026-08-12',
        'is_half_day': '1',
        'reason': 'Flu',
      },
      filePath: note.path,
    );

    // The handler receives the request already finalised, which is the right
    // thing to assert on: this is the bytes the server will parse, not the
    // builder that produced them.
    final request = sent.single as http.Request;
    final body = request.body;

    // MultipartRequest writes its own Content-Type with the boundary in it.
    // Setting one by hand produces a request no server can parse, so the client
    // deliberately does not.
    expect(request.headers['content-type'], startsWith('multipart/form-data;'));
    expect(request.headers['content-type'], contains('boundary='));

    // Every field crosses as a form field — which is what the server's
    // `validate()` and `boolean()` read. A JSON body would reach neither.
    expect(body, contains('name="leave_type_id"'));
    expect(body, contains('name="is_half_day"'));
    expect(body, contains('name="reason"'));
    expect(body, contains('Flu'));

    // The file is a part named for the field the controller validates, and it
    // keeps the name it had on disk — that name is what the approver sees.
    expect(body, contains('name="attachment"; filename="sick-note.pdf"'));
    expect(body, contains('not really a pdf'));
  });

  test('with nothing attached it is still a form post, with no file part',
      () async {
    final session = recordingSession();

    await session.api.postMultipart(
      '/leave/requests',
      fields: {
        'leave_type_id': '1',
        'start_date': '2026-08-10',
        'end_date': '2026-08-12',
      },
    );

    final request = sent.single as http.Request;

    // One code path whether or not a file is attached, rather than two that
    // have to stay in step.
    expect(request.headers['content-type'], startsWith('multipart/form-data;'));
    expect(request.body, contains('name="start_date"'));
    expect(request.body, isNot(contains('filename=')));
  });

  testWidgets('a request that carries a file says so on the card',
      (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    final api = ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/leave/balances')) {
          return http.Response(
            jsonEncode({'ok': true, 'year': 2026, 'today': '2026-08-03', 'balances': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        return http.Response(
          jsonEncode({
            'ok': true,
            'requests': [
              {
                'id': 7,
                'leave_type': 'Annual Leave',
                'start_date': '2026-08-10',
                'end_date': '2026-08-12',
                'days': 3,
                'status': 'pending',
                'stage': 'Awaiting Manager',
                'can_cancel': true,
                'has_attachment': true,
                'attachment_name': 'sick-note.pdf',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocale.supported,
      home: SessionScope(
        notifier: Session(api: api, cache: OfflineCache(directory: dir)),
        child: LeaveScreen(visible: ValueNotifier(true)),
      ),
    ));
    await settle(tester);

    // The name, not the word "attachment": it is how the person who uploaded it
    // knows the right file went up.
    expect(find.text('sick-note.pdf'), findsOneWidget);
  });

  test('a file the server says is gone is not drawn as an attachment', () {
    // `has_attachment` is computed from the disk, so a row whose file has been
    // lost still carries the name it was uploaded under. A paperclip pointing
    // at nothing is worse than no paperclip.
    final request = LeaveRequest.fromJson(const {
      'id': 7,
      'leave_type': 'Annual Leave',
      'start_date': '2026-08-10',
      'end_date': '2026-08-12',
      'days': 3,
      'status': 'pending',
      'stage': 'Awaiting Manager',
      'can_cancel': true,
      'has_attachment': false,
      'attachment_name': 'sick-note.pdf',
    });

    expect(request.attachmentName, isNull);
  });
}
