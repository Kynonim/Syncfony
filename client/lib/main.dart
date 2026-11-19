import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:syncfony/background.dart';
import 'package:syncfony/l10n.dart';
import 'package:syncfony/service.dart';
import 'package:syncfony/uix.dart';
import 'package:syncfony/widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarBrightness: .dark,
      systemNavigationBarColor: Colors.transparent,
    ),
  );

  // Muat preferensi tampilan & bahasa sebelum frame pertama agar tidak ada "flash".
  final prefs = await SharedPreferences.getInstance();
  glassBlurScale = (prefs.getDouble(glassBlurPrefsKey) ?? 1.0)
      .clamp(minGlassBlurScale, maxGlassBlurScale)
      .toDouble();
  accentColor.value = accentById(prefs.getString(accentPrefsKey)).seed;
  await l10n.load();

  // Daftarkan tugas backup periodik jika sebelumnya diaktifkan di Settings.
  await configureBackgroundBackup(
    enabled: prefs.getBool(backgroundEnabledPrefsKey) ?? false,
  );

  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final brightness = View.of(context).platformDispatcher.platformBrightness;
    final MaterialTheme theme = MaterialTheme(textTheme);

    return AnimatedBuilder(
      animation: Listenable.merge([accentColor, l10n]),
      builder: (context, _) {
        // Hanya kirim locale yang benar-benar didukung delegate Material.
        // Tanpa ini, Locale('id') akan gagal menemukan MaterialLocalizations.
        final active = Locale(l10n.code);
        final activeSupported = GlobalMaterialLocalizations.delegate.isSupported(active);
        final materialLocales = <Locale>[
          for (final option in l10n.languages)
            if (GlobalMaterialLocalizations.delegate.isSupported(Locale(option.code)))
              Locale(option.code),
          const Locale('en'),
        ];

        return MaterialApp(
          title: 'Syncfony',
          theme: brightness == .light ? theme.light() : theme.dark(),
          locale: activeSupported ? active : const Locale('en'),
          supportedLocales: materialLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const Syncfony(),
          debugShowCheckedModeBanner: false,
        );
      },
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
  static const prefsKey = serverUrlPrefsKey;
  static const tokenPrefsKey = serverTokenPrefsKey;
  final focus = FocusNode();
  final controller = TextEditingController(text: "http://127.0.0.1:2026");
  final tokenController = TextEditingController();

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((x) {
      final saved = x.getString(prefsKey);
      if (saved != null && saved.isNotEmpty) {
        controller.text = saved;
      }
      final savedToken = x.getString(tokenPrefsKey);
      if (savedToken != null && savedToken.isNotEmpty) {
        tokenController.text = savedToken;
      }
    });
    Future.delayed(const Duration(microseconds: 400), () {
      if (mounted) focus.requestFocus();
    });
  }

  Future<void> run() async {
    final url = controller.text.trim();
    final token = tokenController.text.trim();
    if (url.isEmpty) return;
    setState(() => isChecking = true);
    try {
      final api = Api(url, token: token.isEmpty ? null : token);
      final isHealth = await api.checkServer();
      if (!isHealth) throw Exception("Koneksi terputus");
      if (token.isNotEmpty) {
        await api.getStats();
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, url);
      await prefs.setString(tokenPrefsKey, token);
      if (!mounted) return;
      goto(
        context,
        SyncfonyGallery(
          serverUrl: url,
          token: token.isEmpty ? null : token,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      final err = msg.contains("401")
          ? t('error.tokenInvalid')
          : msg.contains("errno = 1")
              ? t('error.network')
              : msg.contains("errno = 61")
                  ? t('error.offline')
                  : t('error.connect', args: {'error': msg});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), backgroundColor: Colors.red.shade800),
      );
    } finally {
      if (mounted) setState(() => isChecking = false);
    }
  }

  @override
  void dispose() {
    focus.dispose();
    controller.dispose();
    tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: AppBackground()),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                mainAxisAlignment: .center,
                children: [
                  const AppLogo(size: 112),
                  const SizedBox(height: 10),
                  const Text(
                    "Syncfony",
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 40, letterSpacing: -1.2),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    t('welcome.tagline'),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  GlassSurface(
                    radius: 30,
                    opacity: 0.55,
                    blur: 30,
                    padding: const EdgeInsets.all(20),
                    margin: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
                        TextField(
                          controller: controller,
                          focusNode: focus,
                          keyboardType: .url,
                          textInputAction: .next,
                          decoration: InputDecoration(
                            labelText: t('server.url'),
                            hintText: "http://127.0.0.1:2026",
                            prefixIcon: const Icon(Icons.link_rounded),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: tokenController,
                          obscureText: true,
                          textInputAction: .go,
                          onSubmitted: (_) => isChecking ? null : run(),
                          decoration: InputDecoration(
                            labelText: t('server.token'),
                            hintText: t('server.tokenHint'),
                            prefixIcon: const Icon(Icons.key_rounded),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          height: 54,
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: isChecking ? null : run,
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: .circular(20),
                              ),
                            ),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              child: isChecking
                                  ? const SizedBox(
                                      key: ValueKey("l"),
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(strokeWidth: 2.4),
                                    )
                                  : Row(
                                      key: const ValueKey("t"),
                                      mainAxisAlignment: .center,
                                      children: [
                                        Text(
                                          t('action.start'),
                                          style: const TextStyle(fontSize: 16, fontWeight: .w600),
                                        ),
                                        const SizedBox(width: 8),
                                        const Icon(Icons.arrow_forward_ios, size: 16),
                                      ],
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
