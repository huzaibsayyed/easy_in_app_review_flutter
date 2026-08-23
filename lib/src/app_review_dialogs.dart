import 'package:flutter/material.dart';

import 'app_review.dart';

/// Optional, themeable dialog helpers built on top of [AppReview].
///
/// Kept separate from [AppReview] on purpose — business logic (should we
/// ask? did we ask?) shouldn't be coupled to one specific dialog's copy
/// or styling. Copy this file into your project and adjust freely;
/// nothing here talks to native review APIs except through [AppReview].
extension AppReviewDialogs on BuildContext {
  /// Shows a lightweight "enjoying the app?" gate before triggering the
  /// native review prompt, so you don't spend one of Apple's 3
  /// prompts-per-year on a user who's about to say no anyway.
  ///
  /// Returns `true` if the native review sheet ended up being triggered.
  Future<bool> showRatePromptDialog({String title = 'Enjoying the app?', String message = 'Would you like to rate us?', String positiveLabel = 'Sure!', String negativeLabel = 'Not right now'}) async {
    final confirmed = await showDialog<bool>(
      context: this,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(negativeLabel)),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(positiveLabel)),
        ],
      ),
    );

    if (confirmed == true) {
      return AppReview.maybeRequestReview();
    }
    return false;
  }

  /// A follow-up dialog you can show a little while after
  /// [AppReview.requestReview] fired, asking whether the user actually
  /// went through with rating. Purely informational — wire the result
  /// into [AppReview.confirmReview] and your own analytics if useful.
  Future<void> showReviewConfirmationDialog({String title = 'Have you rated us?', String message = 'If not, you can still rate us on the store.'}) async {
    final status = await AppReview.status();
    if (!status.hasRequested || status.hasConfirmed) return;
    if (!mounted) return;

    final result = await showDialog<bool>(
      context: this,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () async {
              await AppReview.openStoreListing();
              if (dialogContext.mounted) Navigator.pop(dialogContext, false);
            },
            child: const Text('Open Store Listing'),
          ),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Yes, I rated it')),
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Maybe later')),
        ],
      ),
    );

    if (result == true) {
      await AppReview.confirmReview();
    }
  }
}
