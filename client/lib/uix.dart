import 'dart:math' as math;
import 'dart:ui';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransitionsBuilder;
import 'package:material_ui/material_ui.dart';

void goto(BuildContext context, Widget widget) {
  Navigator.of(context).push(
    PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 450),
      pageBuilder: (_, x, _) => FadeTransition(opacity: x, child: widget),
      transitionsBuilder: (_, x, _, c) {
        final offset = Tween(
          begin: const Offset(0, 0.04),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: x, curve: Curves.easeOutCubic));
        return FadeTransition(
          opacity: x,
          child: SlideTransition(position: offset, child: c),
        );
      },
    ),
  );
}

void goback(BuildContext context) {
  Navigator.pop(context);
}

/// ---------------------------------------------------------------------------
/// Preferensi tampilan global
/// ---------------------------------------------------------------------------

/// Skala global intensitas blur kaca:
/// `0.0` = tanpa blur (hanya tint), `1.0` = default, `2.0` = dua kali lipat.
double glassBlurScale = 1.0;
const double minGlassBlurScale = 0.0;
const double maxGlassBlurScale = 2.0;

const String glassBlurPrefsKey = 'syncfony_glass_blur';
const String gridColumnsPrefsKey = 'syncfony_grid_columns';
const String accentPrefsKey = 'syncfony_accent';
const String gooeyEffectPrefsKey = 'syncfony_gooey_effect';
const String gooeyIntensityPrefsKey = 'syncfony_gooey_intensity';

/// Efek gooey/metaball pada app bar dan bottom bar.
final ValueNotifier<bool> gooeyEffectEnabled = ValueNotifier(true);
final ValueNotifier<double> gooeyIntensity = ValueNotifier(0.65);

class AccentOption {
  final String id;
  final String label;
  final Color seed;

  const AccentOption(this.id, this.label, this.seed);
}

/// Palet aksen bergaya warna sistem iOS.
const List<AccentOption> accentOptions = [
  AccentOption('green', 'Hijau', Color(0xFF2F7D4F)),
  AccentOption('blue', 'Biru', Color(0xFF0A84FF)),
  AccentOption('teal', 'Teal', Color(0xFF12A5A5)),
  AccentOption('purple', 'Ungu', Color(0xFF7C5CFF)),
  AccentOption('pink', 'Pink', Color(0xFFE0518C)),
  AccentOption('orange', 'Oranye', Color(0xFFFF8A3D)),
  AccentOption('red', 'Merah', Color(0xFFE5483C)),
  AccentOption('graphite', 'Grafit', Color(0xFF6E7B72)),
];

AccentOption accentById(String? id) {
  return accentOptions.firstWhere(
    (option) => option.id == id,
    orElse: () => accentOptions.first,
  );
}

/// Warna aksen aktif. Widget yang bergantung padanya harus listen ke notifier ini.
final ValueNotifier<Color> accentColor = ValueNotifier(accentOptions.first.seed);

/// Logo aplikasi yang otomatis mengikuti warna aksen.
///
/// `BlendMode.color` mempertahankan detail (luminance) line art sambil
/// mengganti hue/saturasi latar ikon, sehingga tampilannya tetap tajam.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 40, this.tinted = true});

  final double size;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      'assets/main.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
    if (!tinted) return image;

    return ValueListenableBuilder<Color>(
      valueListenable: accentColor,
      builder: (context, accent, _) {
        return ColorFiltered(
          colorFilter: ColorFilter.mode(accent, BlendMode.color),
          child: image,
        );
      },
    );
  }
}

/// Latar berlapis lembut: wash warna aksen + vignette tipis.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ValueListenableBuilder<Color>(
      valueListenable: accentColor,
      builder: (context, accent, _) {
        final soft = isDark
            ? Color.lerp(accent, const Color(0xFF05070A), 0.45)!
            : Color.lerp(accent, Colors.white, 0.55)!;
        final companion = isDark
            ? Color.lerp(accent, const Color(0xFF1E3A5F), 0.80)!
            : Color.lerp(accent, const Color(0xFF7C9CC0), 0.80)!;

        return IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: isDark
                        ? const [Color(0xFF0A0C0E), Color(0xFF06070A)]
                        : const [Color(0xFFFDFDFE), Color(0xFFF1F3F6)],
                  ),
                ),
              ),
              _blob(
                alignment: const Alignment(-0.95, -1.2),
                color: soft,
                opacity: isDark ? 0.52 : 0.45,
              ),
              _blob(
                alignment: const Alignment(1.15, 0.95),
                color: companion,
                opacity: isDark ? 0.24 : 0.20,
              ),
              // Vignette tipis untuk memberi kedalaman.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 1.05,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: isDark ? 0.26 : 0.05),
                    ],
                    stops: const [0.55, 1.0],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _blob({
    required Alignment alignment,
    required Color color,
    required double opacity,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: alignment,
          radius: 1.4,
          colors: [color.withValues(alpha: opacity), color.withValues(alpha: 0)],
        ),
      ),
    );
  }
}

/// Permukaan kaca: blur + tint + garis specular + bayangan lembut.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = 28,
    this.blur = 26,
    this.padding = EdgeInsets.zero,
    this.tint,
    this.opacity = 0.55,
    this.showBorder = true,
    this.shadow = true,
    this.width,
    this.height,
    this.margin,
  });

  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsets padding;
  final Color? tint;
  final double opacity;
  final bool showBorder;
  final bool shadow;
  final double? width;
  final double? height;
  final EdgeInsets? margin;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = tint ?? (isDark ? const Color(0xFF0D1014) : Colors.white);
    final fill = base.withValues(alpha: opacity);
    final highlight = Colors.white.withValues(alpha: isDark ? 0.16 : 0.60);
    final shade = Colors.black.withValues(alpha: isDark ? 0.20 : 0.035);
    final borderRadius = BorderRadius.circular(radius);
    final sigma = blur * glassBlurScale;

    final surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(highlight, fill),
            fill,
            Color.alphaBlend(shade, fill),
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
        border: showBorder
            ? Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.18 : 0.75),
                width: 0.9,
              )
            : null,
      ),
      child: Padding(padding: padding, child: child),
    );

    return Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.38 : 0.10),
                  blurRadius: 30,
                  spreadRadius: -6,
                  offset: const Offset(0, 14),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        // Blur dimatikan sepenuhnya saat pengaturan = 0 (hemat GPU).
        child: sigma <= 0.01
            ? surface
            : BackdropFilter(
                filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: surface,
              ),
      ),
    );
  }
}

/// Surface kaca dengan bentuk yang beranimasi lembut seperti tetesan air.
///
/// Saat efek gooey aktif, silhouette bar + beberapa blob digambar di belakang
/// kaca, lalu di-blur dan di-threshold sehingga elemen-elemennya menyatu /
/// terbelah seperti metaball.
class LiquidGlassBar extends StatefulWidget {
  final Widget child;
  final double radius;
  final BorderRadius? borderRadius;
  final double blur;
  final double opacity;
  final Color? tint;
  final EdgeInsets padding;
  final EdgeInsets? margin;
  final bool shadow;
  final bool showBorder;
  final int? activeIndex;
  final int? itemCount;

  const LiquidGlassBar({
    super.key,
    required this.child,
    this.radius = 30,
    this.borderRadius,
    this.blur = 30,
    this.opacity = 0.58,
    this.tint,
    this.padding = EdgeInsets.zero,
    this.margin,
    this.shadow = true,
    this.showBorder = true,
    this.activeIndex,
    this.itemCount,
  });

  @override
  State<LiquidGlassBar> createState() => _LiquidGlassBarState();
}

class _LiquidGlassBarState extends State<LiquidGlassBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _indexController = AnimationController.unbounded(
    vsync: this,
    duration: const Duration(milliseconds: 460),
    value: (widget.activeIndex ?? 0).toDouble(),
  );

  @override
  void initState() {
    super.initState();
    gooeyEffectEnabled.addListener(_syncIndex);
  }

  @override
  void didUpdateWidget(covariant LiquidGlassBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeIndex != oldWidget.activeIndex && widget.activeIndex != null) {
      if (gooeyEffectEnabled.value) {
        _indexController.animateTo(
          widget.activeIndex!.toDouble(),
          duration: const Duration(milliseconds: 460),
          curve: Curves.easeOutCubic,
        );
      } else {
        _indexController.value = widget.activeIndex!.toDouble();
      }
    }
  }

  void _syncIndex() {
    if (!mounted) return;
    if (!gooeyEffectEnabled.value) {
      _indexController.stop();
      if (widget.activeIndex != null) {
        _indexController.value = widget.activeIndex!.toDouble();
      }
    }
  }

  @override
  void dispose() {
    gooeyEffectEnabled.removeListener(_syncIndex);
    _indexController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final base = widget.tint ?? (isDark ? const Color(0xFF0D1014) : Colors.white);
    final fill = base.withValues(alpha: widget.opacity);
    final sigma = widget.blur * glassBlurScale;

    return AnimatedBuilder(
      animation: Listenable.merge([
        _indexController,
        gooeyEffectEnabled,
        gooeyIntensity,
      ]),
      builder: (context, child) {
        final enabled = gooeyEffectEnabled.value;
        final intensity = gooeyIntensity.value.clamp(0.0, 1.0);
        final radius = widget.borderRadius ?? BorderRadius.circular(widget.radius);

        final surface = DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(Colors.white.withValues(alpha: isDark ? 0.16 : 0.60), fill),
                fill,
                Color.alphaBlend(Colors.black.withValues(alpha: isDark ? 0.20 : 0.035), fill),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.65, -0.7),
                        radius: 1.05,
                        colors: [
                          Colors.white.withValues(alpha: isDark ? 0.16 : 0.34),
                          Colors.white.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0.7, 0.6),
                        radius: 0.72,
                        colors: [
                          scheme.primary.withValues(alpha: isDark ? 0.16 : 0.12),
                          scheme.primary.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.showBorder)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: isDark ? 0.18 : 0.75),
                          width: 0.9,
                        ),
                      ),
                    ),
                  ),
                ),
              Padding(padding: widget.padding, child: child),
            ],
          ),
        );

        final gooey = enabled && intensity > 0.01
            ? _buildGooeyLayer(context, intensity, scheme.primary)
            : null;

        return Container(
          margin: widget.margin,
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: widget.shadow
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.34 : 0.10),
                      blurRadius: 34,
                      spreadRadius: -5,
                      offset: const Offset(0, 16),
                    ),
                  ]
                : null,
          ),
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              ?gooey,
              ClipRRect(
                borderRadius: radius,
                child: sigma <= 0.01
                    ? surface
                    : BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                        child: surface,
                      ),
              ),
            ],
          ),
        );
      },
      child: widget.child,
    );
  }

  Widget _buildGooeyLayer(BuildContext context, double intensity, Color color) {
    const inset = 36.0;
    final target = (widget.activeIndex ?? 0).toDouble();
    final transition = widget.activeIndex == null
        ? 0.0
        : (target - _indexController.value).abs().clamp(0.0, 1.0);
    final painter = _GooeyPainter(
      inset: inset,
      radius: widget.radius,
      color: color,
      activeIndex: widget.activeIndex == null ? null : _indexController.value,
      itemCount: widget.itemCount,
      activeTransition: transition,
      intensity: intensity,
    );

    return Positioned(
      left: -inset,
      top: -inset,
      right: -inset,
      bottom: -inset,
      child: IgnorePointer(
        child: Opacity(
          opacity: (0.70 * intensity).clamp(0.0, 0.8),
          child: ColorFiltered(
            colorFilter: _gooeyAlphaFilter,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: 8 + 7 * intensity,
                sigmaY: 8 + 7 * intensity,
              ),
              child: CustomPaint(painter: painter),
            ),
          ),
        ),
      ),
    );
  }
}

const ColorFilter _gooeyAlphaFilter = ColorFilter.matrix(<double>[
  1, 0, 0, 0, 0,
  0, 1, 0, 0, 0,
  0, 0, 1, 0, 0,
  0, 0, 0, 20, -2400,
]);

class _GooeyPainter extends CustomPainter {
  final double inset;
  final double radius;
  final Color color;
  final double? activeIndex;
  final int? itemCount;
  final double activeTransition;
  final double intensity;

  const _GooeyPainter({
    required this.inset,
    required this.radius,
    required this.color,
    required this.activeIndex,
    required this.itemCount,
    required this.activeTransition,
    required this.intensity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final paint = Paint()..color = color;
    final barRect = Rect.fromLTWH(
      inset,
      inset,
      math.max(0, size.width - inset * 2),
      math.max(0, size.height - inset * 2),
    );
    if (barRect.isEmpty) return;

    canvas.drawRRect(
      RRect.fromRectAndRadius(barRect, Radius.circular(radius)),
      paint,
    );

    if (activeIndex != null && itemCount != null && itemCount! > 0) {
      final x = barRect.left + barRect.width * ((activeIndex! + 0.5) / itemCount!);
      final drop = activeTransition.clamp(0.0, 1.0);
      canvas.drawCircle(
        Offset(x, barRect.bottom + barRect.height * 0.30 * drop),
        barRect.height * (0.30 + 0.08 * intensity) * (1 - 0.18 * drop),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GooeyPainter oldDelegate) => true;
}

/// Kartu kaca siap pakai (pengganti `Card`).
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 26,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(radius: radius, padding: padding, child: child);
  }
}

/// Tombol ikon bulat berbahan kaca.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.size = 44,
    this.iconSize = 22,
    this.color,
    this.active = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final Color? color;
  final bool active;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = color ?? (active ? scheme.onPrimary : scheme.onSurface);

    final button = GlassSurface(
      radius: size / 2,
      blur: 20,
      opacity: active ? 1.0 : 0.5,
      shadow: false,
      tint: active ? scheme.primary : null,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(size / 2),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: iconSize, color: foreground),
          ),
        ),
      ),
    );

    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// Bilah atas transparan ber-blur untuk halaman viewer media.
Widget viewerGlassBar() {
  final sigma = 26 * glassBlurScale;
  final overlay = ColoredBox(color: const Color(0xFF0B0D10).withValues(alpha: 0.42));
  return ClipRect(
    child: sigma <= 0.01
        ? overlay
        : BackdropFilter(
            filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: overlay,
          ),
  );
}

class MaterialTheme {
  final TextTheme textTheme;

  const MaterialTheme(this.textTheme);

  static ColorScheme lightScheme(Color seed) {
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    ).copyWith(
      error: const Color(0xffe5483c),
      onError: Colors.white,
      errorContainer: const Color(0xffffdad6),
      onErrorContainer: const Color(0xff93000a),
    );
  }

  ThemeData light() {
    return theme(lightScheme(accentColor.value));
  }

  static ColorScheme darkScheme(Color seed) {
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    ).copyWith(
      error: const Color(0xffff6b60),
      onError: const Color(0xff4a0504),
      errorContainer: const Color(0xff93000a),
      onErrorContainer: const Color(0xffffdad6),
    );
  }

  ThemeData dark() {
    return theme(darkScheme(accentColor.value));
  }

  ThemeData theme(ColorScheme colorScheme) => ThemeData(
    useMaterial3: true,
    brightness: colorScheme.brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    textTheme: textTheme.apply(
      bodyColor: colorScheme.onSurface,
      displayColor: colorScheme.onSurface,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surfaceContainerHigh.withValues(
        alpha: colorScheme.brightness == Brightness.dark ? 0.45 : 0.75,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colorScheme.primary, width: 1.4),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      backgroundColor: colorScheme.brightness == Brightness.dark
          ? const Color(0xFF1D2621)
          : const Color(0xFF141A16),
      contentTextStyle: TextStyle(
        color: colorScheme.brightness == Brightness.dark
            ? const Color(0xFFE4EAE6)
            : Colors.white,
        fontSize: 14,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    dividerTheme: DividerThemeData(
      color: colorScheme.outlineVariant.withValues(alpha: 0.35),
      thickness: 1,
      space: 1,
    ),
    iconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
  );
}
