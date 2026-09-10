import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/l10n.dart';
import '../main.dart';

/// Asks the server to email a reset link.
///
/// The app's whole part in the flow. The link opens the web reset page rather
/// than deep-linking back here: a token entry screen would be a second
/// implementation of something the web already does, and the reset has to work
/// from a borrowed laptop anyway — the handset is often the thing the person
/// has lost access to.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail});

  /// Carried over from the login form, so somebody who typed their address and
  /// then remembered they cannot recall the password does not type it twice.
  final String? initialEmail;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _email =
      TextEditingController(text: widget.initialEmail ?? '');

  bool _busy = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;

    setState(() => _busy = true);

    // Before the await: the catch needs the strings and cannot reach for a
    // context on the far side of one.
    final t = context.t;

    try {
      await SessionScope.read(context).api.post(
        '/auth/forgot-password',
        body: {'email': _email.text.trim()},
      );

      if (!mounted) return;
      // Deliberately shown whether or not that address has an account. The
      // server answers the same way for both, and a screen that said "no such
      // user" would undo the reason it does.
      setState(() => _sent = true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.text(t);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(context.t.forgotTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _sent ? _confirmation(theme, context.t) : _form(theme, context.t),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form(ThemeData theme, AppLocalizations t) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            Icons.lock_reset,
            size: 52,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 20),
          Text(
            t.forgotHeading,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            t.forgotBlurb,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 28),

          if (_error != null) ...[
            _Banner(
              message: _error!,
              color: theme.colorScheme.error,
              icon: Icons.error_outline,
            ),
            const SizedBox(height: 16),
          ],

          TextFormField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofocus: true,
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _busy ? null : _submit(),
            decoration: InputDecoration(
              labelText: t.loginEmail,
              prefixIcon: const Icon(Icons.mail_outline),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? t.loginEnterEmail : null,
          ),
          const SizedBox(height: 24),

          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : Text(t.forgotSubmit),
          ),
        ],
      ),
    );
  }

  Widget _confirmation(ThemeData theme, AppLocalizations t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          Icons.mark_email_read_outlined,
          size: 52,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 20),
        Text(
          t.forgotSentTitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Text(
          t.forgotSentBlurb,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Text(
          t.forgotSentWarning,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 28),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.forgotBackToSignIn),
        ),
        const SizedBox(height: 8),
        TextButton(
          // Nothing was confirmed to have been sent, so a mistyped address
          // fails silently by design. This is the way back from that.
          onPressed: () => setState(() => _sent = false),
          child: Text(t.forgotDifferentEmail),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.message,
    required this.color,
    required this.icon,
  });

  final String message;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: TextStyle(color: color, fontSize: 14)),
          ),
        ],
      ),
    );
  }
}
