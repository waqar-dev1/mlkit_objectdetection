import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'dart:ui';
class CameraUtils {
  /// Convert CameraImage to InputImage for ML Kit processing
  static InputImage? cameraImageToInputImage(
    CameraImage image,
    CameraDescription camera,
  ) {
    final sensorOrientation = camera.sensorOrientation;

    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      // For Android, we need to adjust based on camera facing
      var rotationCompensation = sensorOrientation;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (360 - rotationCompensation) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }

    if (rotation == null) return null;

    // Get image format
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }

    // Compose the image bytes
    if (image.planes.isEmpty) return null;

    final Uint8List bytes;
    if (format == InputImageFormat.nv21) {
      // NV21: combine Y and UV planes
      final yPlane = image.planes[0];
      final uvPlane = image.planes.length > 1 ? image.planes[1] : null;
      if (uvPlane == null) return null;
      bytes = Uint8List(yPlane.bytes.length + uvPlane.bytes.length)
        ..setAll(0, yPlane.bytes)
        ..setAll(yPlane.bytes.length, uvPlane.bytes);
    } else {
      bytes = image.planes[0].bytes;
    }

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }
}
