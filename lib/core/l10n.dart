import 'package:flutter/widgets.dart';

import '../l10n/generated/app_localizations.dart';
import 'api_client.dart';

/// So that importing this one file is enough. `lookupAppLocalizations` is how
/// anything without a widget tree — a test, most of all — gets a set of
/// strings to work with.
export '../l10n/generated/app_localizations.dart'
    show AppLocalizations, lookupAppLocalizations;

/// `context.t.somethingOrOther` — the app's strings, one getter away from any
/// widget. A shorthand rather than a wrapper: it returns the generated class
/// untouched, so nothing here has to be kept in step with the ARB files.
extension L10nContext on BuildContext {
  AppLocalizations get t => AppLocalizations.of(this);
}

/// What to actually put in front of a person when a request fails.
///
/// **The four codes the client raises itself are translated here; everything
/// else is the server's own text and is shown as it arrived.** That split is
/// the whole rule. `ApiClient` builds its messages with no locale and no
/// context — one of them names 0.0.0.0, which is a line for a log rather than
/// for somebody standing in a stairwell — so its prose stays a developer
/// fallback, and this is what a screen shows.
///
/// The server's half is untranslated for now: the app sends `Accept-Language`
/// with every request (see `ApiClient.acceptLanguage`), so the day the API
/// starts answering in Spanish this method needs no change at all.
extension ApiErrorText on ApiException {
  /// True when the signed-in account has no employee record, and so no
  /// attendance, leave, schedule, documents or colleagues either.
  ///
  /// `forbidden` is raised in exactly one place on this API — the resolver
  /// every employee-facing endpoint goes through — so on those endpoints it
  /// means this and nothing else.
  ///
  /// **Worth knowing because it is the one failure no retry can clear.** An HR
  /// or administrator account that was never linked to an employee saw the
  /// ordinary error card on four tabs, each offering "Try again" for a
  /// condition that will still be true on the hundredth press. The Profile tab
  /// already says the true thing — that this account belongs on the web
  /// dashboard — and the others now stop pretending the server is having a
  /// moment.
  bool get isMissingEmployeeRecord => error == 'forbidden';

  String text(AppLocalizations t) {
    if (isNetworkFailure) return t.errorNoConnection;
    if (isRateLimited) return t.errorTooManyAttempts;

    switch (error) {
      case 'bad_response':
        return t.errorBadResponse;
      case 'download_failed':
        return t.errorDownloadFailed;
    }

    // Validation failures carry a generic top line and the useful text in the
    // field detail, so prefer that when there is exactly one field wrong.
    final server = displayMessage;

    // A failure the server did not put words to. It has no untranslated text
    // to prefer, which is why ApiClient no longer invents any.
    return server.isEmpty ? t.errorGeneric : server;
  }
}
