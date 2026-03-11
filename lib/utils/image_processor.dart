import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../screens/providers/capture_session.dart';

/// Applies perspective crop + colour filter to a [CapturedDocument] and
/// writes the result to the app temp directory.
///
/// All heavy work is done on a background isolate via [compute].
class ImageProcessor {
  /// Process [doc] and return the output [File].
  ///
  /// Runs in a background isolate so the UI never hitches.
  static Future<File?> process(CapturedDocument doc) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final outPath = '${tempDir.path}/processed_${doc.id}.jpg';

      final args = _ProcessArgs(
        inputPath:  doc.rawFile.path,
        outputPath: outPath,
        filter:     doc.filter,
        quad:       doc.cropQuad,
      );

      final result = await compute(_processInBackground, args);
      return result ? File(outPath) : null;
    } catch (e) {
      debugPrint('ImageProcessor: $e');
      return null;
    }
  }
}

// ── Background isolate entry ───────────────────────────────────────────────────

class _ProcessArgs {
  final String inputPath;
  final String outputPath;
  final DocumentFilter filter;
  final CropQuad? quad;

  _ProcessArgs({
    required this.inputPath,
    required this.outputPath,
    required this.filter,
    required this.quad,
  });
}

Future<bool> _processInBackground(_ProcessArgs args) async {
  try {
    // 1. Load
    final bytes = await File(args.inputPath).readAsBytes();
    img.Image? image = img.decodeImage(bytes);
    if (image == null) return false;

    // 2. Perspective-correct crop
    if (args.quad != null) {
      image = _perspectiveCrop(image, args.quad!);
    }

    // 3. Apply filter
    image = _applyFilter(image, args.filter);

    // 4. Encode and write
    final outBytes = img.encodeJpg(image, quality: 92);
    await File(args.outputPath).writeAsBytes(outBytes);
    return true;
  } catch (e) {
    return false;
  }
}

// ── Perspective crop ───────────────────────────────────────────────────────────

/// Performs a 4-point perspective transform (warp) so a skewed document quad
/// becomes a flat rectangle — the same thing CamScanner calls "Auto Crop".
///
/// Algorithm:
///   1. Compute the output rectangle dimensions from the quad's edge lengths.
///   2. Build a 3×3 perspective matrix mapping the quad corners → rectangle.
///   3. For each output pixel, inverse-transform to find the source pixel and
///      bilinear-sample the input image.
img.Image _perspectiveCrop(img.Image src, CropQuad q) {
  // Destination width = average of top and bottom edge lengths
  final wTop    = _dist(q.topLeft,     q.topRight);
  final wBottom = _dist(q.bottomLeft,  q.bottomRight);
  final hLeft   = _dist(q.topLeft,     q.bottomLeft);
  final hRight  = _dist(q.topRight,    q.bottomRight);

  final dstW = ((wTop + wBottom) / 2).round().clamp(1, 8000);
  final dstH = ((hLeft + hRight) / 2).round().clamp(1, 8000);

  final dst = img.Image(width: dstW, height: dstH);

  // Source points (as flat [x0,y0, x1,y1, x2,y2, x3,y3])
  final src4 = [
    q.topLeft.dx,     q.topLeft.dy,
    q.topRight.dx,    q.topRight.dy,
    q.bottomRight.dx, q.bottomRight.dy,
    q.bottomLeft.dx,  q.bottomLeft.dy,
  ];

  // Destination points
  final dst4 = [
    0.0,             0.0,
    dstW.toDouble(), 0.0,
    dstW.toDouble(), dstH.toDouble(),
    0.0,             dstH.toDouble(),
  ];

  // Compute the perspective matrix (dst→src) for inverse mapping
  final mat = _getPerspectiveTransform(dst4, src4);

  for (int y = 0; y < dstH; y++) {
    for (int x = 0; x < dstW; x++) {
      // Apply homogeneous transform
      final w  = mat[6] * x + mat[7] * y + mat[8];
      final sx = (mat[0] * x + mat[1] * y + mat[2]) / w;
      final sy = (mat[3] * x + mat[4] * y + mat[5]) / w;

      final px = _bilinearSample(src, sx, sy);
      dst.setPixel(x, y, px);
    }
  }

  return dst;
}

double _dist(ui.Offset a, ui.Offset b) =>
    math.sqrt(math.pow(b.dx - a.dx, 2) + math.pow(b.dy - a.dy, 2));

/// Bilinear interpolation — smooth sub-pixel sampling.
img.Color _bilinearSample(img.Image image, double x, double y) {
  final x0 = x.floor().clamp(0, image.width  - 1);
  final y0 = y.floor().clamp(0, image.height - 1);
  final x1 = (x0 + 1).clamp(0, image.width  - 1);
  final y1 = (y0 + 1).clamp(0, image.height - 1);

  final fx = x - x0;
  final fy = y - y0;

  final c00 = image.getPixel(x0, y0);
  final c10 = image.getPixel(x1, y0);
  final c01 = image.getPixel(x0, y1);
  final c11 = image.getPixel(x1, y1);

  int lerp(num a, num b, double t) => (a + (b - a) * t).round().clamp(0, 255);

  final r = lerp(lerp(c00.r, c10.r, fx), lerp(c01.r, c11.r, fx), fy);
  final g = lerp(lerp(c00.g, c10.g, fx), lerp(c01.g, c11.g, fx), fy);
  final b = lerp(lerp(c00.b, c10.b, fx), lerp(c01.b, c11.b, fx), fy);

  return img.ColorRgb8(r, g, b);
}

/// Compute the 3×3 perspective transform matrix from 4 source points to
/// 4 destination points using Gaussian elimination.
///
/// Returns a flat 9-element list [m00..m22].
List<double> _getPerspectiveTransform(List<double> src, List<double> dst) {
  // Build the 8×8 system Ax=b from the 4 point correspondences
  final A = List.generate(8, (_) => List<double>.filled(8, 0));
  final b = List<double>.filled(8, 0);

  for (int i = 0; i < 4; i++) {
    final sx = src[i * 2];
    final sy = src[i * 2 + 1];
    final dx = dst[i * 2];
    final dy = dst[i * 2 + 1];

    A[i * 2]     = [sx, sy, 1, 0,  0,  0, -dx * sx, -dx * sy];
    A[i * 2 + 1] = [0,  0,  0, sx, sy, 1, -dy * sx, -dy * sy];
    b[i * 2]     = dx;
    b[i * 2 + 1] = dy;
  }

  final x = _gaussianElimination(A, b);
  return [...x, 1.0]; // 9 elements, last is 1 (homogeneous)
}

List<double> _gaussianElimination(List<List<double>> A, List<double> b) {
  final n = b.length;
  for (int col = 0; col < n; col++) {
    // Partial pivot
    int maxRow = col;
    for (int row = col + 1; row < n; row++) {
      if (A[row][col].abs() > A[maxRow][col].abs()) maxRow = row;
    }
    final tmp  = A[col]; A[col] = A[maxRow]; A[maxRow] = tmp;
    final tmpB = b[col]; b[col] = b[maxRow]; b[maxRow] = tmpB;

    for (int row = col + 1; row < n; row++) {
      final factor = A[row][col] / A[col][col];
      b[row] -= factor * b[col];
      for (int j = col; j < n; j++) {
        A[row][j] -= factor * A[col][j];
      }
    }
  }

  // Back-substitution
  final x = List<double>.filled(n, 0);
  for (int i = n - 1; i >= 0; i--) {
    x[i] = b[i];
    for (int j = i + 1; j < n; j++) {
      x[i] -= A[i][j] * x[j];
    }
    x[i] /= A[i][i];
  }
  return x;
}

// ── Colour filters ─────────────────────────────────────────────────────────────

img.Image _applyFilter(img.Image image, DocumentFilter filter) {
  switch (filter) {
    case DocumentFilter.original:
      return image;

    case DocumentFilter.grayscale:
      return img.grayscale(image);

    case DocumentFilter.blackWhite:
    // Grayscale first, then manual threshold at 128.
    // img.threshold() does not exist in image 4.x — iterate pixels directly.
      final grey = img.grayscale(image);
      return _threshold(grey, 128);

    case DocumentFilter.magic:
    // Auto-levels (stretch histogram to full range) + mild sharpening
    // Mimics CamScanner "Magic Color" — boosts contrast on paper backgrounds
      img.Image result = img.adjustColor(
        image,
        contrast: 1.25,
        brightness: 1.05,
        saturation: 0.95, // slight desaturation makes text pop
      );
      result = img.convolution(result, filter: [
        0, -1,  0,
        -1,  5, -1,
        0, -1,  0,
      ], div: 1, offset: 0);
      return result;

    case DocumentFilter.vivid:
      return img.adjustColor(
        image,
        saturation: 1.4,
        contrast:   1.2,
        brightness: 1.02,
      );
  }
}
// ── Manual threshold (image 4.x has no img.threshold function) ───────────────

img.Image _threshold(img.Image src, int level) {
  final out = img.Image(width: src.width, height: src.height);
  for (final pixel in src) {
    // After grayscale all channels are equal; use red as luminance
    final lum = pixel.r.toInt();
    final val = lum >= level ? 255 : 0;
    out.setPixelRgb(pixel.x, pixel.y, val, val, val);
  }
  return out;
}