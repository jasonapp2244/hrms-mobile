import 'package:flutter/material.dart';

/// The padding the content of a modal bottom sheet needs.
///
/// **`useSafeArea: true` does not cover the bottom, and that is not an
/// oversight in Flutter — it is the whole reason this exists.**
/// `showModalBottomSheet` wraps the sheet in `SafeArea(bottom: false)`, leaving
/// the bottom to the caller because a sheet usually has a keyboard under it.
/// Every sheet in this app then padded by `viewInsets.bottom` alone, which is
/// the keyboard and nothing else — so with the keyboard **down**, the last
/// thing in the sheet was drawn underneath the navigation bar.
///
/// On a handset with three-button navigation that is about 48dp of opaque
/// black over the end of the sheet, and the end of a sheet is where the submit
/// button lives: **the Save on "Home & emergency contact" was half-covered and
/// the sheet had nothing left to scroll**, so the only way to reach it was to
/// aim at the top half of a button the user could not fully see.
///
/// `padding.bottom` is the right term rather than `viewPadding.bottom`: it is
/// already the system inset **minus** whatever `viewInsets` covers, so it is
/// the navigation bar when the keyboard is down and zero when the keyboard is
/// up and covering it. Adding both terms is therefore correct in both states
/// and double-counts in neither.
EdgeInsets sheetPadding(BuildContext context, {double horizontal = 20}) {
  final media = MediaQuery.of(context);

  return EdgeInsets.only(
    left: horizontal,
    right: horizontal,
    top: 20,
    bottom: media.viewInsets.bottom + media.padding.bottom + 20,
  );
}
