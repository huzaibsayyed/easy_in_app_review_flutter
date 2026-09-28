# easy_in_app_review

[![pub package](https://img.shields.io/pub/v/easy_in_app_review.svg)](https://pub.dev/packages/easy_admob_ads_flutter)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)

A Flutter package that wraps [`in_app_review`](https://pub.dev/packages/in_app_review) with the bookkeeping Apple and Google expect apps to do themselves before showing a native review prompt: only asking when the platform says it's possible, not nagging a user who was just asked, and capping how often you try per year.

## Features

* Triggers the native App Store / Google Play / Microsoft Store review prompt
* Checks for network connectivity before asking
* Enforces a minimum time since install before the first ask
* Enforces a cooldown between asks
* Enforces a yearly request limit (defaults to Apple's own cap of 3)
* Persists request/confirmation state across app launches via `shared_preferences`
* Structured logging of every eligibility decision via `package:logging`
* Optional, ready-made "Rate us?" and "Did you rate us?" dialogs
* A manual store-listing fallback for a "Rate us" button

## Getting started

Add the package:

```sh
flutter pub add easy_in_app_review
```

### iOS / macOS

Set `appStoreId` in [`AppReview.init`](#setup) — it's your app's numeric App Store Connect ID, found under **General > App Information > Apple ID**. It's required for [`openStoreListing`](#rate-us-button) to work, and not needed just to call `requestReview` / `maybeRequestReview`.

### Android

No configuration needed. Note that the native review prompt can't be exercised through a local/sideloaded debug install — only through a Play testing track — so this package automatically skips the eligibility check on Android debug builds.

### Windows

Pass `microsoftStoreId` to `AppReview.init` if you want `openStoreListing` to work on Windows.

## Usage

### Setup

Call `AppReview.init` once, as early as possible — ideally the first line of `main()`:

```dart
import 'package:easy_in_app_review/easy_in_app_review.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  AppReview.init(
    appStoreId: '123456789',          // required on iOS/macOS
    microsoftStoreId: '9NBLGGH4R315', // optional, Windows only
  );

  runApp(const MyApp());
}
```

### Request a review

Call this from a "happy path" moment in your app — e.g. right after the user completes checkout, finishes a level, or exports a file. Don't call it right after launch or right after an error:

```dart
await AppReview.maybeRequestReview();
```

The native prompt is only requested when all eligibility checks pass: network is available, the platform reports the review API is available, enough time has passed since install, the cooldown has elapsed, and the yearly cap hasn't been reached.

### Rate us button

Use `openStoreListing` for an explicit, user-initiated "Rate us" button in a settings screen. Unlike `maybeRequestReview`, this isn't gated by eligibility checks and always navigates the user off-app:

```dart
ElevatedButton(
  onPressed: AppReview.openStoreListing,
  child: const Text('Rate this app'),
)
```

### Status

Inspect everything the package has recorded — handy for a debug screen or your own confirmation UI:

```dart
final status = await AppReview.status();

print(status.requestCount);
print(status.hasRequested);
print(status.hasConfirmed);
print(status.lastRequestedAt);
```

### Optional dialogs

Ready-made, themeable dialogs built on top of `AppReview`:

```dart
// A lightweight "enjoying the app?" gate before spending one of the
// platform's limited yearly prompts on a user who's about to say no.
final triggered = await context.showRatePromptDialog();

// A follow-up asking whether the user actually went through with rating.
await context.showReviewConfirmationDialog();
```

Both are plain `extension` methods on `BuildContext` defined in [`app_review_dialogs.dart`](lib/src/app_review_dialogs.dart) — copy that file into your project and adjust the copy or styling freely.

To show the confirmation dialog after the user returns to your home page (e.g. after being sent to the store from `showRatePromptDialog`), trigger it from a post-frame callback in `initState`:

```dart
@override
void initState() {
  super.initState();

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) context.showReviewConfirmationDialog();
  });
}
```

The post-frame callback ensures the dialog is scheduled only after the first frame is built, and the delay gives the page time to settle before prompting.

### Logging

Decisions are logged through `package:logging` under the logger name `'AppReview'`. To see the full trace of why a prompt was or wasn't shown:

```dart
Logger.root.level = Level.FINE;
Logger.root.onRecord.listen((record) {
  debugPrint('${record.level.name} ${record.loggerName}: ${record.message}');
});
```

### Testing

Reset all stored review state during development. Gate any UI that calls this behind `kDebugMode` or a debug menu:

```dart
await AppReview.resetForTesting();
```

> The native review prompt is controlled entirely by iOS/Android — calling this package's API does not guarantee a review dialog will actually be displayed, and the OS never confirms whether it was.

## Example

A runnable example app is available in [`example/`](example), demonstrating setup, requesting a review, the optional dialogs, and the status/reset helpers.

## Additional information

Issues and pull requests are welcome on [GitHub](https://github.com/huzaibsayyed/easy_in_app_review/issues).
