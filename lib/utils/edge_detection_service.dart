import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' show Offset;
import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import '../screens/providers/capture_session.dart';

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

CropQuad? _opencvPipeline(Uint8List bytes) {
  cv.Mat? original;
  cv.Mat? small;
  cv.Mat? grey;
  cv.Mat? filtered;

  try {
    original = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (original.isEmpty) return _inset(100, 100);

    final origW = original.cols.toDouble();
    final origH = original.rows.toDouble();
    if (origW < 4 || origH < 4) return _inset(origW, origH);

    // ── Scale down to at most 800px on the long side ──────────────────────
    // 800 > 640 gives more contour detail without a meaningful speed penalty.
    const maxSide = 800;
    final scale   = maxSide / math.max(origW, origH);
    final wW      = math.max(4, (origW * scale).round());
    final wH      = math.max(4, (origH * scale).round());
    small = cv.resize(original, (wW, wH));

    if (small.isEmpty || small.cols < 4 || small.rows < 4) {
      return _inset(origW, origH);
    }

    // Area bounds: document must cover 8%–92% of the working image.
    final minArea = wW * wH * 0.08;
    final maxArea = wW * wH * 0.92;

    // ── Pass A — HSV colour/brightness segmentation ───────────────────────
    final quadA = _passColorSegmentation(small, wW, wH, minArea, maxArea);
    if (quadA != null) {
      final result = _scaleQuad(quadA, origW / wW, origH / wH);
      if (_isPlausible(result, origW, origH)) {
        debugPrint('EdgeDetection ✓ Pass A (color): '
            'TL=(${result.topLeft.dx.toInt()},${result.topLeft.dy.toInt()}) '
            'BR=(${result.bottomRight.dx.toInt()},${result.bottomRight.dy.toInt()})');
        return result;
      }
      debugPrint('EdgeDetection: Pass A result failed plausibility');
    }

    // ── Shared pre-processing for Pass B & C ─────────────────────────────
    grey = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
    if (grey.isEmpty) return _inset(origW, origH);

    // bilateralFilter can occasionally return an empty mat; guard it.
    final bilateral = cv.bilateralFilter(grey, 9, 75, 75);
    filtered = bilateral.isEmpty ? grey : bilateral;

    _burnBorder(filtered, wW, wH, 0.04);

    // ── Pass B — adaptive Canny ───────────────────────────────────────────
    final quadB = _passCanny(filtered, wW, wH, minArea, maxArea);
    if (quadB != null) {
      final result = _scaleQuad(quadB, origW / wW, origH / wH);
      if (_isPlausible(result, origW, origH)) {
        debugPrint('EdgeDetection ✓ Pass B (canny): '
            'TL=(${result.topLeft.dx.toInt()},${result.topLeft.dy.toInt()}) '
            'BR=(${result.bottomRight.dx.toInt()},${result.bottomRight.dy.toInt()})');
        return result;
      }
      debugPrint('EdgeDetection: Pass B result failed plausibility');
    }

    // ── Pass C — Otsu bounding-box ────────────────────────────────────────
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
  } catch (e, st) {
    debugPrint('_opencvPipeline error: $e\n$st');
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pass A — HSV colour/brightness segmentation
// ─────────────────────────────────────────────────────────────────────────────

CropQuad? _passColorSegmentation(
    cv.Mat bgr, int wW, int wH, double minArea, double maxArea) {
  try {
    final hsv = cv.cvtColor(bgr, cv.COLOR_BGR2HSV);
    if (hsv.isEmpty) return null;

    // extractChannel returns a fully-owned independent Mat — safe across
    // GC boundaries, unlike the views returned by cv.split().
    final sChan = cv.extractChannel(hsv, 1); // Saturation
    final vChan = cv.extractChannel(hsv, 2); // Value / brightness

    if (sChan.isEmpty || vChan.isEmpty) {
      debugPrint('Pass A: empty channel after extractChannel');
      return null;
    }

    // Bright pixels (paper, even in slight shadow).
    final (_, maskV)    = cv.threshold(vChan, 100, 255, cv.THRESH_BINARY);
    // Low-saturation pixels (white/grey paper, not coloured background).
    final (_, maskSInv) = cv.threshold(sChan,  80, 255, cv.THRESH_BINARY_INV);

    if (maskV.isEmpty || maskSInv.isEmpty) {
      debugPrint('Pass A: empty mask after threshold');
      return null;
    }

    // Pixels that are BOTH bright AND low-saturation.
    final mask = cv.bitwiseAND(maskV, maskSInv);
    if (mask.isEmpty) return null;

    // Large close (25×25) bridges shadow gaps across paper creases.
    final bigKernel = cv.getStructuringElement(cv.MORPH_RECT, (25, 25));
    final closed    = cv.morphologyEx(mask, cv.MORPH_CLOSE, bigKernel);

    // Small open (7×7) removes table-highlight noise specks.
    final smallKernel = cv.getStructuringElement(cv.MORPH_RECT, (7, 7));
    final opened      = cv.morphologyEx(closed, cv.MORPH_OPEN, smallKernel);

    _burnBorder(opened, wW, wH, 0.04);

    debugPrint('colorSeg: ${wW}x$wH  minArea=${minArea.toInt()}  maxArea=${maxArea.toInt()}');

    final (contours, _) = cv.findContours(
        opened, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

    debugPrint('colorSeg: ${contours.length} contours');
    if (contours.isEmpty) return null;

    final sorted = contours.toList()
      ..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));

    debugPrint('colorSeg top areas: '
        '${sorted.take(3).map((c) => cv.contourArea(c).toInt()).toList()}');

    final candidates = sorted
        .where((c) {
      final a = cv.contourArea(c);
      return a >= minArea && a <= maxArea;
    })
        .toList();

    debugPrint('colorSeg: ${candidates.length} candidates');
    if (candidates.isEmpty) return null;

    return _bestQuadFromContour(
        candidates.first, wW, wH, minArea, maxArea, 'colorSeg');
  } catch (e) {
    debugPrint('Pass A error: $e');
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pass B — adaptive Canny edge detection
// ─────────────────────────────────────────────────────────────────────────────

CropQuad? _passCanny(
    cv.Mat filtered, int wW, int wH, double minArea, double maxArea) {
  try {
    // Use raw pixel data for the median — zero JNI calls per pixel.
    final median = _medianLuminanceFromData(filtered);
    final lo     = math.max(10.0,  median * 0.33);
    final hi     = math.min(250.0, median * 1.33);
    final edges  = cv.canny(filtered, lo, hi);

    if (edges.isEmpty) return null;

    debugPrint('Pass B: median=${median.toInt()}  lo=${lo.toInt()}  hi=${hi.toInt()}');

    final kernel  = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
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
    if (mask.isEmpty) return null;
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
        topLeft:     Offset(bbox.x.toDouble(),                     bbox.y.toDouble()),
        topRight:    Offset((bbox.x + bbox.width).toDouble(),      bbox.y.toDouble()),
        bottomRight: Offset((bbox.x + bbox.width).toDouble(),      (bbox.y + bbox.height).toDouble()),
        bottomLeft:  Offset(bbox.x.toDouble(),                     (bbox.y + bbox.height).toDouble()),
      );
    }
    return null;
  } catch (e) {
    debugPrint('Pass C error: $e');
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared quad finder (used by Pass B)
// ─────────────────────────────────────────────────────────────────────────────

CropQuad? _findBestQuad(
    cv.Mat mask, int wW, int wH,
    double minArea, double maxArea, String tag) {
  final (contours, _) = cv.findContours(
      mask, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

  debugPrint('$tag: ${contours.length} contours');
  if (contours.isEmpty) return null;

  final candidates = contours.toList()
      .where((c) {
    final a = cv.contourArea(c);
    return a >= minArea && a <= maxArea;
  })
      .toList()
    ..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));

  debugPrint('$tag: ${candidates.length} candidates');
  if (candidates.isEmpty) return null;

  // Try the top-5 candidates; return the first that yields a good quad.
  for (final contour in candidates.take(5)) {
    final q = _bestQuadFromContour(contour, wW, wH, minArea, maxArea, tag);
    if (q != null) return q;
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Extract the best quad from a single contour
// ─────────────────────────────────────────────────────────────────────────────

CropQuad? _bestQuadFromContour(
    cv.VecPoint contour, int wW, int wH,
    double minArea, double maxArea, String tag) {
  final peri = cv.arcLength(contour, true);
  if (peri < 1) return null;

  // Try increasingly relaxed epsilon values until we get a 4-point polygon.
  for (final eps in [0.02, 0.03, 0.04, 0.05, 0.07, 0.10]) {
    final approx = cv.approxPolyDP(contour, eps * peri, true);
    if (approx.length == 4) {
      final area = cv.contourArea(approx);
      if (area >= minArea && area <= maxArea) {
        final ordered = _orderPoints(approx.toList());
        debugPrint('$tag: 4-pt poly  eps=$eps  area=${area.toInt()}');
        return CropQuad(
          topLeft:     Offset(ordered[0].x.toDouble(), ordered[0].y.toDouble()),
          topRight:    Offset(ordered[1].x.toDouble(), ordered[1].y.toDouble()),
          bottomRight: Offset(ordered[2].x.toDouble(), ordered[2].y.toDouble()),
          bottomLeft:  Offset(ordered[3].x.toDouble(), ordered[3].y.toDouble()),
        );
      }
    }
  }

  // Bounding-rect fallback with a small padding to recover thresholded edges.
  final bbox = cv.boundingRect(contour);
  final padX = (wW * 0.01).round();
  final padY = (wH * 0.01).round();
  final x    = math.max(0,  bbox.x - padX);
  final y    = math.max(0,  bbox.y - padY);
  final x2   = math.min(wW, bbox.x + bbox.width  + padX);
  final y2   = math.min(wH, bbox.y + bbox.height + padY);
  debugPrint('$tag: bbox fallback  ($x,$y)→($x2,$y2)');
  return CropQuad(
    topLeft:     Offset(x.toDouble(),  y.toDouble()),
    topRight:    Offset(x2.toDouble(), y.toDouble()),
    bottomRight: Offset(x2.toDouble(), y2.toDouble()),
    bottomLeft:  Offset(x.toDouble(),  y2.toDouble()),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Paint black rectangles on the 4 borders of [mat] to prevent edge-of-frame
/// noise from being picked up as document corners.
void _burnBorder(cv.Mat mat, int w, int h, double ratio) {
  if (mat.isEmpty) return;
  final bx = math.max(1, (w * ratio).round());
  final by = math.max(1, (h * ratio).round());
  cv.rectangle(mat, cv.Rect(0,      0,          w,  by), cv.Scalar.black, thickness: -1);
  cv.rectangle(mat, cv.Rect(0,      h - by,     w,  by), cv.Scalar.black, thickness: -1);
  cv.rectangle(mat, cv.Rect(0,      0,          bx,  h), cv.Scalar.black, thickness: -1);
  cv.rectangle(mat, cv.Rect(w - bx, 0,          bx,  h), cv.Scalar.black, thickness: -1);
}

/// Compute median pixel value from the raw Uint8List — O(n) with zero per-pixel
/// JNI/FFI calls, unlike mat.at<int>(y, x) in a nested loop.
double _medianLuminanceFromData(cv.Mat grey) {
  try {
    final data  = grey.data;           // Uint8List view of the mat buffer
    final total = data.length;
    if (total == 0) return 127.0;

    final hist = List<int>.filled(256, 0);
    for (int i = 0; i < total; i++) {
      hist[data[i]]++;
    }

    final half = total ~/ 2;
    int cumul = 0;
    for (int i = 0; i < 256; i++) {
      cumul += hist[i];
      if (cumul >= half) return i.toDouble();
    }
    return 127.0;
  } catch (e) {
    debugPrint('_medianLuminanceFromData error: $e');
    return 127.0;
  }
}

/// Scale a quad from the working-image space back to the original-image space.
CropQuad _scaleQuad(CropQuad q, double sx, double sy) => CropQuad(
  topLeft:     Offset(q.topLeft.dx * sx,     q.topLeft.dy * sy),
  topRight:    Offset(q.topRight.dx * sx,    q.topRight.dy * sy),
  bottomRight: Offset(q.bottomRight.dx * sx, q.bottomRight.dy * sy),
  bottomLeft:  Offset(q.bottomLeft.dx * sx,  q.bottomLeft.dy * sy),
);

/// Order 4 points: [topLeft, topRight, bottomRight, bottomLeft].
///
/// Algorithm is rotation-robust:
///   • TL = point whose (x+y) is smallest
///   • BR = point whose (x+y) is largest
///   • TR = of the remaining two, the one with the larger x
///   • BL = the remaining point
List<cv.Point> _orderPoints(List<cv.Point> pts) {
  assert(pts.length == 4);

  // Sort by x + y to find TL (min) and BR (max).
  final bySum = List<cv.Point>.from(pts)
    ..sort((a, b) => (a.x + a.y).compareTo(b.x + b.y));

  final tl   = bySum.first;
  final br   = bySum.last;
  final rest = [bySum[1], bySum[2]];

  // Of the remaining two, the one with the larger x is TR, the other is BL.
  // This is rotation-robust unlike the (y-x) sort used previously.
  rest.sort((a, b) => a.x.compareTo(b.x));
  final bl = rest[0]; // smaller x → left side → bottom-left
  final tr = rest[1]; // larger  x → right side → top-right

  return [tl, tr, br, bl];
}

/// Returns true if the quad covers a plausible document area.
///
/// Thresholds are deliberately generous — it is better to let a slightly
/// wrong quad through (the user can adjust it manually) than to fall back
/// to the full-image inset.
bool _isPlausible(CropQuad q, double w, double h) {
  final xs = [q.topLeft.dx, q.topRight.dx, q.bottomRight.dx, q.bottomLeft.dx];
  final ys = [q.topLeft.dy, q.topRight.dy, q.bottomRight.dy, q.bottomLeft.dy];
  final bw = xs.reduce(math.max) - xs.reduce(math.min);
  final bh = ys.reduce(math.max) - ys.reduce(math.min);

  // Must cover at least 8% of each dimension,
  // and must not exceed 95% (leaves room for a thin visible border).
  return bw > w * 0.08 && bh > h * 0.08
      && bw < w * 0.95 && bh < h * 0.95;
}

/// Conservative inset quad when all detection passes fail.
CropQuad _inset(double w, double h, [double margin = 0.05]) => CropQuad(
  topLeft:     Offset(w * margin,       h * margin),
  topRight:    Offset(w * (1 - margin), h * margin),
  bottomRight: Offset(w * (1 - margin), h * (1 - margin)),
  bottomLeft:  Offset(w * margin,       h * (1 - margin)),
);