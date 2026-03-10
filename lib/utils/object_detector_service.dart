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
    if (!_isInitialized || _objectDetector == null) return null;
    if (_isBusy) return null;

    _isBusy = true;
    try {
      final objects = await _objectDetector!.processImage(inputImage);
      return objects;
    } catch (e) {
      // Silently ignore frame processing errors (e.g. rotation mismatch)
      return null;
    } finally {
      _isBusy = false;
    }
  }

  Future<void> dispose() async {
    await _objectDetector?.close();
    _objectDetector = null;
    _isInitialized = false;
  }
}
