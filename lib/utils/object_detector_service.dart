import 'package:flutter/cupertino.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

class ObjectDetectorService {
  ObjectDetector? _objectDetector;
  bool _isInitialized = false;
  bool _isBusy = false;

  bool get isInitialized => _isInitialized;
  bool get isBusy => _isBusy;

  Future<void> initialize() async {
    if (_isInitialized) return;

    // Use base model (no custom model needed for general object detection)
    final options = ObjectDetectorOptions(
      // Use streaming mode for real-time camera feed
      mode: DetectionMode.stream,
      // Enable classification to get labels/confidence
      classifyObjects: true,
      // Allow multiple detections per frame
      multipleObjects: true,
    );

    _objectDetector = ObjectDetector(options: options);
    _isInitialized = true;
  }

  /// Process a single frame and return detected objects.
  /// Returns null if already processing a frame (to avoid backpressure).
  Future<List<DetectedObject>?> processImage(InputImage inputImage) async {
    if (!_isInitialized || _objectDetector == null) {
      debugPrint("ProcessImage: Detector not initialized.");
      return null;
    }
    if (_isBusy) {
      debugPrint("ProcessImage: Detector busy, skipping frame.");
      return null;
    }

    _isBusy = true;
    debugPrint("ProcessImage: Starting inference...");

    try {
      final objects = await _objectDetector!.processImage(inputImage);
      debugPrint("ProcessImage: Success! Found ${objects.length} objects.");
      final largest = objects.reduce((a, b) => _area(a) >= _area(b) ? a : b);
      return [largest];
    } catch (e) {
      debugPrint("ProcessImage: Error processing frame: $e");
      return null;
    } finally {
      _isBusy = false;
    }
  }
  double _area(DetectedObject obj) =>
      obj.boundingBox.width * obj.boundingBox.height;
  Future<void> dispose() async {
    await _objectDetector?.close();
    _objectDetector = null;
    _isInitialized = false;
  }
}
