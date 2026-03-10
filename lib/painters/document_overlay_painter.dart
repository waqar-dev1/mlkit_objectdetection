import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

/// Paints ML Kit bounding boxes correctly over a [CameraPreview] widget.
///
/// Coordinate pipeline:
///   ML Kit bbox  →  (rotate if needed)  →  scale to canvas  →  mirror if front cam
///
/// Key insight: ML Kit returns coordinates in the *rotated* image space
/// (i.e. after applying [InputImageRotation]).  On a portrait Android device
/// the sensor delivers landscape frames (e.g. 1280×720) but ML Kit already
/// rotates them, so the logical image size we should scale against is
/// 720×1280 — height and width are swapped.
class DocumentOverlayPainter extends CustomPainter {
  final List<DetectedObject> detectedObjects;

  /// Raw sensor frame size (width × height) as delivered by CameraImage.
  final Size absoluteImageSize;

  /// The rotation that was applied when building the InputImage.
  final InputImageRotation rotation;

  final bool isFrontCamera;

  DocumentOverlayPainter({
    required this.detectedObjects,
    required this.absoluteImageSize,
    required this.rotation,
    this.isFrontCamera = false,
  });

  @override
  void paint(Canvas canvas, Size canvasSize) {
    if (detectedObjects.isEmpty) return;

    for (final object in detectedObjects) {
      final rect = _translateRect(object.boundingBox, canvasSize);
      final confidence = _maxConfidence(object);
      _drawOverlay(canvas, rect, confidence >= 0.7, confidence);
    }
  }

  /// Translates a ML Kit bounding box to canvas coordinates.
  Rect _translateRect(Rect bbox, Size canvasSize) {
    // After rotation ML Kit's logical image dimensions may be swapped.
    final double imageW;
    final double imageH;

    switch (rotation) {
      case InputImageRotation.rotation90deg:
      case InputImageRotation.rotation270deg:
      // Sensor is landscape, device is portrait → swap
        imageW = absoluteImageSize.height;
        imageH = absoluteImageSize.width;
        break;
      default:
        imageW = absoluteImageSize.width;
        imageH = absoluteImageSize.height;
    }

    final double scaleX = canvasSize.width / imageW;
    final double scaleY = canvasSize.height / imageH;

    double left   = bbox.left   * scaleX;
    double top    = bbox.top    * scaleY;
    double right  = bbox.right  * scaleX;
    double bottom = bbox.bottom * scaleY;

    // Mirror horizontally for selfie camera
    if (isFrontCamera) {
      final l = canvasSize.width - right;
      final r = canvasSize.width - left;
      left  = l;
      right = r;
    }

    return Rect.fromLTRB(
      left.clamp(0, canvasSize.width),
      top.clamp(0, canvasSize.height),
      right.clamp(0, canvasSize.width),
      bottom.clamp(0, canvasSize.height),
    );
  }

  double _maxConfidence(DetectedObject object) {
    if (object.labels.isEmpty) return 0.5;
    return object.labels.map((l) => l.confidence).reduce((a, b) => a > b ? a : b);
  }

  // ── Drawing helpers ───────────────────────────────────────────────────────

  void _drawOverlay(Canvas canvas, Rect rect, bool highConf, double conf) {
    final color = highConf ? const Color(0xFF00E676) : const Color(0xFFFFAB40);

    // Tinted fill
    canvas.drawRect(rect, Paint()..color = color.withOpacity(0.10)..style = PaintingStyle.fill);

    // Dashed border
    _drawDashedBorder(canvas, rect, color);

    // Corner brackets
    _drawCorners(canvas, rect, color);

    // Confidence label
    _drawLabel(canvas, rect, conf, color);
  }

  void _drawDashedBorder(Canvas canvas, Rect rect, Color color) {
    final paint = Paint()
      ..color = color.withOpacity(0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final path = Path();
    _dash(path, rect.topLeft,     rect.topRight);
    _dash(path, rect.bottomLeft,  rect.bottomRight);
    _dash(path, rect.topLeft,     rect.bottomLeft);
    _dash(path, rect.topRight,    rect.bottomRight);
    canvas.drawPath(path, paint);
  }

  void _dash(Path path, Offset a, Offset b, {double on = 8, double off = 5}) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final len = (b - a).distance;
    if (len == 0) return;
    final ux = dx / len;
    final uy = dy / len;
    double d = 0;
    bool draw = true;
    while (d < len) {
      final seg = (draw ? on : off).clamp(0, len - d);
      if (draw) {
        path.moveTo(a.dx + ux * d,       a.dy + uy * d);
        path.lineTo(a.dx + ux * (d+seg), a.dy + uy * (d+seg));
      }
      d += seg;
      draw = !draw;
    }
  }

  void _drawCorners(Canvas canvas, Rect rect, Color color) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final cs = (rect.shortestSide * 0.15).clamp(12.0, 30.0);

    void corner(Offset a, Offset vertex, Offset b) {
      canvas.drawPath(Path()..moveTo(a.dx, a.dy)..lineTo(vertex.dx, vertex.dy)..lineTo(b.dx, b.dy), paint);
    }

    corner(Offset(rect.left,      rect.top + cs),    rect.topLeft,     Offset(rect.left + cs,  rect.top));
    corner(Offset(rect.right - cs, rect.top),         rect.topRight,    Offset(rect.right,      rect.top + cs));
    corner(Offset(rect.left,      rect.bottom - cs), rect.bottomLeft,  Offset(rect.left + cs,  rect.bottom));
    corner(Offset(rect.right - cs, rect.bottom),      rect.bottomRight, Offset(rect.right,      rect.bottom - cs));
  }

  void _drawLabel(Canvas canvas, Rect rect, double conf, Color color) {
    final text = '${(conf * 100).toStringAsFixed(0)}%';
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const px = 5.0;
    const py = 4.0;
    final bw = tp.width + px * 2;
    const bh = 11.0 + py * 2;
    final bx = rect.left;
    final by = (rect.top - bh - 3) < 0 ? rect.top + 3 : rect.top - bh - 3;

    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, bw, bh), const Radius.circular(4)),
      Paint()..color = color.withOpacity(0.88),
    );
    tp.paint(canvas, Offset(bx + px, by + py));
  }

  @override
  bool shouldRepaint(DocumentOverlayPainter old) =>
      old.detectedObjects != detectedObjects ||
          old.absoluteImageSize != absoluteImageSize ||
          old.rotation != rotation;
}