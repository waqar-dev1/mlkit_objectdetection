import 'dart:ui';
import 'package:flutter/material.dart';

import '../../screens/providers/capture_session.dart';

/// Interactive 4-corner document crop editor.
///
/// Renders over an image (inside a [Stack]) and lets the user drag each
/// corner handle to adjust the crop quad.  The parent receives updates via
/// [onQuadChanged].
///
/// Coordinate system: all values are normalised [0..1] relative to the
/// widget's own size, so the widget can be any size without the caller
/// needing to know the image dimensions.
class CropEditor extends StatefulWidget {
  /// Initial quad in normalised [0..1] coordinates.
  final CropQuad normQuad;

  /// Called continuously while the user drags a corner.
  final ValueChanged<CropQuad> onQuadChanged;

  const CropEditor({
    super.key,
    required this.normQuad,
    required this.onQuadChanged,
  });

  @override
  State<CropEditor> createState() => _CropEditorState();
}

class _CropEditorState extends State<CropEditor> {
  late CropQuad _quad;

  // Which corner is being dragged, or -1 for none.
  // 0=topLeft, 1=topRight, 2=bottomRight, 3=bottomLeft
  int _dragging = -1;

  static const double _handleRadius = 14.0;
  static const double _hitRadius    = 28.0; // larger invisible hit area

  @override
  void initState() {
    super.initState();
    _quad = widget.normQuad;
  }

  @override
  void didUpdateWidget(CropEditor old) {
    super.didUpdateWidget(old);
    if (old.normQuad != widget.normQuad) _quad = widget.normQuad;
  }

  List<Offset> get _corners => _quad.corners; // TL TR BR BL

  Offset _cornerAt(int i, Size size) {
    final c = _corners[i];
    return Offset(c.dx * size.width, c.dy * size.height);
  }

  CropQuad _updateCorner(int i, Offset normPos) {
    final clamped = Offset(
      normPos.dx.clamp(0.0, 1.0),
      normPos.dy.clamp(0.0, 1.0),
    );
    return CropQuad(
      topLeft:     i == 0 ? clamped : _quad.topLeft,
      topRight:    i == 1 ? clamped : _quad.topRight,
      bottomRight: i == 2 ? clamped : _quad.bottomRight,
      bottomLeft:  i == 3 ? clamped : _quad.bottomLeft,
    );
  }

  void _onPanStart(DragStartDetails d, Size size) {
    for (int i = 0; i < 4; i++) {
      if ((_cornerAt(i, size) - d.localPosition).distance < _hitRadius) {
        setState(() => _dragging = i);
        return;
      }
    }
  }

  void _onPanUpdate(DragUpdateDetails d, Size size) {
    if (_dragging < 0) return;
    final norm = Offset(
      d.localPosition.dx / size.width,
      d.localPosition.dy / size.height,
    );
    setState(() => _quad = _updateCorner(_dragging, norm));
    widget.onQuadChanged(_quad);
  }

  void _onPanEnd(DragEndDetails _) => setState(() => _dragging = -1);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, constraints) {
      final size = constraints.biggest;
      return GestureDetector(
        onPanStart:  (d) => _onPanStart(d, size),
        onPanUpdate: (d) => _onPanUpdate(d, size),
        onPanEnd:    _onPanEnd,
        child: CustomPaint(
          painter: _CropPainter(
            quad:     _quad,
            dragging: _dragging,
          ),
          size: size,
        ),
      );
    });
  }
}

// ── Painter ────────────────────────────────────────────────────────────────────

class _CropPainter extends CustomPainter {
  final CropQuad quad;
  final int dragging;

  const _CropPainter({required this.quad, required this.dragging});

  static const _handleRadius = 14.0;
  static const _accentColor  = Color(0xFF00E676);

  @override
  void paint(Canvas canvas, Size size) {
    final corners = quad.corners.map((c) =>
        Offset(c.dx * size.width, c.dy * size.height)).toList();

    // ── Dim mask outside the quad ──────────────────────────────────────────
    final quadPath = Path()..addPolygon(corners, true);
    final fullPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final maskPath = Path.combine(PathOperation.difference, fullPath, quadPath);
    canvas.drawPath(maskPath,
        Paint()..color = Colors.black.withOpacity(0.45));

    // ── Quad border ────────────────────────────────────────────────────────
    final borderPaint = Paint()
      ..color       = _accentColor
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    canvas.drawPath(quadPath, borderPaint);

    // ── Grid lines (3×3 rule-of-thirds) ───────────────────────────────────
    _drawGrid(canvas, corners);

    // ── Corner handles ─────────────────────────────────────────────────────
    for (int i = 0; i < 4; i++) {
      final isActive = dragging == i;
      // Outer ring
      canvas.drawCircle(
        corners[i],
        _handleRadius,
        Paint()
          ..color       = _accentColor.withOpacity(isActive ? 1.0 : 0.85)
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
      // Filled dot
      canvas.drawCircle(
        corners[i],
        isActive ? 8.0 : 5.0,
        Paint()..color = _accentColor,
      );
    }
  }

  void _drawGrid(Canvas canvas, List<Offset> c) {
    final gridPaint = Paint()
      ..color       = Colors.white.withOpacity(0.25)
      ..strokeWidth = 0.75;

    // Interpolate inside the quad for a perspective-correct grid
    for (int row = 1; row <= 2; row++) {
      final t = row / 3.0;
      final left  = Offset.lerp(c[0], c[3], t)!;
      final right = Offset.lerp(c[1], c[2], t)!;
      canvas.drawLine(left, right, gridPaint);
    }
    for (int col = 1; col <= 2; col++) {
      final t = col / 3.0;
      final top    = Offset.lerp(c[0], c[1], t)!;
      final bottom = Offset.lerp(c[3], c[2], t)!;
      canvas.drawLine(top, bottom, gridPaint);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.quad != quad || old.dragging != dragging;
}
