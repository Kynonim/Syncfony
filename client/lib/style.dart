import 'dart:math' as math;
import 'package:flutter/cupertino.dart';

class SyncfonyPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color? tint;
  final double radius, blur;

  const SyncfonyPanel({
    super.key,
    required this.child,
    this.padding = const .all(20),
    this.tint,
    this.radius = 24,
    this.blur = 18
  });

  @override
  Widget build(BuildContext context) {
    // TODO: implement build
    throw UnimplementedError();
  }
}

class SyncfonyFluid extends StatefulWidget {
  final Widget child;
  const SyncfonyFluid({super.key, required this.child});
  @override
  State<SyncfonyFluid> createState() => SyncfonyFluidState();
}

class SyncfonyFluidState extends State<SyncfonyFluid> with SingleTickerProviderStateMixin {
  late final AnimationController am;

  @override
  void initState() {
    super.initState();
    am = AnimationController(vsync: this, duration: const Duration(seconds: 18))..repeat();
  }

  @override
  void dispose() {
    am.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return AnimatedBuilder(
      animation: am,
      builder: (context, _i) {
        final t = am.value * 2 * math.pi;
        return Stack(
          children: [
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: .topLeft,
                  end: .bottomLeft,
                  colors: [Color(0xFFEAF2FF), Color(0xFFF7F0FF), Color(0xFFFFF3EC)]
                )
              ),
            ),
            styleBlob(
              size: size,
              cx: 0.25 + 0.05 * math.sin(t),
              cy: 0.20 + 0.05 * math.cos(t * 0.8),
              r: 0.45,
              color: const Color(0xFF7C9BFF).withValues(alpha: 0.35),
            ),
            styleBlob(
              size: size,
              cx: 0.75 + 0.05 * math.cos(t * 0.9),
              cy: 0.35 + 0.05 * math.sin(t * 0.7),
              r: 0.50,
              color: const Color(0xFFFF8FB1).withValues(alpha: 0.30),
            ),
            styleBlob(
              size: size,
              r: 0.45,
              color: const Color(0xFF8DE6C1).withValues(alpha: 0.28),
              cx: 0.55 + 0.06 * math.sin(t * 0.6 + 1),
              cy: 0.85 + 0.04 * math.cos(t * 0.7 + 1),
            ),
            widget.child
          ],
        );
      },
    );
  }
}

Widget styleBlob({required Size size, required Color color, required double cx, required double cy, required double r}) {
  final d = size.shortestSide * r * 2;
  return Positioned(
    left: size.width * cx - d / 2,
    top: size.height * cy - d / 2,
    child: IgnorePointer(
      child: Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          shape: .circle,
          gradient: RadialGradient(
            stops: [0.0, 1.0],
            colors: [color, color.withValues(alpha: 0)]
          ),
        ),
      ),
    ),
  );
}
