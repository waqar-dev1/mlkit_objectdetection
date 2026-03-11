import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../screens/providers/capture_session.dart';

/// Multi-pass document corner detector — pure Dart, background isolate.
///
/// Pipeline:
///   1. Downscale → grayscale → bilateral-style blur (preserve edges)
///   2. Canny-inspired edge map (Sobel + non-max suppression + hysteresis)
///   3. Morphological close (dilate→erode) to connect broken edges
///   4. Ignore a 3% image border to avoid frame edges
///   5. Project edge pixels onto X and Y axes — find histogram peaks
///   6. Pick the outermost strong peaks on each side as document boundaries
///   7. Cross-validate: the four lines must form a plausible rectangle
///   8. Fall back to Otsu bright-blob if line detection fails
class EdgeDetectionService {
  static Future<CropQuad?> detectCorners(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      return await compute(_pipeline, bytes);
    } catch (e) {
      debugPrint('EdgeDetectionService: $e');
      return null;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Isolate entry
// ─────────────────────────────────────────────────────────────────────────────

CropQuad _pipeline(Uint8List bytes) {
  final original = img.decodeImage(bytes);
  if (original == null) return _inset(100, 100);

  final oW = original.width.toDouble();
  final oH = original.height.toDouble();

  // ── 1. Downscale to ~500px longest side ───────────────────────────────────
  const work = 500;
  final sc   = work / math.max(oW, oH);
  final wW   = (oW * sc).round();
  final wH   = (oH * sc).round();
  final small = img.copyResize(original, width: wW, height: wH,
      interpolation: img.Interpolation.average);

  // ── 2. Grayscale + box blur (approximates bilateral for speed) ────────────
  final grey    = img.grayscale(small);
  final blurred = img.gaussianBlur(grey, radius: 2);

  // ── 3. Read luminance grid ────────────────────────────────────────────────
  final lum = _readLum(blurred, wW, wH);

  // ── 4. Canny-style edge map ───────────────────────────────────────────────
  final (mag, dir) = _sobelFull(lum, wW, wH);
  final nms        = _nonMaxSuppression(mag, dir, wW, wH);
  final edges      = _hysteresis(nms, wW, wH, loRatio: 0.25, hiRatio: 0.65);

  // ── 5. Morphological close (3×3 dilation then erosion) ───────────────────
  final closed = _morphClose(edges, wW, wH);

  // ── 6. Border exclusion — 3% on each side ────────────────────────────────
  final bx = (wW * 0.03).round();
  final by = (wH * 0.03).round();
  for (int y = 0; y < wH; y++) {
    for (int x = 0; x < wW; x++) {
      if (x < bx || x >= wW - bx || y < by || y >= wH - by) {
        closed[y * wW + x] = false;
      }
    }
  }

  // ── 7. Axis projections → document boundaries ────────────────────────────
  final bounds = _projectBoundaries(closed, wW, wH);

  // ── 8. Cross-validate rectangle ──────────────────────────────────────────
  if (bounds != null && _isPlausibleRect(bounds, wW, wH)) {
    final sx = oW / wW;
    final sy = oH / wH;
    debugPrint('EdgeDetection ✓ '
        'L=${(bounds.l*sx).toInt()} T=${(bounds.t*sy).toInt()} '
        'R=${(bounds.r*sx).toInt()} B=${(bounds.b*sy).toInt()}');
    return CropQuad(
      topLeft:     Offset(bounds.l * sx, bounds.t * sy),
      topRight:    Offset(bounds.r * sx, bounds.t * sy),
      bottomRight: Offset(bounds.r * sx, bounds.b * sy),
      bottomLeft:  Offset(bounds.l * sx, bounds.b * sy),
    );
  }

  // ── 9. Fallback: Otsu bright-blob ─────────────────────────────────────────
  debugPrint('EdgeDetection: line detection failed, trying blob fallback');
  final blob = _otsuBlob(lum, wW, wH, bx, by);
  if (blob != null && _isPlausibleRect(blob, wW, wH)) {
    final sx = oW / wW;
    final sy = oH / wH;
    debugPrint('EdgeDetection blob ✓');
    return CropQuad(
      topLeft:     Offset(blob.l * sx, blob.t * sy),
      topRight:    Offset(blob.r * sx, blob.t * sy),
      bottomRight: Offset(blob.r * sx, blob.b * sy),
      bottomLeft:  Offset(blob.l * sx, blob.b * sy),
    );
  }

  debugPrint('EdgeDetection: both passes failed → inset fallback');
  return _inset(oW, oH);
}

// ─────────────────────────────────────────────────────────────────────────────
// Luminance reader
// ─────────────────────────────────────────────────────────────────────────────

List<int> _readLum(img.Image g, int w, int h) {
  final out = List<int>.filled(w * h, 0);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      out[y * w + x] = g.getPixel(x, y).r.toInt();
    }
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Sobel — returns magnitude and quantised direction (0/45/90/135 degrees)
// ─────────────────────────────────────────────────────────────────────────────

(List<double>, List<int>) _sobelFull(List<int> lum, int w, int h) {
  final mag = List<double>.filled(w * h, 0);
  final dir = List<int>.filled(w * h, 0); // 0,1,2,3 = 0°,45°,90°,135°

  int px(int x, int y) => lum[y.clamp(0,h-1) * w + x.clamp(0,w-1)];

  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final gx = -px(x-1,y-1) + px(x+1,y-1)
          -2*px(x-1,y)  + 2*px(x+1,y)
          -px(x-1,y+1) + px(x+1,y+1);
      final gy = -px(x-1,y-1) - 2*px(x,y-1) - px(x+1,y-1)
          +px(x-1,y+1) + 2*px(x,y+1) + px(x+1,y+1);

      mag[y*w+x] = math.sqrt(gx*gx + gy*gy.toDouble());

      // Quantise angle to 0/45/90/135
      final angle = math.atan2(gy.toDouble(), gx.toDouble()) * 180 / math.pi;
      final a = (angle < 0 ? angle + 180 : angle);
      dir[y*w+x] = a < 22.5 || a >= 157.5 ? 0
          : a < 67.5  ? 1
          : a < 112.5 ? 2
          : 3;
    }
  }
  return (mag, dir);
}

// ─────────────────────────────────────────────────────────────────────────────
// Non-maximum suppression — thin edges to single-pixel width
// ─────────────────────────────────────────────────────────────────────────────

List<double> _nonMaxSuppression(List<double> mag, List<int> dir, int w, int h) {
  final out = List<double>.filled(w * h, 0);
  double m(int x, int y) => (x<0||x>=w||y<0||y>=h) ? 0 : mag[y*w+x];

  for (int y = 1; y < h-1; y++) {
    for (int x = 1; x < w-1; x++) {
      final v = mag[y*w+x];
      double n1, n2;
      switch (dir[y*w+x]) {
        case 0:  n1 = m(x-1,y); n2 = m(x+1,y);
        case 1:  n1 = m(x-1,y+1); n2 = m(x+1,y-1);
        case 2:  n1 = m(x,y-1); n2 = m(x,y+1);
        default: n1 = m(x-1,y-1); n2 = m(x+1,y+1);
      }
      out[y*w+x] = (v >= n1 && v >= n2) ? v : 0;
    }
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Hysteresis thresholding — strong edges stay, weak edges only if connected
// ─────────────────────────────────────────────────────────────────────────────

List<bool> _hysteresis(List<double> nms, int w, int h,
    {required double loRatio, required double hiRatio}) {
  double maxV = 0;
  for (final v in nms) if (v > maxV) maxV = v;

  final hi = maxV * hiRatio;
  final lo = maxV * loRatio;

  final strong = List<bool>.filled(w * h, false);
  final weak   = List<bool>.filled(w * h, false);
  for (int i = 0; i < w * h; i++) {
    if (nms[i] >= hi) strong[i] = true;
    else if (nms[i] >= lo) weak[i] = true;
  }

  // BFS: promote weak pixels connected to strong pixels
  final out   = List<bool>.from(strong);
  final queue = <int>[];
  for (int i = 0; i < w * h; i++) {
    if (strong[i]) queue.add(i);
  }

  while (queue.isNotEmpty) {
    final idx = queue.removeLast();
    final x = idx % w;
    final y = idx ~/ w;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = x + dx;
        final ny = y + dy;
        if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
        final ni = ny * w + nx;
        if (weak[ni] && !out[ni]) {
          out[ni] = true;
          queue.add(ni);
        }
      }
    }
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Morphological close (dilate + erode with 3×3 kernel)
// ─────────────────────────────────────────────────────────────────────────────

List<bool> _morphClose(List<bool> src, int w, int h) {
  // Dilate
  final dilated = List<bool>.filled(w * h, false);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      bool found = false;
      outer:
      for (int dy = -1; dy <= 1 && !found; dy++) {
        for (int dx = -1; dx <= 1 && !found; dx++) {
          final nx = x+dx; final ny = y+dy;
          if (nx>=0&&nx<w&&ny>=0&&ny<h&&src[ny*w+nx]) found = true;
        }
      }
      dilated[y*w+x] = found;
    }
  }
  // Erode
  final eroded = List<bool>.filled(w * h, false);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      bool all = true;
      outer:
      for (int dy = -1; dy <= 1 && all; dy++) {
        for (int dx = -1; dx <= 1 && all; dx++) {
          final nx = x+dx; final ny = y+dy;
          if (nx<0||nx>=w||ny<0||ny>=h||!dilated[ny*w+nx]) all = false;
        }
      }
      eroded[y*w+x] = all;
    }
  }
  return eroded;
}

// ─────────────────────────────────────────────────────────────────────────────
// Axis projection — find document boundaries from edge density histograms
// ─────────────────────────────────────────────────────────────────────────────

class _Bounds {
  final double l, t, r, b;
  const _Bounds(this.l, this.t, this.r, this.b);
}

_Bounds? _projectBoundaries(List<bool> edges, int w, int h) {
  // Build row and column density histograms
  final colHist = List<int>.filled(w, 0);
  final rowHist = List<int>.filled(h, 0);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      if (edges[y*w+x]) { colHist[x]++; rowHist[y]++; }
    }
  }

  // Smooth histograms with a 5-tap box filter to merge nearby peaks
  List<double> smooth(List<int> hist) {
    final s = List<double>.filled(hist.length, 0);
    for (int i = 0; i < hist.length; i++) {
      double sum = 0; int cnt = 0;
      for (int d = -2; d <= 2; d++) {
        final j = i + d;
        if (j >= 0 && j < hist.length) { sum += hist[j]; cnt++; }
      }
      s[i] = sum / cnt;
    }
    return s;
  }

  final sc = smooth(colHist);
  final sr = smooth(rowHist);

  // Dynamic threshold = mean + 0.5 * std of smoothed histogram
  double dynThreshold(List<double> h2) {
    final mean = h2.reduce((a,b) => a+b) / h2.length;
    final variance = h2.map((v) => (v-mean)*(v-mean))
        .reduce((a,b) => a+b) / h2.length;
    return mean + 0.5 * math.sqrt(variance);
  }

  final cThr = dynThreshold(sc);
  final rThr = dynThreshold(sr);

  // Find outermost peaks that exceed threshold (scan inward from borders)
  int? left, right, top, bottom;
  for (int x = 0; x < w; x++)   { if (sc[x] > cThr) { left  = x; break; } }
  for (int x = w-1; x >= 0; x--){ if (sc[x] > cThr) { right = x; break; } }
  for (int y = 0; y < h; y++)   { if (sr[y] > rThr) { top   = y; break; } }
  for (int y = h-1; y >= 0; y--){ if (sr[y] > rThr) { bottom = y; break; } }

  if (left==null||right==null||top==null||bottom==null) return null;
  return _Bounds(left.toDouble(), top.toDouble(),
      right.toDouble(), bottom.toDouble());
}

// ─────────────────────────────────────────────────────────────────────────────
// Plausibility check
// ─────────────────────────────────────────────────────────────────────────────

bool _isPlausibleRect(_Bounds b, int w, int h) {
  final bw = b.r - b.l;
  final bh = b.b - b.t;
  return bw > w * 0.2 && bh > h * 0.2  // must be at least 20% of image
      && bw < w * 0.99 && bh < h * 0.99; // must not be the full frame
}

// ─────────────────────────────────────────────────────────────────────────────
// Otsu bright-blob fallback
// ─────────────────────────────────────────────────────────────────────────────

_Bounds? _otsuBlob(List<int> lum, int w, int h, int bx, int by) {
  // Otsu threshold
  final hist = List<int>.filled(256, 0);
  for (final p in lum) hist[p]++;
  final total = lum.length;
  double sumAll = 0;
  for (int i = 0; i < 256; i++) sumAll += i * hist[i];

  double sumB = 0; int wB = 0;
  double maxVar = 0; int thr = 128;
  for (int t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0 || wB == total) continue;
    sumB += t * hist[t];
    final mB = sumB / wB;
    final mF = (sumAll - sumB) / (total - wB);
    final v  = wB * (total - wB) * (mB - mF) * (mB - mF);
    if (v > maxVar) { maxVar = v; thr = t; }
  }

  // Find bounding box of bright pixels (excluding border)
  int? minX, maxX, minY, maxY;
  for (int y = by; y < h - by; y++) {
    for (int x = bx; x < w - bx; x++) {
      if (lum[y*w+x] >= thr) {
        if (minX == null || x < minX) minX = x;
        if (maxX == null || x > maxX) maxX = x;
        if (minY == null || y < minY) minY = y;
        if (maxY == null || y > maxY) maxY = y;
      }
    }
  }

  if (minX==null) return null;
  return _Bounds(minX.toDouble(), minY!.toDouble(),
      maxX!.toDouble(), maxY!.toDouble());
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

CropQuad _inset(double w, double h, [double margin = 0.05]) => CropQuad(
  topLeft:     Offset(w*margin,     h*margin),
  topRight:    Offset(w*(1-margin), h*margin),
  bottomRight: Offset(w*(1-margin), h*(1-margin)),
  bottomLeft:  Offset(w*margin,     h*(1-margin)),
);