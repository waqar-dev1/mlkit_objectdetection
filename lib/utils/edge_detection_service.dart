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

/// OpenCV-based document corner detector.
///
/// Full pipeline (runs in a background isolate — zero UI thread impact):
///
///   1.  Decode JPEG/PNG bytes with cv.imdecode
///   2.  Downscale to ≤800 px longest side (speed + noise reduction)
///   3.  Convert BGR → Grayscale
///   4.  CLAHE (Contrast Limited Adaptive Histogram Equalisation)
///       → dramatically improves edge visibility on dark/washed-out shots
///   5.  GaussianBlur (5×5, σ=0) to suppress JPEG compression artefacts
///   6.  Canny edge detection (auto-thresholds via Otsu on blurred image)
///   7.  Morphological close (dilate × 2 → erode × 2, 5×5 kernel)
///       → bridges gaps in document outlines
///   8.  findContours (RETR_EXTERNAL, CHAIN_APPROX_SIMPLE)
///   9.  Sort contours by area descending, inspect top-10
///  10.  approxPolyDP (ε = 2 % of arc length) on each candidate
///  11.  Accept first contour that approximates to exactly 4 points
///       and covers ≥ 15 % of image area (avoids tiny noise quads)
///  12.  If no 4-point contour found: convexHull of largest contour
///       then approxPolyDP again (handles partially occluded documents)
///  13.  Order the 4 points as TL→TR→BR→BL
///  14.  Scale back to original image pixel coordinates
///  15.  Plausibility check — fall back to Otsu bright-blob if needed
///  16.  Final fallback: 5% inset quad
class EdgeDetectionService {
  static Future<CropQuad?> detectCorners(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      // Run entirely in a separate isolate — never blocks the UI thread
      return await Isolate.run(() => _opencvPipeline(bytes));
    } catch (e) {
      debugPrint('EdgeDetectionService: $e');
      return null;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main pipeline (runs in isolate)
// ─────────────────────────────────────────────────────────────────────────────

CropQuad? _opencvPipeline(Uint8List bytes) {
  // ── 1. Decode ──────────────────────────────────────────────────────────────
  final original = cv.imdecode(bytes, cv.IMREAD_COLOR);
  if (original.isEmpty) return null;

  final origH = original.rows.toDouble();
  final origW = original.cols.toDouble();

  // ── 2. Downscale to ≤800 px longest side ──────────────────────────────────
  const maxSide = 800;
  final scale   = maxSide / math.max(origW, origH);
  final wW      = (origW * scale).round();
  final wH      = (origH * scale).round();

  final small = cv.resize(original, (wW, wH));

  // ── 3. Grayscale ───────────────────────────────────────────────────────────
  final grey = cv.cvtColor(small, cv.COLOR_BGR2GRAY);

  // ── 4. CLAHE — boosts local contrast before edge detection ────────────────
  //   clipLimit=2.0, tileGridSize=8×8 (standard document scanner values)
  final clahe     = cv.createCLAHE(clipLimit: 2.0, tileGridSize: (8, 8));
  final equalised = clahe.apply(grey);

  // ── 5. Gaussian blur ───────────────────────────────────────────────────────
  final blurred = cv.gaussianBlur(equalised, (5, 5), 0);

  // ── 6. Auto-threshold Canny ────────────────────────────────────────────────
  //   Derive Canny thresholds from Otsu on the blurred image so they adapt
  //   to each photo's contrast range automatically.
  final (otsuThresh, _) = cv.threshold(
      blurred, 0, 255, cv.THRESH_BINARY | cv.THRESH_OTSU);
  final lo    = otsuThresh * 0.5;  // hysteresis low  = 0.5 × Otsu
  final hi    = otsuThresh;        // hysteresis high = Otsu
  final edges = cv.canny(blurred, lo, hi);

  // ── 7. Morphological close — bridge gaps in document outline ──────────────
  final kernel  = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
  final dilated = cv.dilate(edges, kernel, iterations: 2);
  final closed  = cv.erode(dilated, kernel, iterations: 2);

  // ── 8. Find external contours ─────────────────────────────────────────────
  final (contours, _) = cv.findContours(
      closed, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

  if (contours.isEmpty) {
    debugPrint('EdgeDetection: no contours found');
    return _otsuFallback(bytes, origW, origH);
  }

  // ── 9. Sort by area descending, inspect top 10 ────────────────────────────
  final minArea  = wW * wH * 0.15;  // must cover ≥ 15% of working image
  final sorted   = contours.toList()
    ..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));
  final topN     = sorted.take(10).toList();

  // ── 10–11. approxPolyDP — find the first 4-point contour ──────────────────
  cv.VecPoint? quad4;

  for (final contour in topN) {
    final area = cv.contourArea(contour);
    if (area < minArea) continue;

    final peri   = cv.arcLength(contour, true);
    final approx = cv.approxPolyDP(contour, 0.02 * peri, true);

    if (approx.length == 4) {
      quad4 = approx;
      debugPrint('EdgeDetection ✓ 4-point contour (area=${area.toInt()})');
      break;
    }
  }

  // ── 12. Fallback: convexHull of largest contour → approxPolyDP ────────────
  if (quad4 == null && topN.isNotEmpty) {
    final largest = topN.first;

    // convexHull returns a Mat of points — extract into a VecPoint manually
    final hullMat = cv.convexHull(largest, returnPoints: true);

    final hullPoints = <cv.Point>[];
    for (int i = 0; i < hullMat.rows; i++) {
      final px = hullMat.at<int>(i, 0);
      final py = hullMat.at<int>(i, 1);
      hullPoints.add(cv.Point(px, py));
    }
    final hullVec = cv.VecPoint.fromList(hullPoints);

    final peri = cv.arcLength(hullVec, true);

    for (final eps in [0.02, 0.04, 0.06, 0.08, 0.10]) {
      final approx = cv.approxPolyDP(hullVec, eps * peri, true);
      if (approx.length == 4) {
        quad4 = approx;
        debugPrint('EdgeDetection ✓ hull fallback (eps=$eps)');
        break;
      }
    }
  }

  // ── 13. Order 4 points TL → TR → BR → BL ─────────────────────────────────
  if (quad4 != null && quad4.length == 4) {
    final pts     = quad4.toList();
    final ordered = _orderPoints(pts);

    // ── 14. Scale back to original coords ─────────────────────────────────
    final sx = origW / wW;
    final sy = origH / wH;

    final result = CropQuad(
      topLeft:     Offset(ordered[0].x * sx, ordered[0].y * sy),
      topRight:    Offset(ordered[1].x * sx, ordered[1].y * sy),
      bottomRight: Offset(ordered[2].x * sx, ordered[2].y * sy),
      bottomLeft:  Offset(ordered[3].x * sx, ordered[3].y * sy),
    );

    // ── 15. Plausibility check ─────────────────────────────────────────────
    if (_isPlausible(result, origW, origH)) {
      debugPrint('EdgeDetection final: '
          'TL=(${result.topLeft.dx.toInt()},${result.topLeft.dy.toInt()}) '
          'TR=(${result.topRight.dx.toInt()},${result.topRight.dy.toInt()}) '
          'BR=(${result.bottomRight.dx.toInt()},${result.bottomRight.dy.toInt()}) '
          'BL=(${result.bottomLeft.dx.toInt()},${result.bottomLeft.dy.toInt()})');
      return result;
    }
    debugPrint('EdgeDetection: failed plausibility check');
  }

  // ── 16. Final fallback ─────────────────────────────────────────────────────
  debugPrint('EdgeDetection: all passes failed → Otsu fallback');
  return _otsuFallback(bytes, origW, origH);
}

// ─────────────────────────────────────────────────────────────────────────────
// Point ordering — TL, TR, BR, BL
// ─────────────────────────────────────────────────────────────────────────────

/// Orders 4 points as: topLeft, topRight, bottomRight, bottomLeft.
///
/// Algorithm:
///   • Sort by (x+y): smallest = TL, largest = BR
///   • Sort remainder by (y-x): smallest = TR, largest = BL
List<cv.Point> _orderPoints(List<cv.Point> pts) {
  // Sum x+y
  pts.sort((a, b) => (a.x + a.y).compareTo(b.x + b.y));
  final tl = pts[0];
  final br = pts[3];

  // Difference y-x for the remaining two
  final rest = [pts[1], pts[2]];
  rest.sort((a, b) => (a.y - a.x).compareTo(b.y - b.x));
  final tr = rest[0];
  final bl = rest[1];

  return [tl, tr, br, bl];
}

// ─────────────────────────────────────────────────────────────────────────────
// Plausibility check
// ─────────────────────────────────────────────────────────────────────────────

bool _isPlausible(CropQuad q, double w, double h) {
  // Compute bounding box of the quad
  final xs = [q.topLeft.dx, q.topRight.dx, q.bottomRight.dx, q.bottomLeft.dx];
  final ys = [q.topLeft.dy, q.topRight.dy, q.bottomRight.dy, q.bottomLeft.dy];
  final bw = xs.reduce(math.max) - xs.reduce(math.min);
  final bh = ys.reduce(math.max) - ys.reduce(math.min);

  // Must cover at least 15% and not exceed 99% in both dimensions
  return bw > w * 0.15 && bh > h * 0.15
      && bw < w * 0.99 && bh < h * 0.99;
}

// ─────────────────────────────────────────────────────────────────────────────
// Otsu bright-blob fallback (pure Dart — no OpenCV needed here)
// ─────────────────────────────────────────────────────────────────────────────

CropQuad _otsuFallback(Uint8List bytes, double origW, double origH) {
  try {
    // Re-use the already-decoded bytes — decode to grayscale
    final grey = cv.imdecode(bytes, cv.IMREAD_GRAYSCALE);

    // Downscale for speed
    const maxSide = 400;
    final sc  = maxSide / math.max(origW, origH);
    final wW  = (origW * sc).round();
    final wH  = (origH * sc).round();
    final small = cv.resize(grey, (wW, wH));

    // Otsu threshold
    final (_, mask) = cv.threshold(
        small, 0, 255, cv.THRESH_BINARY | cv.THRESH_OTSU);

    // Border exclusion — zero a 4% strip
    final bx = (wW * 0.04).round();
    final by = (wH * 0.04).round();
    cv.rectangle(mask, cv.Rect(0, 0, wW, by),     cv.Scalar.black, thickness: -1);
    cv.rectangle(mask, cv.Rect(0, wH-by, wW, by), cv.Scalar.black, thickness: -1);
    cv.rectangle(mask, cv.Rect(0, 0, bx, wH),     cv.Scalar.black, thickness: -1);
    cv.rectangle(mask, cv.Rect(wW-bx, 0, bx, wH), cv.Scalar.black, thickness: -1);

    final (contours, _) = cv.findContours(
        mask, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

    if (contours.isNotEmpty) {
      final sorted  = contours.toList()
        ..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));
      final bbox    = cv.boundingRect(sorted.first);

      final sx = origW / wW;
      final sy = origH / wH;

      final quad = CropQuad(
        topLeft:     Offset(bbox.x * sx,              bbox.y * sy),
        topRight:    Offset((bbox.x + bbox.width) * sx, bbox.y * sy),
        bottomRight: Offset((bbox.x + bbox.width) * sx, (bbox.y + bbox.height) * sy),
        bottomLeft:  Offset(bbox.x * sx,              (bbox.y + bbox.height) * sy),
      );

      if (_isPlausible(quad, origW, origH)) {
        debugPrint('EdgeDetection: Otsu fallback succeeded');
        return quad;
      }
    }
  } catch (e) {
    debugPrint('EdgeDetection: Otsu fallback error — $e');
  }

  debugPrint('EdgeDetection: using final inset fallback');
  return _inset(origW, origH);
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

CropQuad _inset(double w, double h, [double margin = 0.05]) => CropQuad(
  topLeft:     Offset(w * margin,       h * margin),
  topRight:    Offset(w * (1 - margin), h * margin),
  bottomRight: Offset(w * (1 - margin), h * (1 - margin)),
  bottomLeft:  Offset(w * margin,       h * (1 - margin)),
);