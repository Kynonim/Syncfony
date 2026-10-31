import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:syncfony/api.dart';
import 'package:syncfony/style.dart';
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
        snackBarTheme: const SnackBarThemeData(
          behavior: .floating,
          elevation: 0,
        ),
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
  final focus = FocusNode();
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
    Future.delayed(const Duration(microseconds: 400), () {
      if (mounted) focus.requestFocus();
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
      Navigator.of(context).push(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 450),
          pageBuilder: (_, a, _) => FadeTransition(
            opacity: a,
            child: GaleryManager(api: Api(url)),
          ),
          transitionsBuilder: (_, a, _, child) {
            final offset = Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic));
            return FadeTransition(
              opacity: a,
              child: SlideTransition(position: offset, child: child),
            );
          },
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Connection error: $e"), backgroundColor: Colors.red.shade700),
      );
    } finally {
      if (mounted) setState(() => isChecking = false);
    }
  }

  @override
  void dispose() {
    focus.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SyncfonyFluid(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: .all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  builder: (context, v, child) {
                    return Opacity(
                      opacity: v,
                      child: Transform.translate(
                        offset: Offset(0, 16 * (1 - v)),
                        child: child,
                      ),
                    );
                  },
                  child: SyncfonyPanel(
                    padding: const .all(28),
                    child: Column(
                      mainAxisSize: .min,
                      crossAxisAlignment: .stretch,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: .circle,
                            gradient: const LinearGradient(
                              colors: [Color(0xFF6C8CFF), Color(0xFFB06CFF)],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF6C8CFF).withValues(alpha: 0.4),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ]
                          ),
                          child: const Icon(Icons.cloud_rounded, color: Colors.white, size: 32),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          "Syncfony",
                          textAlign: .center,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: .w700,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "Backup Foto & Video ke Server Pribadi",
                          textAlign: .center,
                          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.black54),
                        ),
                        const SizedBox(height: 28),
                        TextField(
                          controller: controller,
                          focusNode: focus,
                          keyboardType: .url,
                          textInputAction: .go,
                          onSubmitted: (_) => isChecking ? null : go(),
                          decoration: InputDecoration(
                            labelText: "Server URL",
                            hintText: "http://192.168.0.1:2026",
                            prefixIcon: const Icon(Icons.link_rounded),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.6),
                            border: OutlineInputBorder(
                              borderRadius: .circular(16),
                              borderSide: .none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: .circular(16),
                              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.8)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: .circular(16),
                              borderSide: const BorderSide(color: Color(0xFF6C8CFF), width: 1.5),
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          height: 52,
                          child: FilledButton(
                            onPressed: isChecking ? null : go,
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(borderRadius: .circular(16)),
                              backgroundColor: const Color(0xFF6C8CFF),
                            ),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              child: isChecking ? const SizedBox(
                                key: ValueKey("l"),
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: Colors.white,
                                ),
                              ) : const Row(
                                key: ValueKey("t"),
                                mainAxisAlignment: .center,
                                children: [
                                  Text(
                                    "Start",
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: .w600,
                                    ),
                                  ),
                                  SizedBox(width: 8),
                                  Icon(Icons.arrow_forward_rounded, size: 30),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
