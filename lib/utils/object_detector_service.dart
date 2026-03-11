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

  /// Process a single frame and return the single largest detected object.
  /// Returns null if already processing a frame (to avoid backpressure).
  /// Returns an empty list if no objects were detected.
  Future<List<DetectedObject>?> processImage(InputImage inputImage) async {
    if (!_isInitialized || _objectDetector == null) return null;
    if (_isBusy) return null;

    _isBusy = true;
    try {
      final objects = await _objectDetector!.processImage(inputImage);
      if (objects.isEmpty) return [];

      // Keep only the object with the largest bounding box area
      final largest = objects.reduce((a, b) => _area(a) >= _area(b) ? a : b);
      return [largest];
    } catch (e) {
      // Silently ignore frame processing errors (e.g. rotation mismatch)
      return null;
    } finally {
      _isBusy = false;
    }
  }

  /// Bounding box area in pixels².
  double _area(DetectedObject obj) =>
      obj.boundingBox.width * obj.boundingBox.height;

  Future<void> dispose() async {
    await _objectDetector?.close();
    _objectDetector = null;
    _isInitialized = false;
  }
}
