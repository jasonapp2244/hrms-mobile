import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';

/// What happened to a file the app fetched and tried to open.
enum OpenedFile {
  /// Handed to an app that could show it.
  opened,

  /// Downloaded, but nothing on this handset opens that type — a `.docx` on a
  /// bare phone. Worth saying, because the tap otherwise looks ignored.
  noOpener,
}

/// Fetch a file from the API, put it somewhere the OS can reach, and open it.
///
/// **Saved to the temporary directory, not Documents.** These are passport
/// scans and sick notes: leaving copies where every other app can browse them
/// would undo the point of having served them from an authenticated endpoint.
/// The OS reclaims the space on its own schedule.
///
/// The name comes from the server's `Content-Disposition` when it sent one and
/// from [fallbackName] otherwise, and either way it is **sanitised**, because
/// it reaches a filesystem path and it was typed by a person.
///
/// Errors are left to the caller: `ApiException` for the fetch and
/// `FileSystemException` for a full disk both mean different things on the two
/// screens that call this, and a helper that swallowed them would have to
/// invent a message that fits neither.
Future<OpenedFile> downloadAndOpen(
  ApiClient api,
  String path, {
  required String fallbackName,
  required int id,
}) async {
  final file = await api.getFile(path);

  final dir = await getTemporaryDirectory();
  final name = safeFileName(file.filename ?? fallbackName, id);
  final target = '${dir.path}${Platform.pathSeparator}$name';

  await File(target).writeAsBytes(file.bytes, flush: true);

  final result = await OpenFilex.open(target);

  return result.type == ResultType.done ? OpenedFile.opened : OpenedFile.noOpener;
}

/// A filename safe to put on a path, and never empty.
String safeFileName(String raw, int id) {
  final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  // A bare dot survives the filter and is not a filename.
  return cleaned.isEmpty || cleaned == '.' ? 'file-$id' : cleaned;
}
