import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv.dart' as cv;
import 'package:path_provider/path_provider.dart';
import '../screens/providers/capture_session.dart';

/// Applies perspective warp + colour filter to a [CapturedDocument].
///
/// Crop stage uses OpenCV warpPerspective (C++ speed, sub-pixel accuracy).
/// Filter stage uses the pure-Dart `image` package (no OpenCV dependency
/// for colour ops — keeps binary size lean since we only include imgproc).
class ImageProcessor {
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

      final ok = await Isolate.run(() => _process(args));
      return ok ? File(outPath) : null;
    } catch (e) {
      debugPrint('ImageProcessor: $e');
      return null;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Isolate entry
// ─────────────────────────────────────────────────────────────────────────────

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

bool _process(_ProcessArgs args) {
  try {
    final bytes = File(args.inputPath).readAsBytesSync();

    // ── Step 1: OpenCV perspective warp ─────────────────────────────────────
    cv.Mat warped;
    if (args.quad != null) {
      warped = _warpPerspective(bytes, args.quad!);
    } else {
      // No crop quad — just decode as-is
      warped = cv.imdecode(bytes, cv.IMREAD_COLOR);
    }

    if (warped.isEmpty) return false;

    // ── Step 2: Encode warped to bytes, hand off to image package for filter ─
    final warpedBytes = cv.imencode('.jpg', warped).$2;

    // ── Step 3: Apply colour filter (pure Dart, no extra OpenCV modules) ─────
    if (args.filter == DocumentFilter.original) {
      File(args.outputPath).writeAsBytesSync(warpedBytes);
      return true;
    }

    img.Image? dartImg = img.decodeImage(warpedBytes);
    if (dartImg == null) return false;

    dartImg = _applyFilter(dartImg, args.filter);

    final outBytes = img.encodeJpg(dartImg, quality: 92);
    File(args.outputPath).writeAsBytesSync(outBytes);
    return true;
  } catch (e) {
    debugPrint('_process error: $e');
    return false;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// OpenCV perspective warp
// ─────────────────────────────────────────────────────────────────────────────

cv.Mat _warpPerspective(Uint8List bytes, CropQuad quad) {
  final src = cv.imdecode(bytes, cv.IMREAD_COLOR);

  // Source points from the quad (already in original pixel space)
  final srcPts = cv.Mat.fromList(4, 1, cv.MatType.CV_32FC2, [
    quad.topLeft.dx,     quad.topLeft.dy,
    quad.topRight.dx,    quad.topRight.dy,
    quad.bottomRight.dx, quad.bottomRight.dy,
    quad.bottomLeft.dx,  quad.bottomLeft.dy,
  ]);

  // Output dimensions: average of opposing edge lengths
  final dstW = (_dist(quad.topLeft,    quad.topRight) +
      _dist(quad.bottomLeft, quad.bottomRight)) / 2;
  final dstH = (_dist(quad.topLeft,    quad.bottomLeft) +
      _dist(quad.topRight,   quad.bottomRight)) / 2;

  final outW = dstW.round().clamp(1, 8000);
  final outH = dstH.round().clamp(1, 8000);

  // Destination points — flat rectangle
  final dstPts = cv.Mat.fromList(4, 1, cv.MatType.CV_32FC2, [
    0.0,            0.0,
    outW.toDouble(), 0.0,
    outW.toDouble(), outH.toDouble(),
    0.0,            outH.toDouble(),
  ]);

  final M       = cv.getPerspectiveTransform(srcPts as cv.VecPoint, dstPts as cv.VecPoint);
  final warped  = cv.warpPerspective(src, M, (outW, outH));

  return warped;
}

double _dist(Offset a, Offset b) =>
    math.sqrt(math.pow(b.dx - a.dx, 2) + math.pow(b.dy - a.dy, 2));

// ─────────────────────────────────────────────────────────────────────────────
// Colour filters (pure Dart — image package)
// ─────────────────────────────────────────────────────────────────────────────

img.Image _applyFilter(img.Image image, DocumentFilter filter) {
  switch (filter) {
    case DocumentFilter.original:
      return image;

    case DocumentFilter.grayscale:
      return img.grayscale(image);

    case DocumentFilter.blackWhite:
      return _threshold(img.grayscale(image), 128);

    case DocumentFilter.magic:
    // Auto-contrast + mild unsharp mask — mimics CamScanner "Magic Color"
      img.Image result = img.adjustColor(
        image,
        contrast:   1.25,
        brightness: 1.05,
        saturation: 0.90,
      );
      result = img.convolution(result,
          filter: [0, -1, 0, -1, 5, -1, 0, -1, 0],
          div: 1, offset: 0);
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

img.Image _threshold(img.Image src, int level) {
  final out = img.Image(width: src.width, height: src.height);
  for (final pixel in src) {
    final val = pixel.r.toInt() >= level ? 255 : 0;
    out.setPixelRgb(pixel.x, pixel.y, val, val, val);
  }
  return out;
}