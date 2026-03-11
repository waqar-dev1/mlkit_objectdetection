import 'package:flutter/material.dart';

/// Shutter / capture button.
///
/// Renders the classic camera-shutter look: a white filled circle inside a
/// white ring, with a subtle scale-down animation on press.
///
/// Kept as a standalone widget so Phase 3 can swap its appearance (e.g. add
/// a progress ring, change colour when a document is locked) without touching
/// the screen layout.
class CaptureButton extends StatefulWidget {
  final VoidCallback? onTap;

  /// Diameter of the outer ring. Inner circle is 75 % of this.
  final double size;

  /// Whether the button should accept taps. Set to false while a capture
  /// is already in progress.
  final bool enabled;

  const CaptureButton({
    super.key,
    required this.onTap,
    this.size = 72,
    this.enabled = true,
  });

  @override
  State<CaptureButton> createState() => _CaptureButtonState();
}

class _CaptureButtonState extends State<CaptureButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
      reverseDuration: const Duration(milliseconds: 120),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.88).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeIn),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    if (widget.enabled) _ctrl.forward();
  }

  void _onTapUp(TapUpDetails _) {
    _ctrl.reverse();
    if (widget.enabled) widget.onTap?.call();
  }

  void _onTapCancel() => _ctrl.reverse();

  @override
  Widget build(BuildContext context) {
    final outerSize = widget.size;
    final innerSize = outerSize * 0.75;

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: ScaleTransition(
        scale: _scale,
        child: Opacity(
          opacity: widget.enabled ? 1.0 : 0.45,
          child: SizedBox(
            width: outerSize,
            height: outerSize,
            child: CustomPaint(
              painter: _ShutterPainter(innerSize: innerSize),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShutterPainter extends CustomPainter {
  final double innerSize;
  const _ShutterPainter({required this.innerSize});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerR = size.width / 2;
    final innerR = innerSize / 2;

    // Outer ring
    canvas.drawCircle(
      center,
      outerR,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    // Inner filled circle
    canvas.drawCircle(
      center,
      innerR,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_ShutterPainter old) => old.innerSize != innerSize;
}