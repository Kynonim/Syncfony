import 'package:material_ui/material_ui.dart';
import 'package:syncfony/app_info.dart';
import 'package:syncfony/l10n.dart';
import 'package:syncfony/uix.dart';

/// Layar kunci yang muncul sebelum galeri dibuka.
class LockScreen extends StatefulWidget {
  final Future<bool> Function() onUnlock;

  const LockScreen({super.key, required this.onUnlock});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _attempt());
  }

  Future<void> _attempt() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });

    final unlocked = await widget.onUnlock();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = !unlocked;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: AppBackground()),
          Center(
            child: GlassSurface(
              radius: 32,
              opacity: 0.6,
              blur: 32,
              margin: const EdgeInsets.symmetric(horizontal: 32),
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: const AppLogo(size: 72),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    AppInfo.name,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.5),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    t('lock.prompt'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (_failed) ...[
                    const SizedBox(height: 10),
                    Text(
                      t('lock.failed'),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _attempt,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.fingerprint_rounded),
                      label: Text(t('lock.unlock')),
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
