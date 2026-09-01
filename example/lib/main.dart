import 'package:flutter/material.dart';
import 'package:nexus_flutter/nexus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialise once, at startup — like the WebSocket SDK.
  await Nexus.init(const NexusConfig(
    apiKey: 'nxs_your_api_key',
    baseUrl: 'https://api.nexus.inverge.net',
    logging: true,
  ));

  // Optionally identify the end-user; everything after is correlated to them.
  await Nexus.instance.identify('user_123', email: 'alice@shopper.com');

  // Wrap the app so `context.nexus` is available everywhere.
  runApp(const NexusScope(child: DemoApp()));
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexus SDK demo',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0D7D82), useMaterial3: true),
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
  String _status = 'Ready';

  @override
  void initState() {
    super.initState();
    // Access services via context after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.nexus.events.track('screen_viewed', properties: {'screen': 'home'});
      context.nexus.logs.info('home screen opened', source: 'ui');
    });
  }

  @override
  Widget build(BuildContext context) {
    // Everything through the app context: context.nexus.<service>
    final nexus = context.nexus;
    return Scaffold(
      appBar: AppBar(title: const Text('Nexus umbrella SDK')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                nexus.events.track('order_placed', properties: {'total': 129});
                setState(() => _status = 'Tracked order_placed');
              },
              child: const Text('events · track'),
            ),
            FilledButton(
              onPressed: () async {
                await nexus.flags.load();
                setState(() => _status = 'new-checkout = ${nexus.flags.isEnabled('new-checkout')}');
              },
              child: const Text('flags · evaluate'),
            ),
            FilledButton(
              onPressed: () {
                nexus.realtime.connect();
                nexus.realtime.join('orders:42');
                nexus.realtime.on('order.updated', (data) => debugPrint('rt: $data'));
                setState(() => _status = 'Realtime connected + joined orders:42');
              },
              child: const Text('realtime · join'),
            ),
            FilledButton(
              onPressed: () async {
                await nexus.replay.start();
                setState(() => _status = 'Session replay started');
              },
              child: const Text('replay · start'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  throw StateError('demo error');
                } catch (e, s) {
                  nexus.errors.capture(e, s);
                  setState(() => _status = 'Captured an error');
                }
              },
              child: const Text('errors · capture'),
            ),
          ],
        ),
      ),
    );
  }
}
