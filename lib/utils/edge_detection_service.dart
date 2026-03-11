import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../screens/providers/capture_session.dart';

/// Pure-Dart document corner detector.
///
/// Pipeline (all runs in a background isolate — zero UI thread work):
///   1. Decode image and downscale to a fast working size (~600px)
///   2. Convert to grayscale
///   3. Apply Gaussian blur to reduce noise
///   4. Sobel edge detection
///   5. Scan from each of the 4 sides inward to find where strong edges start
///   6. Return a [CropQuad] in original-image pixel coordinates
///
/// If detection confidence is low, falls back to a 5% inset of the full image
/// so the user always has a sensible starting point in the crop editor.
class EdgeDetectionService {
  static Future<CropQuad?> detectCorners(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final result = await compute(_detect, bytes);
      debugPrint('EdgeDetectionService: ${result.toString()}');
      return result;
    } catch (e) {
      debugPrint('EdgeDetectionService: $e');
      return null;
    }
  }
}

// ── Background isolate entry point ─────────────────────────────────────────────

CropQuad? _detect(Uint8List bytes) {
  // 1. Decode
  img.Image? original = img.decodeImage(bytes);
  if (original == null) return null;

  final origW = original.width.toDouble();
  final origH = original.height.toDouble();

  // 2. Downscale for speed — work at max 640px on the longest side
  const workSize = 640;
  img.Image work;
  if (origW > workSize || origH > workSize) {
    final scale = workSize / math.max(origW, origH);
    work = img.copyResize(
      original,
      width:  (origW * scale).round(),
      height: (origH * scale).round(),
      interpolation: img.Interpolation.average,
    );
  } else {
    work = original;
  }

  final wW = work.width;
  final wH = work.height;

  // 3. Grayscale
  final grey = img.grayscale(work);

  // 4. Gaussian blur (3x3 kernel) to suppress noise
  final blurred = img.gaussianBlur(grey, radius: 2);

  // 5. Build edge magnitude map using Sobel
  final edges = _sobelEdges(blurred);

  // 6. Scan from each side to find the document boundary
  final threshold = _adaptiveThreshold(edges);

  final top    = _scanFromTop(edges, threshold, wW, wH);
  final bottom = _scanFromBottom(edges, threshold, wW, wH);
  final left   = _scanFromLeft(edges, threshold, wW, wH);
  final right  = _scanFromRight(edges, threshold, wW, wH);

  // 7. Scale back to original image coordinates
  final scaleX = origW / wW;
  final scaleY = origH / wH;

  // Add a small inward nudge (3px in work space) so handles sit just inside
  const nudge = 3.0;
  final t = math.max(0.0, top    - nudge) * scaleY;
  final b = math.min(origH, bottom + nudge) * scaleY;
  final l = math.max(0.0, left   - nudge) * scaleX;
  final r = math.min(origW, right + nudge) * scaleX;

  // 8. Sanity check — if the detected region is implausibly small fall back
  final detectedW = r - l;
  final detectedH = b - t;
  if (detectedW < origW * 0.2 || detectedH < origH * 0.2) {
    return _insetQuad(origW, origH, 0.05);
  }

  final quad = CropQuad(
    topLeft:     Offset(l, t),
    topRight:    Offset(r, t),
    bottomRight: Offset(r, b),
    bottomLeft:  Offset(l, b),
  );

  print('CropQuad:\n'
      'topLeft: ${quad.topLeft}\n'
      'topRight: ${quad.topRight}\n'
      'bottomRight: ${quad.bottomRight}\n'
      'bottomLeft: ${quad.bottomLeft}');

  return quad;
}

// ── Sobel edge map ─────────────────────────────────────────────────────────────

/// Returns a 2D list [y][x] of edge magnitudes (0–255).
List<List<int>> _sobelEdges(img.Image grey) {
  final w = grey.width;
  final h = grey.height;

  // Pre-read luminance into a flat list for fast random access
  final lum = List<int>.filled(w * h, 0);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      lum[y * w + x] = grey.getPixel(x, y).r.toInt();
    }
  }

  int px(int x, int y) {
    x = x.clamp(0, w - 1);
    y = y.clamp(0, h - 1);
    return lum[y * w + x];
  }

  final out = List.generate(h, (_) => List<int>.filled(w, 0));
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final gx = -px(x-1,y-1) + px(x+1,y-1)
          -2*px(x-1,y)  + 2*px(x+1,y)
          -px(x-1,y+1) + px(x+1,y+1);
      final gy = -px(x-1,y-1) - 2*px(x,y-1) - px(x+1,y-1)
          +px(x-1,y+1) + 2*px(x,y+1) + px(x+1,y+1);
      out[y][x] = math.sqrt(gx*gx + gy*gy).clamp(0, 255).toInt();
    }
  }
  return out;
}

// ── Adaptive threshold ─────────────────────────────────────────────────────────

/// Pick a threshold that classifies roughly the top 15 % of pixels as edges.
int _adaptiveThreshold(List<List<int>> edges) {
  final hist = List<int>.filled(256, 0);
  int total = 0;
  for (final row in edges) {
    for (final v in row) {
      hist[v]++;
      total++;
    }
  }
  final target = (total * 0.85).toInt(); // keep top 15 %
  int cumul = 0;
  for (int i = 0; i < 256; i++) {
    cumul += hist[i];
    if (cumul >= target) return math.max(i, 20); // floor at 20
  }
  return 40;
}

// ── Directional scanners ───────────────────────────────────────────────────────
//
// Each scanner collapses the edge map along one axis by summing a column/row,
// then walks inward from the outside until the sum crosses a density threshold.
// This is robust to sparse edges that Sobel produces on real document photos.

double _scanFromTop(List<List<int>> e, int thr, int w, int h) {
  for (int y = 0; y < h; y++) {
    int sum = 0;
    for (int x = 0; x < w; x++) sum += e[y][x] > thr ? 1 : 0;
    if (sum > w * 0.12) return y.toDouble();
  }
  return h * 0.05;
}

double _scanFromBottom(List<List<int>> e, int thr, int w, int h) {
  for (int y = h - 1; y >= 0; y--) {
    int sum = 0;
    for (int x = 0; x < w; x++) sum += e[y][x] > thr ? 1 : 0;
    if (sum > w * 0.12) return y.toDouble();
  }
  return h * 0.95;
}

double _scanFromLeft(List<List<int>> e, int thr, int w, int h) {
  for (int x = 0; x < w; x++) {
    int sum = 0;
    for (int y = 0; y < h; y++) sum += e[y][x] > thr ? 1 : 0;
    if (sum > h * 0.12) return x.toDouble();
  }
  return w * 0.05;
}

double _scanFromRight(List<List<int>> e, int thr, int w, int h) {
  for (int x = w - 1; x >= 0; x--) {
    int sum = 0;
    for (int y = 0; y < h; y++) sum += e[y][x] > thr ? 1 : 0;
    if (sum > h * 0.12) return x.toDouble();
  }
  return w * 0.95;
}

// ── Fallback ───────────────────────────────────────────────────────────────────

CropQuad _insetQuad(double w, double h, double margin) => CropQuad(
  topLeft:     Offset(w * margin,       h * margin),
  topRight:    Offset(w * (1 - margin), h * margin),
  bottomRight: Offset(w * (1 - margin), h * (1 - margin)),
  bottomLeft:  Offset(w * margin,       h * (1 - margin)),
);