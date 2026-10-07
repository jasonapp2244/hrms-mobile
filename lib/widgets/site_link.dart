import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api_client.dart';
import '../core/l10n.dart';

/// Opens one of the server's public pages — the privacy policy, the account
/// deletion page — in the browser.
///
/// Shared by the login screen and Profile so both point at the same address:
/// the host comes from the API base URL, so a build pointed at staging shows
/// staging's policy rather than silently linking to production.
class SiteLink {
  SiteLink._();

  /// Replaced in tests, where no browser exists to open.
  @visibleForTesting
  static Future<bool> Function(Uri url) launcher =
      (url) => launchUrl(url, mode: LaunchMode.externalApplication);

  static Future<void> open(BuildContext context, String path) async {
    final url = Uri.parse('${ApiClient.siteUrl}$path');

    // Outside the app rather than in a web view: a policy shown in a frame the
    // app controls is worth less than one the person can see the address of.
    final opened = await launcher(url);

    if (!opened && context.mounted) {
      // Failing silently would look identical to a page that opened behind the
      // app, so say what could not be reached and where it lives.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.t.profileCouldNotOpen('$url'))),
      );
    }
  }
}
