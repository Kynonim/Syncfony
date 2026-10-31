import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:syncfony/api.dart';
import 'package:syncfony/widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: .dark,
    systemNavigationBarColor: Colors.transparent,
  ));
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Syncfony',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6C8CFF),
        useMaterial3: true,
        fontFamily: ".SF Pro Text",
        scaffoldBackgroundColor: Colors.transparent,
      ),
      debugShowCheckedModeBanner: false,
      home: const Syncfony(),
    );
  }
}

class Syncfony extends StatefulWidget {
  const Syncfony({super.key});
  @override
  State<Syncfony> createState() => SyncfonyState();
}

class SyncfonyState extends State<Syncfony> {
  bool isChecking = false;
  static const prefkey = "syncfony_server_url";
  final controller = TextEditingController(text: "http://localhost:2026");

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final saved = p.getString(prefkey);
      if (saved != null && saved.isNotEmpty) {
        controller.text = saved;
      }
    });
  }

  Future<void> go() async {
    final url = controller.text.trim();
    if (url.isEmpty) return;
    setState(() => isChecking = true);

    try {
      final health = await http.get(Uri.parse("$url/api/health")).timeout(const Duration(seconds: 5));
      if (health.statusCode != 200) throw Exception("server tidak merespon");
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefkey, url);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => GaleryManager(api: Api(url))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Server error: $e"), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => isChecking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: .all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: .min,
                crossAxisAlignment: .stretch,
                children: [
                  Icon(Icons.cloud_upload_rounded, size: 72, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    "Syncfony",
                    textAlign: .center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: .bold
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Backup Foto & Video ke Server Pribadi",
                    textAlign: .center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey.shade600
                    ),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: "Server URL",
                      hintText: "http://192.168.0.1:2026",
                      prefixIcon: Icon(Icons.link),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: isChecking ? null : go,
                    icon: isChecking ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    ) : const Icon(Icons.arrow_forward),
                    label: Text(isChecking ? "Menghubungkan..." : "Start"),
                    style: FilledButton.styleFrom(padding: .symmetric(vertical: 14)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
