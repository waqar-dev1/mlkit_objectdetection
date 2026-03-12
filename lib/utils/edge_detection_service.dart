import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' show Offset;
import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import '../screens/providers/capture_session.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

class EdgeDetectionService {
  static Future<CropQuad?> detectCorners(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      return await Isolate.run(() => _opencvPipeline(bytes));
    } catch (e) {
      debugPrint('EdgeDetectionService error: $e');
      return null;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main pipeline — three independent passes, first success wins
// ─────────────────────────────────────────────────────────────────────────────
//
// Pass A — Color/brightness segmentation (best for white paper on colored bg)
// Pass B — Canny edge detection          (best for dark paper or low contrast)
// Pass C — Otsu bounding box             (last resort)

CropQuad? _opencvPipeline(Uint8List bytes) {
  final original = cv.imdecode(bytes, cv.IMREAD_COLOR);
  if (original.isEmpty) return _inset(100, 100);

  final origW = original.cols.toDouble();
  final origH = original.rows.toDouble();

  // Downscale to ≤640 longest side
  const maxSide = 640;
  final scale = maxSide / math.max(origW, origH);
  final wW    = math.max(2, (origW * scale).round());
  final wH    = math.max(2, (origH * scale).round());
  final small = cv.resize(original, (wW, wH));

  final minArea = wW * wH * 0.10;
  final maxArea = wW * wH * 0.88; // tighter upper bound

  // ── Pass A: Color segmentation ────────────────────────────────────────────
  final quadA = _passColorSegmentation(small, wW, wH, minArea, maxArea);
  if (quadA != null) {
    final result = _scaleQuad(quadA, origW / wW, origH / wH);
    if (_isPlausible(result, origW, origH)) {
      debugPrint('EdgeDetection ✓ Pass A (color): '
          'TL=(${result.topLeft.dx.toInt()},${result.topLeft.dy.toInt()}) '
          'BR=(${result.bottomRight.dx.toInt()},${result.bottomRight.dy.toInt()})');
      return result;
    }
  }

  // ── Pass B: Canny edge detection ──────────────────────────────────────────
  final grey     = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
  final filtered = cv.bilateralFilter(grey, 9, 75, 75);
  _burnBorder(filtered, wW, wH, 0.04);

  final quadB = _passCanny(filtered, wW, wH, minArea, maxArea);
  if (quadB != null) {
    final result = _scaleQuad(quadB, origW / wW, origH / wH);
    if (_isPlausible(result, origW, origH)) {
      debugPrint('EdgeDetection ✓ Pass B (canny): '
          'TL=(${result.topLeft.dx.toInt()},${result.topLeft.dy.toInt()}) '
          'BR=(${result.bottomRight.dx.toInt()},${result.bottomRight.dy.toInt()})');
      return result;
    }
  }

  // ── Pass C: Otsu bounding box ─────────────────────────────────────────────
  final quadC = _passOtsu(filtered, wW, wH, maxArea);
  if (quadC != null) {
    final result = _scaleQuad(quadC, origW / wW, origH / wH);
    if (_isPlausible(result, origW, origH)) {
      debugPrint('EdgeDetection ✓ Pass C (otsu): '
          'TL=(${result.topLeft.dx.toInt()},${result.topLeft.dy.toInt()}) '
          'BR=(${result.bottomRight.dx.toInt()},${result.bottomRight.dy.toInt()})');
      return result;
    }
  }

  debugPrint('EdgeDetection: all passes failed → inset fallback');
  return _inset(origW, origH);
}

// ─────────────────────────────────────────────────────────────────────────────
// Pass A — Color / brightness segmentation
//
// Converts to HSV and isolates pixels that are:
//   • High Value   (bright)   — captures white/light paper
//   • Low Saturation          — paper is unsaturated; wood/table is saturated
//
// Then finds the largest contour in the combined mask and fits a quad to it.
// This is extremely reliable for white/light paper on any colored background.
// ─────────────────────────────────────────────────────────────────────────────

CropQuad? _passColorSegmentation(
    cv.Mat bgr, int wW, int wH, double minArea, double maxArea) {
  try {
    final hsv = cv.cvtColor(bgr, cv.COLOR_BGR2HSV);

    // Split HSV into channels — cv.split returns VecMat directly (not a tuple)
    final hsvChannels = cv.split(hsv); // VecMat: [H, S, V]
    final sChan = hsvChannels[1];      // Saturation
    final vChan = hsvChannels[2];      // Value (brightness)

    // Mask A: High brightness  (Value > 140)
    final (_, maskV) = cv.threshold(vChan, 140, 255, cv.THRESH_BINARY);

    // Mask B: Low saturation   (Saturation < 60)
    // Inverted threshold — keep pixels BELOW 60
    final (_, maskSInv) = cv.threshold(sChan, 60, 255, cv.THRESH_BINARY_INV);

    // Combined: must be BOTH bright AND low-saturation
    final mask = cv.bitwiseAND(maskV, maskSInv);

    // Morphological close to fill gaps inside the paper
    final kernel = cv.getStructuringElement(cv.MORPH_RECT, (15, 15));
    final closed = cv.morphologyEx(mask, cv.MORPH_CLOSE, kernel);

    // Also remove small noise
    final opened = cv.morphologyEx(closed, cv.MORPH_OPEN,
        cv.getStructuringElement(cv.MORPH_RECT, (5, 5)));

    _burnBorder(opened, wW, wH, 0.04);

    return _findBestQuad(opened, wW, wH, minArea, maxArea, 'colorSeg');
  } catch (e) {
    debugPrint('Pass A error: $e');
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pass B — Canny edge detection
// ─────────────────────────────────────────────────────────────────────────────

CropQuad? _passCanny(
    cv.Mat filtered, int wW, int wH, double minArea, double maxArea) {
  try {
    final median = _medianLuminance(filtered, wW, wH);
    final lo     = math.max(10.0,  median * 0.5);
    final hi     = math.min(200.0, median * 1.2);
    final edges  = cv.canny(filtered, lo, hi);

    debugPrint('Pass B: median=${median.toInt()} lo=${lo.toInt()} hi=${hi.toInt()}');

    final kernel  = cv.getStructuringElement(cv.MORPH_RECT, (7, 7));
    final dilated = cv.dilate(edges, kernel, iterations: 2);
    final closed  = cv.erode(dilated, kernel, iterations: 1);
    _burnBorder(closed, wW, wH, 0.04);

    return _findBestQuad(closed, wW, wH, minArea, maxArea, 'canny');
  } catch (e) {
    debugPrint('Pass B error: $e');
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pass C — Otsu bounding box
// ─────────────────────────────────────────────────────────────────────────────

CropQuad? _passOtsu(cv.Mat filtered, int wW, int wH, double maxArea) {
  try {
    final (_, mask) = cv.threshold(
        filtered, 0, 255, cv.THRESH_BINARY | cv.THRESH_OTSU);
    _burnBorder(mask, wW, wH, 0.04);

    final (contours, _) = cv.findContours(
        mask, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

    if (contours.isEmpty) return null;

    final sorted = contours.toList()
      ..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));

    for (final c in sorted) {
      final area = cv.contourArea(c);
      if (area > maxArea) continue;
      final bbox = cv.boundingRect(c);
      return CropQuad(
        topLeft:     Offset(bbox.x.toDouble(),              bbox.y.toDouble()),
        topRight:    Offset((bbox.x + bbox.width).toDouble(), bbox.y.toDouble()),
        bottomRight: Offset((bbox.x + bbox.width).toDouble(), (bbox.y + bbox.height).toDouble()),
        bottomLeft:  Offset(bbox.x.toDouble(),              (bbox.y + bbox.height).toDouble()),
      );
    }
    return null;
  } catch (e) {
    debugPrint('Pass C error: $e');
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared: find best quad from a binary mask
// ─────────────────────────────────────────────────────────────────────────────

CropQuad? _findBestQuad(
    cv.Mat mask, int wW, int wH,
    double minArea, double maxArea, String tag) {
  final (contours, _) = cv.findContours(
      mask, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

  debugPrint('$tag: ${contours.length} contours');

  if (contours.isEmpty) return null;

  final candidates = contours.toList().where((c) {
    final a = cv.contourArea(c);
    return a >= minArea && a <= maxArea;
  }).toList()
    ..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));

  debugPrint('$tag: ${candidates.length} candidates (minArea=${minArea.toInt()})');

  // Try approxPolyDP to get exact 4-point quad
  for (final contour in candidates.take(5)) {
    final peri = cv.arcLength(contour, true);
    for (final eps in [0.02, 0.03, 0.04, 0.05, 0.07, 0.10]) {
      final approx = cv.approxPolyDP(contour, eps * peri, true);
      if (approx.length == 4) {
        final area = cv.contourArea(approx);
        if (area >= minArea && area <= maxArea) {
          debugPrint('$tag: 4-point poly eps=$eps area=${area.toInt()}');
          final pts     = approx.toList();
          final ordered = _orderPoints(pts);
          return CropQuad(
            topLeft:     Offset(ordered[0].x.toDouble(), ordered[0].y.toDouble()),
            topRight:    Offset(ordered[1].x.toDouble(), ordered[1].y.toDouble()),
            bottomRight: Offset(ordered[2].x.toDouble(), ordered[2].y.toDouble()),
            bottomLeft:  Offset(ordered[3].x.toDouble(), ordered[3].y.toDouble()),
          );
        }
      }
    }
  }

  // Fallback: bounding rect of largest candidate
  if (candidates.isNotEmpty) {
    final bbox = cv.boundingRect(candidates.first);
    debugPrint('$tag: falling back to bounding rect');
    return CropQuad(
      topLeft:     Offset(bbox.x.toDouble(),              bbox.y.toDouble()),
      topRight:    Offset((bbox.x + bbox.width).toDouble(), bbox.y.toDouble()),
      bottomRight: Offset((bbox.x + bbox.width).toDouble(), (bbox.y + bbox.height).toDouble()),
      bottomLeft:  Offset(bbox.x.toDouble(),              (bbox.y + bbox.height).toDouble()),
    );
  }

  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Burn a solid black border (ratio of each side) onto mat in-place.
void _burnBorder(cv.Mat mat, int w, int h, double ratio) {
  final bx = (w * ratio).round();
  final by = (h * ratio).round();
  cv.rectangle(mat, cv.Rect(0,      0,      w,  by), cv.Scalar.black, thickness: -1);
  cv.rectangle(mat, cv.Rect(0,  h - by,     w,  by), cv.Scalar.black, thickness: -1);
  cv.rectangle(mat, cv.Rect(0,      0,      bx,  h), cv.Scalar.black, thickness: -1);
  cv.rectangle(mat, cv.Rect(w - bx, 0,      bx,  h), cv.Scalar.black, thickness: -1);
}

/// Median luminance for sigma-based Canny thresholds.
double _medianLuminance(cv.Mat grey, int w, int h) {
  final hist  = List<int>.filled(256, 0);
  final total = w * h;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      hist[grey.at<int>(y, x)]++;
    }
  }
  int cumul = 0;
  for (int i = 0; i < 256; i++) {
    cumul += hist[i];
    if (cumul >= total ~/ 2) return i.toDouble();
  }
  return 127.0;
}

/// Scale a quad from working-image space to original-image space.
CropQuad _scaleQuad(CropQuad q, double sx, double sy) => CropQuad(
  topLeft:     Offset(q.topLeft.dx * sx,     q.topLeft.dy * sy),
  topRight:    Offset(q.topRight.dx * sx,    q.topRight.dy * sy),
  bottomRight: Offset(q.bottomRight.dx * sx, q.bottomRight.dy * sy),
  bottomLeft:  Offset(q.bottomLeft.dx * sx,  q.bottomLeft.dy * sy),
);

/// Orders 4 OpenCV points as TL → TR → BR → BL.
List<cv.Point> _orderPoints(List<cv.Point> pts) {
  final sorted = List<cv.Point>.from(pts)
    ..sort((a, b) => (a.x + a.y).compareTo(b.x + b.y));
  final tl   = sorted[0];
  final rest = [sorted[1], sorted[2]]
    ..sort((a, b) => (a.y - a.x).compareTo(b.y - b.x));
  final tr = rest[0];
  final bl = rest[1];
  final br = sorted[3];
  return [tl, tr, br, bl];
}

/// Result must cover 10%–88% of image in both axes.
bool _isPlausible(CropQuad q, double w, double h) {
  final xs = [q.topLeft.dx, q.topRight.dx, q.bottomRight.dx, q.bottomLeft.dx];
  final ys = [q.topLeft.dy, q.topRight.dy, q.bottomRight.dy, q.bottomLeft.dy];
  final bw = xs.reduce(math.max) - xs.reduce(math.min);
  final bh = ys.reduce(math.max) - ys.reduce(math.min);
  return bw > w * 0.10 && bh > h * 0.10
      && bw < w * 0.88 && bh < h * 0.88;
}

CropQuad _inset(double w, double h, [double margin = 0.05]) => CropQuad(
  topLeft:     Offset(w * margin,       h * margin),
  topRight:    Offset(w * (1 - margin), h * margin),
  bottomRight: Offset(w * (1 - margin), h * (1 - margin)),
  bottomLeft:  Offset(w * margin,       h * (1 - margin)),
);