import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

class DocumentOverlayPainter extends CustomPainter {
  final List<DetectedObject> detectedObjects;
  final Size imageSize;
  final bool isFrontCamera;

  DocumentOverlayPainter({
    required this.detectedObjects,
    required this.imageSize,
    this.isFrontCamera = false,
  });

  @override
  void paint(Canvas canvas, Size canvasSize) {
    if (detectedObjects.isEmpty) return;

    final scaleX = canvasSize.width / imageSize.width;
    final scaleY = canvasSize.height / imageSize.height;

    for (final object in detectedObjects) {
      final boundingBox = object.boundingBox;

      // Scale the bounding box to the canvas size
      double left = boundingBox.left * scaleX;
      double top = boundingBox.top * scaleY;
      double right = boundingBox.right * scaleX;
      double bottom = boundingBox.bottom * scaleY;

      // Mirror horizontally for front camera
      if (isFrontCamera) {
        final mirroredLeft = canvasSize.width - right;
        final mirroredRight = canvasSize.width - left;
        left = mirroredLeft;
        right = mirroredRight;
      }

      // Clamp to canvas bounds
      left = left.clamp(0.0, canvasSize.width);
      top = top.clamp(0.0, canvasSize.height);
      right = right.clamp(0.0, canvasSize.width);
      bottom = bottom.clamp(0.0, canvasSize.height);

      final rect = Rect.fromLTRB(left, top, right, bottom);
      final confidence = _getConfidence(object);
      final isHighConfidence = confidence >= 0.7;

      _drawDocumentOverlay(canvas, rect, isHighConfidence, confidence);
    }
  }

  double _getConfidence(DetectedObject object) {
    if (object.labels.isEmpty) return 0.5;
    return object.labels
        .map((l) => l.confidence)
        .reduce((a, b) => a > b ? a : b);
  }

  void _drawDocumentOverlay(
    Canvas canvas,
    Rect rect,
    bool isHighConfidence,
    double confidence,
  ) {
    final color = isHighConfidence
        ? const Color(0xFF00E676) // bright green for high confidence
        : const Color(0xFFFFAB40); // amber for lower confidence

    // --- Semi-transparent fill ---
    final fillPaint = Paint()
      ..color = color.withOpacity(0.08)
      ..style = PaintingStyle.fill;
    canvas.drawRect(rect, fillPaint);

    // --- Dashed border ---
    _drawDashedBorder(canvas, rect, color);

    // --- Corner brackets ---
    _drawCornerBrackets(canvas, rect, color);

    // --- Confidence badge ---
    _drawConfidenceBadge(canvas, rect, confidence, color);
  }

  void _drawDashedBorder(Canvas canvas, Rect rect, Color color) {
    final borderPaint = Paint()
      ..color = color.withOpacity(0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    const dashWidth = 8.0;
    const dashSpace = 5.0;

    final path = Path();

    // Top edge
    _addDashedLine(
      path,
      Offset(rect.left, rect.top),
      Offset(rect.right, rect.top),
      dashWidth,
      dashSpace,
    );
    // Bottom edge
    _addDashedLine(
      path,
      Offset(rect.left, rect.bottom),
      Offset(rect.right, rect.bottom),
      dashWidth,
      dashSpace,
    );
    // Left edge
    _addDashedLine(
      path,
      Offset(rect.left, rect.top),
      Offset(rect.left, rect.bottom),
      dashWidth,
      dashSpace,
    );
    // Right edge
    _addDashedLine(
      path,
      Offset(rect.right, rect.top),
      Offset(rect.right, rect.bottom),
      dashWidth,
      dashSpace,
    );

    canvas.drawPath(path, borderPaint);
  }

  void _addDashedLine(
    Path path,
    Offset start,
    Offset end,
    double dashWidth,
    double dashSpace,
  ) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final length = (end - start).distance;
    if (length == 0) return;

    final unitX = dx / length;
    final unitY = dy / length;

    double distance = 0;
    bool drawing = true;

    while (distance < length) {
      final segLength =
          drawing ? dashWidth : dashSpace;
      final segEnd = (distance + segLength).clamp(0.0, length);

      if (drawing) {
        path.moveTo(
          start.dx + unitX * distance,
          start.dy + unitY * distance,
        );
        path.lineTo(
          start.dx + unitX * segEnd,
          start.dy + unitY * segEnd,
        );
      }

      distance += segLength;
      drawing = !drawing;
    }
  }

  void _drawCornerBrackets(Canvas canvas, Rect rect, Color color) {
    final bracketPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final cornerSize = (rect.shortestSide * 0.15).clamp(12.0, 32.0);

    final corners = [
      // Top-left
      [
        Offset(rect.left, rect.top + cornerSize),
        Offset(rect.left, rect.top),
        Offset(rect.left + cornerSize, rect.top),
      ],
      // Top-right
      [
        Offset(rect.right - cornerSize, rect.top),
        Offset(rect.right, rect.top),
        Offset(rect.right, rect.top + cornerSize),
      ],
      // Bottom-left
      [
        Offset(rect.left, rect.bottom - cornerSize),
        Offset(rect.left, rect.bottom),
        Offset(rect.left + cornerSize, rect.bottom),
      ],
      // Bottom-right
      [
        Offset(rect.right - cornerSize, rect.bottom),
        Offset(rect.right, rect.bottom),
        Offset(rect.right, rect.bottom - cornerSize),
      ],
    ];

    for (final corner in corners) {
      final path = Path()
        ..moveTo(corner[0].dx, corner[0].dy)
        ..lineTo(corner[1].dx, corner[1].dy)
        ..lineTo(corner[2].dx, corner[2].dy);
      canvas.drawPath(path, bracketPaint);
    }
  }

  void _drawConfidenceBadge(
    Canvas canvas,
    Rect rect,
    double confidence,
    Color color,
  ) {
    final label = '${(confidence * 100).toStringAsFixed(0)}%';
    const fontSize = 11.0;

    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const padding = 5.0;
    const badgeHeight = fontSize + padding * 2;
    final badgeWidth = textPainter.width + padding * 2 + 8;

    final badgeLeft = rect.left;
    final badgeTop = rect.top - badgeHeight - 4;

    // Keep badge within canvas bounds
    final safeTop = badgeTop < 0 ? rect.top + 4 : badgeTop;

    final badgeRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(badgeLeft, safeTop, badgeWidth, badgeHeight),
      const Radius.circular(4),
    );

    // Badge background
    canvas.drawRRect(
      badgeRect,
      Paint()..color = color.withOpacity(0.9),
    );

    // Badge text
    textPainter.paint(
      canvas,
      Offset(badgeLeft + padding + 4, safeTop + padding),
    );
  }

  @override
  bool shouldRepaint(DocumentOverlayPainter oldDelegate) {
    return oldDelegate.detectedObjects != detectedObjects ||
        oldDelegate.imageSize != imageSize;
  }
}
