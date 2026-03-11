import 'dart:ui';
import 'package:flutter/material.dart';

import '../../screens/providers/capture_session.dart';

/// Handle types tracked during a drag gesture.
enum _HandleType {
  cornerTL, cornerTR, cornerBR, cornerBL,   // drag individual corner
  edgeTop, edgeRight, edgeBottom, edgeLeft,  // drag entire edge inward/outward
  none,
}

/// Interactive 4-corner + 4-edge-midpoint crop editor.
///
/// Corner handles  → move that corner freely (free-form quad distortion)
/// Edge handles    → move the entire edge inward or outward, keeping the
///                   opposite edge fixed (like Adobe Scan edge nudge)
///
/// All coordinates are normalised [0..1] relative to the widget size.
class CropEditor extends StatefulWidget {
  final CropQuad normQuad;
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
  _HandleType _dragging = _HandleType.none;

  // Slightly larger invisible hit areas for comfortable touch
  static const double _cornerHit = 32.0;
  static const double _edgeHit   = 28.0;

  @override
  void initState() {
    super.initState();
    _quad = widget.normQuad;
  }

  @override
  void didUpdateWidget(CropEditor old) {
    super.didUpdateWidget(old);
    if (old.normQuad != widget.normQuad && _dragging == _HandleType.none) {
      _quad = widget.normQuad;
    }
  }

  // ── Handle positions ──────────────────────────────────────────────────────

  Offset _px(Offset norm, Size size) =>
      Offset(norm.dx * size.width, norm.dy * size.height);

  /// Midpoint of the top edge (TL → TR)
  Offset _midTop(Size s) =>
      _px(Offset.lerp(_quad.topLeft, _quad.topRight, 0.5)!, s);

  /// Midpoint of the bottom edge (BL → BR)
  Offset _midBottom(Size s) =>
      _px(Offset.lerp(_quad.bottomLeft, _quad.bottomRight, 0.5)!, s);

  /// Midpoint of the left edge (TL → BL)
  Offset _midLeft(Size s) =>
      _px(Offset.lerp(_quad.topLeft, _quad.bottomLeft, 0.5)!, s);

  /// Midpoint of the right edge (TR → BR)
  Offset _midRight(Size s) =>
      _px(Offset.lerp(_quad.topRight, _quad.bottomRight, 0.5)!, s);

  // ── Hit testing ───────────────────────────────────────────────────────────

  _HandleType _hitTest(Offset pos, Size size) {
    Offset c(Offset n) => _px(n, size);

    // Corners first (higher priority)
    if ((c(_quad.topLeft)     - pos).distance < _cornerHit) return _HandleType.cornerTL;
    if ((c(_quad.topRight)    - pos).distance < _cornerHit) return _HandleType.cornerTR;
    if ((c(_quad.bottomRight) - pos).distance < _cornerHit) return _HandleType.cornerBR;
    if ((c(_quad.bottomLeft)  - pos).distance < _cornerHit) return _HandleType.cornerBL;

    // Edge midpoints
    if ((_midTop(size)    - pos).distance < _edgeHit) return _HandleType.edgeTop;
    if ((_midBottom(size) - pos).distance < _edgeHit) return _HandleType.edgeBottom;
    if ((_midLeft(size)   - pos).distance < _edgeHit) return _HandleType.edgeLeft;
    if ((_midRight(size)  - pos).distance < _edgeHit) return _HandleType.edgeRight;

    return _HandleType.none;
  }

  // ── Drag callbacks ────────────────────────────────────────────────────────

  void _onPanStart(DragStartDetails d, Size size) {
    setState(() => _dragging = _hitTest(d.localPosition, size));
  }

  void _onPanUpdate(DragUpdateDetails d, Size size) {
    if (_dragging == _HandleType.none) return;

    final nx = (d.localPosition.dx / size.width).clamp(0.0, 1.0);
    final ny = (d.localPosition.dy / size.height).clamp(0.0, 1.0);
    final norm = Offset(nx, ny);

    CropQuad next;

    switch (_dragging) {
    // ── Corner drags (free) ───────────────────────────────────────────────
      case _HandleType.cornerTL:
        next = _quad.copyWith(topLeft: norm);
      case _HandleType.cornerTR:
        next = _quad.copyWith(topRight: norm);
      case _HandleType.cornerBR:
        next = _quad.copyWith(bottomRight: norm);
      case _HandleType.cornerBL:
        next = _quad.copyWith(bottomLeft: norm);

    // ── Edge drags (move both corners of that edge by delta) ──────────────
      case _HandleType.edgeTop:
      // Only Y delta — keeps horizontal positions, shifts both top corners
        final dy = d.delta.dy / size.height;
        next = _quad.copyWith(
          topLeft:  Offset(_quad.topLeft.dx,  (_quad.topLeft.dy  + dy).clamp(0,1)),
          topRight: Offset(_quad.topRight.dx, (_quad.topRight.dy + dy).clamp(0,1)),
        );
      case _HandleType.edgeBottom:
        final dy = d.delta.dy / size.height;
        next = _quad.copyWith(
          bottomLeft:  Offset(_quad.bottomLeft.dx,  (_quad.bottomLeft.dy  + dy).clamp(0,1)),
          bottomRight: Offset(_quad.bottomRight.dx, (_quad.bottomRight.dy + dy).clamp(0,1)),
        );
      case _HandleType.edgeLeft:
        final dx = d.delta.dx / size.width;
        next = _quad.copyWith(
          topLeft:    Offset((_quad.topLeft.dx   + dx).clamp(0,1), _quad.topLeft.dy),
          bottomLeft: Offset((_quad.bottomLeft.dx + dx).clamp(0,1), _quad.bottomLeft.dy),
        );
      case _HandleType.edgeRight:
        final dx = d.delta.dx / size.width;
        next = _quad.copyWith(
          topRight:    Offset((_quad.topRight.dx   + dx).clamp(0,1), _quad.topRight.dy),
          bottomRight: Offset((_quad.bottomRight.dx + dx).clamp(0,1), _quad.bottomRight.dy),
        );

      default:
        return;
    }

    setState(() => _quad = next);
    widget.onQuadChanged(next);
  }

  void _onPanEnd(DragEndDetails _) =>
      setState(() => _dragging = _HandleType.none);

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, constraints) {
      final size = constraints.biggest;
      return GestureDetector(
        onPanStart:  (d) => _onPanStart(d, size),
        onPanUpdate: (d) => _onPanUpdate(d, size),
        onPanEnd:    _onPanEnd,
        child: CustomPaint(
          painter: _CropPainter(quad: _quad, dragging: _dragging),
          size: size,
        ),
      );
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Painter
// ─────────────────────────────────────────────────────────────────────────────

class _CropPainter extends CustomPainter {
  final CropQuad quad;
  final _HandleType dragging;

  static const _green  = Color(0xFF00E676);
  static const _white  = Colors.white;

  const _CropPainter({required this.quad, required this.dragging});

  // Corner L-bracket arm length
  static const _arm = 22.0;
  // Corner stroke width
  static const _cornerSW = 3.5;
  // Edge handle radius
  static const _edgeR = 9.0;
  // Border stroke
  static const _borderSW = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final c = quad.corners
        .map((n) => Offset(n.dx * size.width, n.dy * size.height))
        .toList();
    // c[0]=TL  c[1]=TR  c[2]=BR  c[3]=BL

    // ── Dim mask outside quad ─────────────────────────────────────────────
    final qPath = Path()..addPolygon(c, true);
    canvas.drawPath(
      Path.combine(PathOperation.difference,
          Path()..addRect(Offset.zero & size), qPath),
      Paint()..color = Colors.black.withOpacity(0.50),
    );

    // ── Quad border (thin, slightly transparent) ──────────────────────────
    canvas.drawPath(
        qPath,
        Paint()
          ..color = _green.withOpacity(0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = _borderSW);

    // ── Rule-of-thirds grid ───────────────────────────────────────────────
    _drawGrid(canvas, c);

    // ── Corner L-brackets ─────────────────────────────────────────────────
    _drawCornerBracket(canvas, c[0], c[1], c[3], dragging == _HandleType.cornerTL); // TL
    _drawCornerBracket(canvas, c[1], c[0], c[2], dragging == _HandleType.cornerTR); // TR
    _drawCornerBracket(canvas, c[2], c[3], c[1], dragging == _HandleType.cornerBR); // BR
    _drawCornerBracket(canvas, c[3], c[2], c[0], dragging == _HandleType.cornerBL); // BL

    // ── Edge midpoint handles ─────────────────────────────────────────────
    final midTop    = _lerp(c[0], c[1], 0.5);
    final midBottom = _lerp(c[3], c[2], 0.5);
    final midLeft   = _lerp(c[0], c[3], 0.5);
    final midRight  = _lerp(c[1], c[2], 0.5);

    _drawEdgeHandle(canvas, midTop,    dragging == _HandleType.edgeTop,    vertical: true);
    _drawEdgeHandle(canvas, midBottom, dragging == _HandleType.edgeBottom,  vertical: true);
    _drawEdgeHandle(canvas, midLeft,   dragging == _HandleType.edgeLeft,   vertical: false);
    _drawEdgeHandle(canvas, midRight,  dragging == _HandleType.edgeRight,  vertical: false);
  }

  // ── Corner bracket ────────────────────────────────────────────────────────
  //
  // Draws an L-shaped bracket at [corner], with arms pointing toward
  // [adjH] (horizontal neighbour) and [adjV] (vertical neighbour).
  void _drawCornerBracket(
      Canvas canvas, Offset corner, Offset adjH, Offset adjV, bool active) {
    final color = active ? _white : _green;
    final paint = Paint()
      ..color       = color
      ..style       = PaintingStyle.stroke
      ..strokeWidth = _cornerSW
      ..strokeCap   = StrokeCap.round
      ..strokeJoin  = StrokeJoin.round;

    // Unit vectors toward each adjacent corner
    Offset unit(Offset from, Offset to) {
      final d = to - from;
      final len = d.distance;
      return len == 0 ? Offset.zero : d / len;
    }

    final toH = unit(corner, adjH) * _arm;
    final toV = unit(corner, adjV) * _arm;

    final path = Path()
      ..moveTo(corner.dx + toH.dx, corner.dy + toH.dy)
      ..lineTo(corner.dx,          corner.dy)
      ..lineTo(corner.dx + toV.dx, corner.dy + toV.dy);

    canvas.drawPath(path, paint);

    // Small filled dot at the corner centre
    canvas.drawCircle(corner, active ? 5.0 : 3.5,
        Paint()..color = color);
  }

  // ── Edge midpoint handle ──────────────────────────────────────────────────
  //
  // A small pill/bar shape aligned along the edge direction.
  void _drawEdgeHandle(Canvas canvas, Offset mid, bool active,
      {required bool vertical}) {
    final color  = active ? _white : _green.withOpacity(0.85);
    final radius = active ? _edgeR + 2.0 : _edgeR;

    // Pill background
    canvas.drawCircle(mid, radius,
        Paint()..color = Colors.black.withOpacity(0.35));

    // Border ring
    canvas.drawCircle(mid, radius,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0);

    // Directional arrows (two small chevrons)
    final arrowPaint = Paint()
      ..color       = color
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap   = StrokeCap.round;

    const aw = 4.0; // arrow half-width
    const ah = 3.5; // arrow depth

    if (vertical) {
      // Up arrow
      canvas.drawLine(Offset(mid.dx - aw, mid.dy - 2),
          Offset(mid.dx,       mid.dy - 2 - ah), arrowPaint);
      canvas.drawLine(Offset(mid.dx + aw, mid.dy - 2),
          Offset(mid.dx,       mid.dy - 2 - ah), arrowPaint);
      // Down arrow
      canvas.drawLine(Offset(mid.dx - aw, mid.dy + 2),
          Offset(mid.dx,       mid.dy + 2 + ah), arrowPaint);
      canvas.drawLine(Offset(mid.dx + aw, mid.dy + 2),
          Offset(mid.dx,       mid.dy + 2 + ah), arrowPaint);
    } else {
      // Left arrow
      canvas.drawLine(Offset(mid.dx - 2, mid.dy - aw),
          Offset(mid.dx - 2 - ah, mid.dy), arrowPaint);
      canvas.drawLine(Offset(mid.dx - 2, mid.dy + aw),
          Offset(mid.dx - 2 - ah, mid.dy), arrowPaint);
      // Right arrow
      canvas.drawLine(Offset(mid.dx + 2, mid.dy - aw),
          Offset(mid.dx + 2 + ah, mid.dy), arrowPaint);
      canvas.drawLine(Offset(mid.dx + 2, mid.dy + aw),
          Offset(mid.dx + 2 + ah, mid.dy), arrowPaint);
    }
  }

  // ── Grid ──────────────────────────────────────────────────────────────────

  void _drawGrid(Canvas canvas, List<Offset> c) {
    final p = Paint()
      ..color       = _white.withOpacity(0.18)
      ..strokeWidth = 0.8;
    for (int i = 1; i <= 2; i++) {
      final t = i / 3.0;
      canvas.drawLine(_lerp(c[0], c[1], t), _lerp(c[3], c[2], t), p);
      canvas.drawLine(_lerp(c[0], c[3], t), _lerp(c[1], c[2], t), p);
    }
  }

  Offset _lerp(Offset a, Offset b, double t) => Offset.lerp(a, b, t)!;

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.quad != quad || old.dragging != dragging;
}