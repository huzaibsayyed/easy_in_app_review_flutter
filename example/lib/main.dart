import 'package:easy_in_app_review_flutter/easy_in_app_review_flutter.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Print the full decision trace to the console. Use Level.INFO or
  // Level.WARNING in a real app so only meaningful events are logged.
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint('[${record.level.name}] ${record.loggerName}: ${record.message}');
  });

  AppReview.init(
    // Replace with your own numeric App Store Connect ID.
    appStoreId: '123456789',
    minTimeSinceInstall: const Duration(seconds: 10),
    minRequestCooldownDays: 90,
    maxRequestsPerYear: 3,
    onError: (error, stackTrace) => debugPrint('AppReview error: $error'),
  );

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'easy_in_app_review_flutter example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppReviewStatus? _status;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final status = await AppReview.status();
    if (!mounted) return;
    setState(() => _status = status);
  }

  Future<void> _maybeRequestReview() async {
    final triggered = await AppReview.maybeRequestReview();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(triggered ? 'Review requested.' : 'Eligibility checks did not pass — see console logs.')));
    await _refreshStatus();
  }

  Future<void> _showRatePrompt() async {
    final triggered = await context.showRatePromptDialog();
    if (!mounted) return;
    if (triggered) await context.showReviewConfirmationDialog();
    await _refreshStatus();
  }

  Future<void> _resetForTesting() async {
    await AppReview.resetForTesting();
    await _refreshStatus();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Review state reset.')));
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;

    return Scaffold(
      appBar: AppBar(title: const Text('easy_in_app_review_flutter example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: status == null
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Status', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Text('Has requested: ${status.hasRequested}'),
                        Text('Has confirmed: ${status.hasConfirmed}'),
                        Text('Request count: ${status.requestCount}'),
                        Text('Last requested at: ${status.lastRequestedAt ?? '-'}'),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _maybeRequestReview, child: const Text('Maybe request review')),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _showRatePrompt, child: const Text('Show rate prompt dialog')),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: AppReview.openStoreListing, child: const Text('Open store listing')),
          const SizedBox(height: 24),
          TextButton(onPressed: _resetForTesting, child: const Text('Reset review state (testing only)')),
        ],
      ),
    );
  }
}
