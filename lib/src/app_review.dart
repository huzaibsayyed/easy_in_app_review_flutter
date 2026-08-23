import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Snapshot of everything [AppReview] has recorded, returned by
/// [AppReview.status].
@immutable
class AppReviewStatus {
  const AppReviewStatus({required this.hasRequested, required this.hasConfirmed, required this.requestCount, required this.lastRequestedAt});

  final bool hasRequested;
  final bool hasConfirmed;
  final int requestCount;
  final DateTime? lastRequestedAt;

  @override
  String toString() =>
      'AppReviewStatus(hasRequested: $hasRequested, hasConfirmed: $hasConfirmed, '
      'requestCount: $requestCount, lastRequestedAt: $lastRequestedAt)';
}

/// A drop-in wrapper around `in_app_review` that adds the bookkeeping
/// Apple/Google expect apps to do themselves before showing a review
/// prompt: only asking when the platform says it can, not nagging users
/// who were just asked, and capping how often it tries per year.
///
/// Logs through `package:logging` under the logger name `'AppReview'`.
/// To see the full decision trace (why a prompt was or wasn't shown),
/// lower `Logger.root.level` to `Level.FINE` or below during debugging;
/// leave it at `Level.INFO`/`Level.WARNING` in normal development so only
/// meaningful events and real problems show up.
///
/// ## Setup
/// ```dart
/// void main() {
///   WidgetsFlutterBinding.ensureInitialized();
///   AppReview.init(
///     appStoreId: '123456789',          // required on iOS/macOS
///     microsoftStoreId: '9NBLGGH4R315', // optional, Windows only
///   );
///   AppReview.recordAppLaunch(); // call once, as early as possible
///   runApp(const MyApp());
/// }
/// ```
///
/// ## Usage
/// ```dart
/// // After a "happy path" moment, e.g. the user just completed checkout:
/// await AppReview.maybeRequestReview();
///
/// // A manual "Rate us" button in Settings:
/// ElevatedButton(
///   onPressed: AppReview.openStoreListing,
///   child: const Text('Rate this app'),
/// )
/// ```
class AppReview {
  AppReview._();

  static final Logger _log = Logger('AppReview');
  static final InAppReview _inAppReview = InAppReview.instance;

  static const _keyRequestCount = 'app_review.request_count';
  static const _keyLastRequestedAt = 'app_review.last_requested_at';
  static const _keyConfirmed = 'app_review.confirmed';
  static const _keyFirstLaunchAt = 'app_review.first_launch_at';

  static String? _appStoreId;
  static String _microsoftStoreId = '';
  static Duration _minTimeSinceInstall = const Duration(seconds: 10);
  static int _minRequestCooldownDays = 90;
  static int _maxRequestsPerYear = 3; // mirrors Apple's own cap
  static void Function(Object error, StackTrace stackTrace)? _onError;
  static bool _initialized = false;

  /// Configures the wrapper. Call once, before any other method — ideally
  /// the first line of `main()`.
  ///
  /// [appStoreId] is your app's numeric App Store Connect ID; required
  /// for [openStoreListing] to work on iOS/macOS, not needed just to
  /// call [requestReview] / [maybeRequestReview].
  ///
  /// [minDaysSinceInstall] and [minRequestCooldownDays] are app-side
  /// throttling layered on top of whatever the OS itself enforces —
  /// tune them to your app. [maxRequestsPerYear] mirrors Apple's limit
  /// of 3 prompts per 365 days.
  ///
  /// [onError] is an optional hook — wire it to your crash reporter if
  /// you want errors forwarded somewhere beyond the log stream. Every
  /// exception caught inside this class is always logged via [_log]
  /// regardless of whether [onError] is set.
  static void init({
    String? appStoreId,
    String microsoftStoreId = '',
    Duration minTimeSinceInstall = const Duration(seconds: 10),
    int minRequestCooldownDays = 90,
    int maxRequestsPerYear = 3,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    _appStoreId = (appStoreId?.isNotEmpty ?? false) ? appStoreId : null;
    _microsoftStoreId = microsoftStoreId;
    _minTimeSinceInstall = minTimeSinceInstall;
    _minRequestCooldownDays = minRequestCooldownDays;
    _maxRequestsPerYear = maxRequestsPerYear;
    _onError = onError;
    _initialized = true;

    _log.config(
      'init() appStoreId=${_appStoreId ?? "(none)"} '
      'minTimeSinceInstall=$_minTimeSinceInstall '
      'minRequestCooldownDays=$_minRequestCooldownDays '
      'maxRequestsPerYear=$_maxRequestsPerYear',
    );

    // Automatically record the first launch.
    unawaited(recordAppLaunch());
  }

  static void _reportError(Object error, StackTrace stackTrace) {
    _log.severe('Unhandled error', error, stackTrace);
    _onError?.call(error, stackTrace);
  }

  static void _assertInitialized() {
    assert(_initialized, 'AppReview.init() must be called before use, e.g. in main().');
  }

  /// Marks "now" as the app's first-launch time, if that hasn't already
  /// been recorded. Call this once per install, as early as possible
  /// (right after [init] in `main()`), so [minDaysSinceInstall] counts
  /// from the real install date rather than whenever a review check
  /// first happens to run.
  static Future<void> recordAppLaunch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!prefs.containsKey(_keyFirstLaunchAt)) {
        final now = DateTime.now();
        await prefs.setString(_keyFirstLaunchAt, now.toIso8601String());
        _log.fine('Recorded first launch at $now');
      }
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
    }
  }

  static DateTime? _parseDate(String? value) => value == null ? null : DateTime.tryParse(value);

  /// Whether the native review sheet is worth attempting right now: the
  /// platform reports it's available *and* your own throttling rules
  /// (min days since install, cooldown, yearly cap) all pass.
  ///
  /// Note this can never be 100% certain anything will actually appear —
  /// iOS and Android make the final call themselves and never confirm
  /// whether the dialog was shown to the user.
  static Future<bool> shouldRequestReview() async {
    _assertInitialized();
    try {
      final hasInternet = await _hasInternetConnection();
      if (!hasInternet) {
        _log.info('shouldRequestReview() = false (no network connection)');
        return false;
      }

      final available = await _inAppReview.isAvailable();
      _log.fine('isAvailable() = $available');
      if (!available) {
        _log.info('shouldRequestReview() = false (platform reports unavailable)');
        return false;
      }

      // The plugin can't be exercised through a local/sideloaded debug
      // install on Android — only through Play's testing tracks — so
      // don't bother asking while debugging.
      if (Platform.isAndroid && kDebugMode) {
        _log.fine('shouldRequestReview() = false (Android debug build)');
        return false;
      }

      final prefs = await SharedPreferences.getInstance();

      await recordAppLaunch(); // no-op if already recorded
      final firstLaunch = _parseDate(prefs.getString(_keyFirstLaunchAt)) ?? DateTime.now();
      final timeSinceInstall = DateTime.now().difference(firstLaunch);
      if (timeSinceInstall < _minTimeSinceInstall) {
        _log.info('shouldRequestReview() = false (only $timeSinceInstall since install, need $_minTimeSinceInstall)');
        return false;
      }

      var requestCount = prefs.getInt(_keyRequestCount) ?? 0;
      final lastRequestedAt = _parseDate(prefs.getString(_keyLastRequestedAt));

      if (requestCount >= _maxRequestsPerYear) {
        final withinTheYear = lastRequestedAt != null && DateTime.now().difference(lastRequestedAt).inDays < 365;
        if (withinTheYear) {
          _log.info('shouldRequestReview() = false (yearly cap of $_maxRequestsPerYear reached)');
          return false;
        }
        // A year has passed since the cap kicked in — start over.
        requestCount = 0;
        await prefs.setInt(_keyRequestCount, 0);
        _log.fine('Yearly cap window elapsed, resetting request count');
      }

      if (lastRequestedAt != null) {
        final daysSinceLastRequest = DateTime.now().difference(lastRequestedAt).inDays;
        if (daysSinceLastRequest < _minRequestCooldownDays) {
          _log.info('shouldRequestReview() = false (cooldown: ${daysSinceLastRequest}d since last ask, need $_minRequestCooldownDays)');
          return false;
        }
      }

      _log.fine('shouldRequestReview() = true');
      return true;
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
      return false;
    }
  }

  /// Triggers the native review sheet unconditionally. Prefer
  /// [maybeRequestReview] — which checks [shouldRequestReview] first —
  /// and call this directly only if you've already done your own gating.
  static Future<bool> requestReview() async {
    _assertInitialized();
    try {
      await _inAppReview.requestReview();
      final prefs = await SharedPreferences.getInstance();
      final newCount = (prefs.getInt(_keyRequestCount) ?? 0) + 1;
      await prefs.setInt(_keyRequestCount, newCount);
      await prefs.setString(_keyLastRequestedAt, DateTime.now().toIso8601String());
      _log.info('requestReview() called (request #$newCount this cycle)');
      return true;
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
      return false;
    }
  }

  /// Convenience: checks [shouldRequestReview] and, if it passes,
  /// immediately calls [requestReview]. Call this from a "happy path"
  /// moment in your app — after a task completes successfully, not
  /// right after launch or right after an error.
  static Future<bool> maybeRequestReview() async {
    if (!await shouldRequestReview()) return false;
    return requestReview();
  }

  /// Opens the store listing page directly — the manual fallback for a
  /// "Rate us" button in a settings screen. Unlike [requestReview], this
  /// always navigates the user off-app, so use it only for an explicit,
  /// user-initiated action.
  static Future<void> openStoreListing() async {
    _assertInitialized();
    if (_appStoreId == null && (Platform.isIOS || Platform.isMacOS)) {
      final error = StateError(
        'AppReview: appStoreId was not provided to init(), so openStoreListing() '
        'cannot resolve a store URL on this platform.',
      );
      _reportError(error, StackTrace.current);
      throw error;
    }
    try {
      await _inAppReview.openStoreListing(appStoreId: _appStoreId ?? '', microsoftStoreId: _microsoftStoreId);
      _log.info('openStoreListing() called');
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
    }
  }

  /// Records that the user confirmed (via your own UI) that they left a
  /// rating. Pure bookkeeping, exposed through [status] — it doesn't
  /// change whether future prompts are shown.
  static Future<void> confirmReview() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyConfirmed, true);
      _log.info('confirmReview() recorded');
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
    }
  }

  /// A snapshot of everything this class has recorded — handy for a
  /// debug screen or for building your own confirmation UI.
  static Future<AppReviewStatus> status() async {
    final prefs = await SharedPreferences.getInstance();
    return AppReviewStatus(
      hasRequested: (prefs.getInt(_keyRequestCount) ?? 0) > 0,
      hasConfirmed: prefs.getBool(_keyConfirmed) ?? false,
      requestCount: prefs.getInt(_keyRequestCount) ?? 0,
      lastRequestedAt: _parseDate(prefs.getString(_keyLastRequestedAt)),
    );
  }

  /// Clears all stored state. For development/QA builds only — gate any
  /// UI that calls this behind `kDebugMode` or a debug menu.
  static Future<void> resetForTesting() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([prefs.remove(_keyRequestCount), prefs.remove(_keyLastRequestedAt), prefs.remove(_keyConfirmed), prefs.remove(_keyFirstLaunchAt)]);
    _log.warning('resetForTesting() cleared all AppReview state');
  }

  /// Returns true when the device has an active network connection.
  ///
  /// `connectivity_plus` checks whether a network interface such as Wi-Fi
  /// or mobile data is available. This does not guarantee that the internet
  /// is actually reachable.
  static Future<bool> _hasInternetConnection() async {
    try {
      final result = await Connectivity().checkConnectivity();
      final hasConnection = !result.contains(ConnectivityResult.none);
      _log.finer('Connectivity check: $result -> hasConnection=$hasConnection');
      return hasConnection;
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
      return false;
    }
  }
}
