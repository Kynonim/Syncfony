import 'package:cupertino_ui/cupertino_ui.dart' show GlobalCupertinoLocalizations;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart' show GlobalWidgetsLocalizations;
import 'package:material_ui/material_ui.dart';
import 'package:syncfony/app_lock.dart';
import 'package:syncfony/background.dart';
import 'package:syncfony/l10n.dart';
import 'package:syncfony/lock_screen.dart';
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
  gooeyEffectEnabled.value = prefs.getBool(gooeyEffectPrefsKey) ?? true;
  gooeyIntensity.value = (prefs.getDouble(gooeyIntensityPrefsKey) ?? 0.65)
      .clamp(0.0, 1.0)
      .toDouble();
  await l10n.load();

  // Daftarkan tugas backup periodik jika sebelumnya diaktifkan di Settings.
  await configureBackgroundBackup(
    enabled: prefs.getBool(backgroundEnabledPrefsKey) ?? false,
  );

  runApp(App(
    initialServerUrl: prefs.getString(serverUrlPrefsKey),
    initialToken: prefs.getString(serverTokenPrefsKey),
    initialLockEnabled: prefs.getBool(AppLock.prefsKey) ?? false,
  ));
}

class App extends StatefulWidget {
  final String? initialServerUrl;
  final String? initialToken;
  final bool initialLockEnabled;

  const App({
    super.key,
    this.initialServerUrl,
    this.initialToken,
    this.initialLockEnabled = false,
  });

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  String? _serverUrl;
  String? _token;
  bool _lockEnabled = false;
  bool _unlocked = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final url = widget.initialServerUrl?.trim() ?? '';
    final token = widget.initialToken?.trim() ?? '';
    _serverUrl = url.isEmpty ? null : url;
    _token = token.isEmpty ? null : token;

    _lockEnabled = widget.initialLockEnabled;
    _unlocked = !_lockEnabled;

    appLockEnabled.value = _lockEnabled;
    appLockEnabled.addListener(_onLockSettingChanged);
  }

  void _onLockSettingChanged() {
    final enabled = appLockEnabled.value;
    setState(() {
      _lockEnabled = enabled;
      // Saat baru diaktifkan jangan langsung mengunci layar Settings;
      // kunci berlaku pada resume berikutnya.
      if (!enabled) _unlocked = true;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _lockEnabled && _unlocked) {
      setState(() => _unlocked = false);
    }
  }

  Future<bool> _unlock() async {
    final ok = await AppLock.authenticate();
    if (ok && mounted) setState(() => _unlocked = true);
    return ok;
  }

  @override
  void dispose() {
    appLockEnabled.removeListener(_onLockSettingChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _handleConnected(String url, String token) {
    setState(() {
      _serverUrl = url;
      _token = token.isEmpty ? null : token;
    });
  }

  Future<void> _handleDisconnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(serverUrlPrefsKey);
    await prefs.remove(serverTokenPrefsKey);
    // Putuskan server = logout: jangan biarkan kunci aplikasi/biometrik tetap
    // aktif untuk sesi berikutnya.
    await AppLock.setEnabled(false);
    if (!mounted) return;
    appLockEnabled.value = false;
    setState(() {
      _serverUrl = null;
      _token = null;
      _lockEnabled = false;
      _unlocked = true;
    });
  }

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
          // Lewati layar welcome bila server sudah pernah dikonfigurasi.
          home: _serverUrl == null
              ? Syncfony(onConnected: _handleConnected)
              : SyncfonyGallery(
                  serverUrl: _serverUrl!,
                  token: _token,
                  onDisconnect: _handleDisconnect,
                ),
          // Kunci aplikasi di atas seluruh navigator (termasuk viewer & sheet).
          builder: (context, child) {
            return Stack(
              children: [
                ?child,
                if (_lockEnabled && !_unlocked) LockScreen(onUnlock: _unlock),
              ],
            );
          },
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}

class Syncfony extends StatefulWidget {
  final void Function(String url, String token)? onConnected;

  const Syncfony({super.key, this.onConnected});

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
      widget.onConnected?.call(url, token);
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
      ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
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
