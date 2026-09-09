import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../main.dart';
import '../widgets/async_view.dart';

/// Who else works here (B3.8).
///
/// The only screen in the app about other people, and so the plainest: a name,
/// a job title, where they are based, and — only where the company has switched
/// it on — a way to contact them.
///
/// Contact details are a company policy that is **off by default**. There is a
/// single phone column on an employee record, and for a workforce with no desk
/// lines it holds personal mobiles.
class DirectoryScreen extends StatefulWidget {
  const DirectoryScreen({super.key});

  @override
  State<DirectoryScreen> createState() => _DirectoryScreenState();
}

class _DirectoryScreenState extends State<DirectoryScreen> {
  final _search = TextEditingController();

  Directory? _directory;
  bool _loading = true;
  String? _error;

  /// Debounces the search so a five-letter name is one request, not five.
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final term = _search.text.trim();

      final res = await SessionScope.read(context).api.get(
            '/directory',
            query: {if (term.isNotEmpty) 'q': term},
          );

      if (!mounted) return;
      setState(() {
        _directory = Directory.fromJson(res);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.error == 'forbidden'
            ? 'This account has no employee record, so the directory is unavailable.'
            : e.displayMessage;
        _loading = false;
      });
    }
  }

  Future<void> _launch(String scheme, String value) async {
    final uri = Uri(scheme: scheme, path: value);

    if (!await launchUrl(uri) && mounted) {
      // No mail client, or no dialler on a tablet. Say what could not be
      // opened rather than letting the tap look ignored.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nothing on this device opens $value.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final directory = _directory;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Colleagues'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(62),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _search,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                hintText: 'Search by name or code',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _search.clear();
                          _load();
                        },
                      ),
              ),
            ),
          ),
        ),
      ),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        child: directory == null || directory.people.isEmpty
            ? EmptyState(
                icon: Icons.people_outline,
                title: _search.text.isEmpty ? 'Nobody to show' : 'No match',
                subtitle: _search.text.isEmpty
                    ? 'Colleagues appear here once HR has added them.'
                    : 'Nobody here matches "${_search.text.trim()}".',
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                  itemCount: directory.people.length +
                      // One trailing note when the list is longer than a page.
                      (directory.hasMore ? 1 : 0),
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    if (i >= directory.people.length) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          'More colleagues than fit on one page — search to narrow it.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12.5),
                        ),
                      );
                    }

                    return _PersonCard(
                      person: directory.people[i],
                      showsContact: directory.showsContactDetails,
                      onEmail: (v) => _launch('mailto', v),
                      onCall: (v) => _launch('tel', v),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({
    required this.person,
    required this.showsContact,
    required this.onEmail,
    required this.onCall,
  });

  final DirectoryPerson person;
  final bool showsContact;
  final ValueChanged<String> onEmail;
  final ValueChanged<String> onCall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final where = [
      if (person.designation != null) person.designation!,
      if (person.department != null) person.department!,
    ].join(' · ');

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: AppTheme.brand.withValues(alpha: 0.15),
              // A photo when there is one, initials when there is not — the
              // grey silhouette repeated down a list reads worse than either.
              backgroundImage:
                  person.photoUrl != null ? NetworkImage(person.photoUrl!) : null,
              child: person.photoUrl != null
                  ? null
                  : Text(
                      person.initials,
                      style: const TextStyle(
                        color: AppTheme.brandDeep,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    person.fullName,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  if (where.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      where,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (person.office != null) person.office!,
                      if (person.workMode == 'wfh') 'Remote',
                      if (person.workMode == 'hybrid') 'Hybrid',
                    ].join(' · '),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            // Drawn only when the company shares contact details *and* this
            // person has some. A button that cannot do anything is worse than
            // no button.
            if (showsContact) ...[
              if (person.phone != null)
                IconButton(
                  icon: const Icon(Icons.phone_outlined, size: 21),
                  tooltip: 'Call',
                  onPressed: () => onCall(person.phone!),
                ),
              if (person.email != null)
                IconButton(
                  icon: const Icon(Icons.mail_outline, size: 21),
                  tooltip: 'Email',
                  onPressed: () => onEmail(person.email!),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
