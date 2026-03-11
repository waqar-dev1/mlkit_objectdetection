import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'dart:ui';

class CameraUtils {
  static InputImage? cameraImageToInputImage(
    CameraImage image,
    CameraDescription camera,
  ) {
    // ── 1. Determine rotation ──────────────────────────────────────────────
    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;

    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var compensation = sensorOrientation;
      if (camera.lensDirection == CameraLensDirection.front) {
        compensation = (360 - compensation) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(compensation);
    }

    if (rotation == null) {
      debugPrint("CameraUtils: Could not determine rotation.");
      return null;
    }

    // ── 2. Build bytes ─────────────────────────────────────────────────────
    if (Platform.isAndroid) {
      return _buildAndroid(image, rotation);
    } else if (Platform.isIOS) {
      return _buildIOS(image, rotation);
    }

    return null;
  }

  // ── Android ──────────────────────────────────────────────────────────────
  //
  // The camera plugin can deliver frames in several formats depending on
  // the device:
  //   • ImageFormatGroup.nv21   → raw value 17  → InputImageFormat.nv21
  //   • ImageFormatGroup.yuv420 → raw value 35  → needs manual NV21 conversion
  //
  // ML Kit only accepts NV21 on Android, so we always convert.
  static InputImage? _buildAndroid(
    CameraImage image,
    InputImageRotation rotation,
  ) {
    final Uint8List nv21Bytes = _yuv420ToNv21(image);

    return InputImage.fromBytes(
      bytes: nv21Bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.width, // for NV21, bytesPerRow == width
      ),
    );
  }

  /// Converts any YUV420-family CameraImage (NV21, YUV_420_888, etc.)
  /// to a flat NV21 byte buffer that ML Kit can consume.
  ///
  /// NV21 layout:  [Y plane — width×height bytes]
  ///               [VU interleaved — width×height/2 bytes]
  static Uint8List _yuv420ToNv21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final int ySize = width * height;
    final int uvSize = width * height ~/ 2;

    final nv21 = Uint8List(ySize + uvSize);

    // ── Y plane ──────────────────────────────────────────────────────────
    final yPlane = image.planes[0];
    final yBytes = yPlane.bytes;
    final int yRowStride = yPlane.bytesPerRow;

    if (yRowStride == width) {
      // Fast path: no padding, copy directly
      nv21.setRange(0, ySize, yBytes);
    } else {
      // Slow path: copy row by row, skipping row padding
      for (int row = 0; row < height; row++) {
        nv21.setRange(
          row * width,
          row * width + width,
          yBytes,
          row * yRowStride,
        );
      }
    }

    // ── UV planes → interleaved VU ────────────────────────────────────────
    if (image.planes.length == 1) {
      // Device packed everything in plane[0] already (true NV21)
      return nv21;
    }

    final uPlane = image.planes.length > 2 ? image.planes[1] : null;
    final vPlane = image.planes.length > 2 ? image.planes[2] : null;

    if (vPlane != null && uPlane != null) {
      // YUV_420_888: separate U and V planes → interleave as VU
      final int uvRowStride = uPlane.bytesPerRow;
      final int uvPixelStride = uPlane.bytesPerPixel ?? 1;
      final int chromaHeight = height ~/ 2;
      final int chromaWidth = width ~/ 2;

      int dstIndex = ySize;
      for (int row = 0; row < chromaHeight; row++) {
        for (int col = 0; col < chromaWidth; col++) {
          final int srcIndex = row * uvRowStride + col * uvPixelStride;
          nv21[dstIndex++] = vPlane.bytes[srcIndex]; // V
          nv21[dstIndex++] = uPlane.bytes[srcIndex]; // U
        }
      }
    } else {
      // Fallback: plane[1] is already the interleaved UV chunk
      final uvBytes = image.planes[1].bytes;
      final int uvRowStride = image.planes[1].bytesPerRow;
      final int chromaHeight = height ~/ 2;

      if (uvRowStride == width) {
        nv21.setRange(ySize, ySize + uvSize, uvBytes);
      } else {
        for (int row = 0; row < chromaHeight; row++) {
          nv21.setRange(
            ySize + row * width,
            ySize + row * width + width,
            uvBytes,
            row * uvRowStride,
          );
        }
      }
    }

    return nv21;
  }

  // ── iOS ───────────────────────────────────────────────────────────────────
  //
  // iOS always delivers BGRA8888 from the camera plugin — a single packed
  // plane that ML Kit accepts directly.
  static InputImage? _buildIOS(
    CameraImage image,
    InputImageRotation rotation,
  ) {
    if (image.planes.isEmpty) {
      debugPrint("CameraUtils [iOS]: No planes in image.");
      return null;
    }

    final plane = image.planes[0];

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.bgra8888,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  /// Returns the [InputImageRotation] for a given camera — the same value
  /// used when building the InputImage.  Callers (e.g. the overlay painter)
  /// need this to map ML Kit coordinates back to screen space.
  static InputImageRotation? rotationForCamera(CameraDescription camera) {
    final sensorOrientation = camera.sensorOrientation;
    if (Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var compensation = sensorOrientation;
      if (camera.lensDirection == CameraLensDirection.front) {
        compensation = (360 - compensation) % 360;
      }
      return InputImageRotationValue.fromRawValue(compensation);
    }
    return null;
  }
}
