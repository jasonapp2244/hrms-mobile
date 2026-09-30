import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../core/l10n.dart';

/// What an office screen's code starts with (A4.21). Anything else is refused
/// on the handset rather than sent, so a stray QR on a poster costs nothing.
const officeQrPrefix = 'KEMP1:';

/// What the welcome email's one-time sign-in code starts with.
const activationQrPrefix = 'KEMP1-ACT:';

/// The camera, pointed at one kind of KEMP code, returning its text (A4.21).
///
/// **ZXing, decoded on the handset, and nothing else.** The usual Flutter
/// scanner uses Google's ML Kit on Android, which reports usage to Google —
/// a third host, and trap 13 is that the privacy documents promise two. The
/// camera frames never leave the phone.
///
/// No gallery button and no camera switch: the code proves the person is
/// standing at the office screen, and a picture from the gallery proves they
/// once were. The server refuses an old code anyway; there is no reason to
/// offer the route.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key, required this.title, required this.prefix});

  final String title;

  /// The one kind of code this scan will accept.
  final String prefix;

  /// Opens the scanner and resolves to the scanned text, or null when the
  /// person backed out.
  ///
  /// Replaceable in tests, which have no camera: a widget test sets this to
  /// return a code, and everything after the scan runs for real. Nothing
  /// else assigns it.
  static Future<String?> Function(BuildContext context, {required String title, required String prefix}) open =
      _push;

  static Future<String?> _push(BuildContext context, {required String title, required String prefix}) =>
      Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => QrScanScreen(title: title, prefix: prefix)),
      );

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  /// Set on the first good read. The camera goes on producing frames until
  /// the route is gone, and a second pop would close the screen behind it.
  bool _done = false;

  /// Shown when the camera read a QR that is not the kind asked for.
  bool _wrongCode = false;

  /// The camera could not start — usually permission refused.
  bool _cameraFailed = false;

  void _onScan(Code code) {
    if (_done || !code.isValid) return;

    final text = code.text?.trim() ?? '';
    if (!text.startsWith(widget.prefix)) {
      if (!_wrongCode) setState(() => _wrongCode = true);
      return;
    }

    _done = true;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      backgroundColor: Colors.black,
      body: _cameraFailed
          ? _CameraUnavailable(message: t.scanCameraUnavailable)
          : Stack(
              children: [
                Positioned.fill(
                  child: ReaderWidget(
                    onScan: _onScan,
                    codeFormat: Format.qrCode,
                    tryHarder: true,
                    showGallery: false,
                    showToggleCamera: false,
                    cropPercent: 0.7,
                    scanDelay: const Duration(milliseconds: 250),
                    onControllerCreated: (_, error) {
                      if (error != null && mounted) setState(() => _cameraFailed = true);
                    },
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 96,
                  child: _Hint(
                    text: _wrongCode
                        ? t.scanWrongCode
                        : widget.prefix == officeQrPrefix
                            ? t.scanPointAtOffice
                            : t.scanPointAtEmail,
                    warning: _wrongCode,
                  ),
                ),
              ],
            ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text, required this.warning});

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: warning ? Colors.orange.shade800 : Colors.black87,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.3),
        ),
      ),
    );
  }
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, color: Colors.white70, size: 56),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
