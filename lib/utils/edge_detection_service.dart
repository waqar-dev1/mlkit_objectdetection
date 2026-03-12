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
// Main pipeline
// ─────────────────────────────────────────────────────────────────────────────

CropQuad? _opencvPipeline(Uint8List bytes) {
  // ── 1. Decode original ────────────────────────────────────────────────────
  final original = cv.imdecode(bytes, cv.IMREAD_COLOR);
  if (original.isEmpty) return _inset(100, 100);

  final origW = original.cols.toDouble();
  final origH = original.rows.toDouble();

  // ── 2. Downscale to ≤640 px longest side ─────────────────────────────────
  // 640 is enough for contour detection — smaller = faster + less noise
  const maxSide = 640;
  final scale = maxSide / math.max(origW, origH);
  final wW = math.max(2, (origW * scale).round());
  final wH = math.max(2, (origH * scale).round());
  final small = cv.resize(original, (wW, wH));

  // ── 3. Grayscale ──────────────────────────────────────────────────────────
  final grey = cv.cvtColor(small, cv.COLOR_BGR2GRAY);

  // ── 4. Bilateral filter — reduces noise while PRESERVING hard edges ───────
  // This is better than Gaussian for document detection because it keeps
  // the paper boundary sharp while smoothing internal texture.
  // d=9, sigmaColor=75, sigmaSpace=75  (standard values)
  final filtered = cv.bilateralFilter(grey, 9, 75, 75);

  // ── 5. Burn a black border (5%) onto the filtered image ───────────────────
  // This definitively kills any frame-edge contours before Canny runs.
  final borderX = (wW * 0.05).round();
  final borderY = (wH * 0.05).round();
  cv.rectangle(filtered, cv.Rect(0, 0, wW, borderY),
      cv.Scalar.black, thickness: -1);
  cv.rectangle(filtered, cv.Rect(0, wH - borderY, wW, borderY),
      cv.Scalar.black, thickness: -1);
  cv.rectangle(filtered, cv.Rect(0, 0, borderX, wH),
      cv.Scalar.black, thickness: -1);
  cv.rectangle(filtered, cv.Rect(wW - borderX, 0, borderX, wH),
      cv.Scalar.black, thickness: -1);

  // ── 6. Canny with clamped, sensible thresholds ────────────────────────────
  // DO NOT use raw Otsu output as Canny thresholds — on a white paper Otsu
  // is very high (200+) which makes Canny miss the paper outline entirely.
  // Instead: compute median luminance and use the sigma method which is
  // robust across dark rooms, bright rooms, and everything in between.
  final median = _medianLuminance(filtered, wW, wH);
  final lo = math.max(10.0,  (1.0 - 0.33) * median);  // never below 10
  final hi = math.min(200.0, (1.0 + 0.33) * median);  // never above 200
  final edges = cv.canny(filtered, lo, hi);

  // ── 7. Morphological close — bridge gaps in the document outline ──────────
  // Use a larger 7×7 kernel + 2 iterations to firmly close corner gaps.
  final kernel  = cv.getStructuringElement(cv.MORPH_RECT, (7, 7));
  final dilated = cv.dilate(edges, kernel, iterations: 2);
  final closed  = cv.erode(dilated, kernel, iterations: 1);

  // ── 8. Also burn border on the closed edge map ────────────────────────────
  cv.rectangle(closed, cv.Rect(0, 0, wW, borderY),
      cv.Scalar.black, thickness: -1);
  cv.rectangle(closed, cv.Rect(0, wH - borderY, wW, borderY),
      cv.Scalar.black, thickness: -1);
  cv.rectangle(closed, cv.Rect(0, 0, borderX, wH),
      cv.Scalar.black, thickness: -1);
  cv.rectangle(closed, cv.Rect(wW - borderX, 0, borderX, wH),
      cv.Scalar.black, thickness: -1);

  // ── 9. Find external contours ─────────────────────────────────────────────
  final (contours, _) = cv.findContours(
      closed, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

  debugPrint('EdgeDetection: ${contours.length} contours found '
      '(image=${wW}x${wH}, median=$median lo=${lo.toInt()} hi=${hi.toInt()})');

  // ── 10. Score and rank contours ───────────────────────────────────────────
  // Score = area — but also PENALISE quads that are suspiciously close to
  // the image border (those are usually frame artefacts that slipped through)
  final minArea = wW * wH * 0.10; // ≥ 10% of working image
  final maxArea = wW * wH * 0.92; // ≤ 92% — must not be the full frame

  final candidates = contours.toList().where((c) {
    final a = cv.contourArea(c);
    return a >= minArea && a <= maxArea;
  }).toList()
    ..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));

  debugPrint('EdgeDetection: ${candidates.length} candidates after area filter');

  // ── 11. Try approxPolyDP on top candidates ────────────────────────────────
  cv.VecPoint? quad4;

  for (final contour in candidates.take(8)) {
    final peri = cv.arcLength(contour, true);

    // Try a range of epsilon values — stricter first, looser as fallback
    for (final eps in [0.02, 0.03, 0.04, 0.05]) {
      final approx = cv.approxPolyDP(contour, eps * peri, true);
      if (approx.length == 4) {
        quad4 = approx;
        debugPrint('EdgeDetection ✓ 4-point poly '
            '(eps=$eps area=${cv.contourArea(contour).toInt()})');
        break;
      }
    }
    if (quad4 != null) break;
  }

  // ── 12. Loose-epsilon fallback directly on the largest candidate ─────────
  // cv.convexHull in opencv_dart 2.x returns Mat, not VecPoint, so it cannot
  // be passed to arcLength/approxPolyDP directly. Instead we skip convexHull
  // and just run approxPolyDP with progressively looser epsilons on the
  // contour itself — this achieves the same "simplify to 4 sides" goal.
  if (quad4 == null && candidates.isNotEmpty) {
    debugPrint('EdgeDetection: no 4-poly found, trying loose-epsilon fallback');
    final contour = candidates.first;
    final peri    = cv.arcLength(contour, true);

    for (final eps in [0.06, 0.08, 0.10, 0.12, 0.15, 0.20]) {
      final approx = cv.approxPolyDP(contour, eps * peri, true);
      if (approx.length == 4) {
        final area = cv.contourArea(approx);
        if (area <= maxArea) {
          quad4 = approx;
          debugPrint('EdgeDetection ✓ loose-eps=$eps area=${area.toInt()}');
          break;
        }
      }
    }
  }

  // ── 13–15. Order points, scale, plausibility ──────────────────────────────
  if (quad4 != null && quad4.length == 4) {
    final pts     = quad4.toList();
    final ordered = _orderPoints(pts);
    final sx      = origW / wW;
    final sy      = origH / wH;

    final result = CropQuad(
      topLeft:     Offset(ordered[0].x * sx, ordered[0].y * sy),
      topRight:    Offset(ordered[1].x * sx, ordered[1].y * sy),
      bottomRight: Offset(ordered[2].x * sx, ordered[2].y * sy),
      bottomLeft:  Offset(ordered[3].x * sx, ordered[3].y * sy),
    );

    if (_isPlausible(result, origW, origH)) {
      debugPrint('EdgeDetection ✓ final result: '
          'TL=(${result.topLeft.dx.toInt()},${result.topLeft.dy.toInt()}) '
          'TR=(${result.topRight.dx.toInt()},${result.topRight.dy.toInt()}) '
          'BR=(${result.bottomRight.dx.toInt()},${result.bottomRight.dy.toInt()}) '
          'BL=(${result.bottomLeft.dx.toInt()},${result.bottomLeft.dy.toInt()})');
      return result;
    }
    debugPrint('EdgeDetection: result failed plausibility — '
        'BW=${((result.topRight.dx - result.topLeft.dx) / origW * 100).toStringAsFixed(1)}% '
        'BH=${((result.bottomLeft.dy - result.topLeft.dy) / origH * 100).toStringAsFixed(1)}%');
  }

  // ── 16. Otsu bright-blob fallback ─────────────────────────────────────────
  debugPrint('EdgeDetection: main pipeline failed → Otsu fallback');
  return _otsuFallback(filtered, wW, wH, origW, origH);
}

// ─────────────────────────────────────────────────────────────────────────────
// Median luminance (sigma thresholding for Canny)
// ─────────────────────────────────────────────────────────────────────────────

double _medianLuminance(cv.Mat grey, int w, int h) {
  // Build a 256-bin histogram and find the 50th percentile
  final hist = List<int>.filled(256, 0);
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

// ─────────────────────────────────────────────────────────────────────────────
// Point ordering — TL, TR, BR, BL
// ─────────────────────────────────────────────────────────────────────────────

List<cv.Point> _orderPoints(List<cv.Point> pts) {
  final sorted = List<cv.Point>.from(pts)
    ..sort((a, b) => (a.x + a.y).compareTo(b.x + b.y));

  final tl   = sorted[0];
  final br   = sorted[3];
  final rest = [sorted[1], sorted[2]]
    ..sort((a, b) => (a.y - a.x).compareTo(b.y - b.x));
  final tr = rest[0];
  final bl = rest[1];

  return [tl, tr, br, bl];
}

// ─────────────────────────────────────────────────────────────────────────────
// Plausibility check
// ─────────────────────────────────────────────────────────────────────────────

bool _isPlausible(CropQuad q, double w, double h) {
  final xs = [q.topLeft.dx, q.topRight.dx, q.bottomRight.dx, q.bottomLeft.dx];
  final ys = [q.topLeft.dy, q.topRight.dy, q.bottomRight.dy, q.bottomLeft.dy];
  final bw = xs.reduce(math.max) - xs.reduce(math.min);
  final bh = ys.reduce(math.max) - ys.reduce(math.min);

  // Must cover 10%–92% in both dimensions
  // Upper bound 92% is the key fix — previous 99% was letting near-full-frame
  // quads pass, which is exactly what was producing the bad TL=(6,47) result.
  return bw > w * 0.10 && bh > h * 0.10
      && bw < w * 0.92 && bh < h * 0.92;
}

// ─────────────────────────────────────────────────────────────────────────────
// Otsu bright-blob fallback
// ─────────────────────────────────────────────────────────────────────────────

CropQuad _otsuFallback(
    cv.Mat filtered, int wW, int wH, double origW, double origH) {
  try {
    // Re-use already filtered+border-burned grey image
    final (_, mask) = cv.threshold(
        filtered, 0, 255, cv.THRESH_BINARY | cv.THRESH_OTSU);

    final (contours, _) = cv.findContours(
        mask, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

    if (contours.isNotEmpty) {
      final sorted = contours.toList()
        ..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));

      final maxArea = wW * wH * 0.92;
      // Find largest contour that isn't the full image
      final best = sorted.firstWhere(
            (c) => cv.contourArea(c) <= maxArea,
        orElse: () => sorted.first,
      );

      final bbox = cv.boundingRect(best);
      final sx   = origW / wW;
      final sy   = origH / wH;

      final quad = CropQuad(
        topLeft:     Offset(bbox.x * sx,                     bbox.y * sy),
        topRight:    Offset((bbox.x + bbox.width) * sx,      bbox.y * sy),
        bottomRight: Offset((bbox.x + bbox.width) * sx,      (bbox.y + bbox.height) * sy),
        bottomLeft:  Offset(bbox.x * sx,                     (bbox.y + bbox.height) * sy),
      );

      if (_isPlausible(quad, origW, origH)) {
        debugPrint('EdgeDetection ✓ Otsu fallback succeeded');
        return quad;
      }
    }
  } catch (e) {
    debugPrint('EdgeDetection: Otsu fallback error — $e');
  }

  debugPrint('EdgeDetection: all passes failed → inset fallback');
  return _inset(origW, origH);
}

// ─────────────────────────────────────────────────────────────────────────────
// Final fallback
// ─────────────────────────────────────────────────────────────────────────────

CropQuad _inset(double w, double h, [double margin = 0.05]) => CropQuad(
  topLeft:     Offset(w * margin,       h * margin),
  topRight:    Offset(w * (1 - margin), h * margin),
  bottomRight: Offset(w * (1 - margin), h * (1 - margin)),
  bottomLeft:  Offset(w * margin,       h * (1 - margin)),
);