import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';

/// The employee's own file (B3.7).
///
/// Pushed from the Profile tab rather than given a tab of its own: this is
/// looked at when a visa is expiring or somebody asks for a contract, not every
/// day, and the bottom bar is already at six for a manager.
///
/// Read-only. Filing is HR's job behind `manage-employees`, and the API offers
/// no upload — so this screen has no add button to explain the absence of.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  List<EmployeeDocument> _documents = const [];
  int _expiringSoon = 0;
  int _expired = 0;

  bool _loading = true;
  String? _error;

  /// The document currently downloading, so one row spins rather than the
  /// whole list going dead.
  int? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final res = await SessionScope.read(context).api.get('/documents');
      if (!mounted) return;

      setState(() {
        _documents = ((res['documents'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(EmployeeDocument.fromJson)
            .toList();
        _expiringSoon = _toCount(res['expiring_soon']);
        _expired = _toCount(res['expired']);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.error == 'forbidden'
            ? 'This account has no employee record, so there is nothing on file.'
            : e.displayMessage;
        _loading = false;
      });
    }
  }

  static int _toCount(Object? v) => v is num ? v.toInt() : 0;

  /// Fetch the file and hand it to whatever the phone opens that type with.
  ///
  /// Written to the temporary directory, not to Documents: these are contracts
  /// and passport scans, and leaving copies in a folder every other app can
  /// browse would undo the point of streaming them through an authenticated
  /// endpoint in the first place. The OS clears this directory on its own.
  Future<void> _open(EmployeeDocument document) async {
    if (_busyId != null) return;
    setState(() => _busyId = document.id);

    try {
      final file = await SessionScope.read(context).api.getFile('/documents/${document.id}');

      final dir = await getTemporaryDirectory();
      // The server's name, falling back to the one on the record. Sanitised
      // because it reaches a filesystem path, and it was typed by a person.
      final name = _safeName(file.filename ?? document.originalName, document.id);
      final path = '${dir.path}${Platform.pathSeparator}$name';

      await File(path).writeAsBytes(file.bytes, flush: true);

      final result = await OpenFilex.open(path);

      if (!mounted) return;

      if (result.type != ResultType.done) {
        // Most often no app installed for the type — a .docx on a bare
        // handset. Say that rather than leaving the tap looking ignored.
        _say(
          'Downloaded, but nothing on this phone opens ${document.originalName}.',
          AppTheme.late,
        );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      _say(
        e.error == 'file_missing'
            ? 'That document is no longer on file. Contact HR.'
            : e.displayMessage,
        Theme.of(context).colorScheme.error,
      );
    } on FileSystemException {
      if (!mounted) return;
      _say('There was no room to save the file.', Theme.of(context).colorScheme.error);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// A filename safe to put on a path, and never empty.
  static String _safeName(String raw, int id) {
    final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

    return cleaned.isEmpty || cleaned == '.' ? 'document-$id' : cleaned;
  }

  void _say(String message, Color colour) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), backgroundColor: colour),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My documents'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        child: _documents.isEmpty
            ? const EmptyState(
                icon: Icons.folder_open_outlined,
                title: 'Nothing on file yet',
                subtitle: 'Contracts, ID and certificates HR files against your '
                    'record appear here.',
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    // Counted by the server so this banner and the rows below
                    // cannot disagree about what needs renewing.
                    if (_expired > 0 || _expiringSoon > 0) ...[
                      _ExpiryBanner(expired: _expired, expiringSoon: _expiringSoon),
                      const SizedBox(height: 16),
                    ],
                    for (final document in _documents)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _DocumentTile(
                          document: document,
                          busy: _busyId == document.id,
                          onTap: () => _open(document),
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _ExpiryBanner extends StatelessWidget {
  const _ExpiryBanner({required this.expired, required this.expiringSoon});

  final int expired;
  final int expiringSoon;

  @override
  Widget build(BuildContext context) {
    final urgent = expired > 0;
    final colour = urgent ? AppTheme.absent : AppTheme.late;

    final parts = <String>[
      if (expired > 0) '$expired expired',
      if (expiringSoon > 0) '$expiringSoon expiring within 30 days',
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colour.withValues(alpha: 0.32)),
      ),
      child: Row(
        children: [
          Icon(urgent ? Icons.error_outline : Icons.schedule, color: colour, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              // HR is chased about these too, so this is a heads-up rather than
              // a demand — the employee usually cannot renew anything alone.
              '${parts.join(' · ')}. HR has been notified.',
              style: TextStyle(color: colour, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _DocumentTile extends StatelessWidget {
  const _DocumentTile({
    required this.document,
    required this.busy,
    required this.onTap,
  });

  final EmployeeDocument document;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (badge, badgeColour) = switch (document.expiryState) {
      'expired' => ('Expired', AppTheme.absent),
      'soon' => ('Expires soon', AppTheme.late),
      _ => (null, AppTheme.neutral),
    };

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Icon(_iconFor(document.mimeType), size: 30, color: AppTheme.brandDeep),
        title: Text(
          document.title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 3),
            Text(
              '${document.typeLabel} · ${document.sizeLabel}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (document.expiresOn != null) ...[
              const SizedBox(height: 4),
              Text(
                'Expires ${Fmt.shortDate(document.expiresOn!)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: badge == null ? theme.colorScheme.outline : badgeColour,
                  fontWeight: badge == null ? FontWeight.w400 : FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
        trailing: busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            : const Icon(Icons.download_outlined),
        onTap: busy ? null : onTap,
      ),
    );
  }

  static IconData _iconFor(String? mime) => switch (mime) {
        'application/pdf' => Icons.picture_as_pdf_outlined,
        final String m when m.startsWith('image/') => Icons.image_outlined,
        final String m when m.contains('word') => Icons.description_outlined,
        final String m when m.contains('sheet') || m.contains('excel') =>
          Icons.table_chart_outlined,
        _ => Icons.insert_drive_file_outlined,
      };
}
