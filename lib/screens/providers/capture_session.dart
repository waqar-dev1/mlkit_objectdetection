import 'dart:io';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

// ── Filter types ───────────────────────────────────────────────────────────────

enum DocumentFilter {
  original,    // No processing — raw camera image
  magic,       // Auto-contrast + slight sharpening (like CamScanner "Magic")
  grayscale,   // Desaturate
  blackWhite,  // Aggressive threshold — pure black/white
  vivid,       // Boost saturation + contrast
}

extension DocumentFilterLabel on DocumentFilter {
  String get label {
    switch (this) {
      case DocumentFilter.original:   return 'Original';
      case DocumentFilter.magic:      return 'Magic';
      case DocumentFilter.grayscale:  return 'Grayscale';
      case DocumentFilter.blackWhite: return 'B & W';
      case DocumentFilter.vivid:      return 'Vivid';
    }
  }
}

// ── Crop quad ──────────────────────────────────────────────────────────────────

/// Four corners of a document crop, in the coordinate space of the
/// *original* raw image (pixels, not normalised).
///
/// Corner order (same as ML Kit document scanner output):
///   topLeft → topRight → bottomRight → bottomLeft
class CropQuad {
  final Offset topLeft;
  final Offset topRight;
  final Offset bottomRight;
  final Offset bottomLeft;

  const CropQuad({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
  });

  /// Full-image quad — no crop applied.
  factory CropQuad.fullImage(double w, double h) => CropQuad(
    topLeft:     Offset.zero,
    topRight:    Offset(w, 0),
    bottomRight: Offset(w, h),
    bottomLeft:  Offset(0, h),
  );

  List<Offset> get corners => [topLeft, topRight, bottomRight, bottomLeft];

  CropQuad copyWith({
    Offset? topLeft,
    Offset? topRight,
    Offset? bottomRight,
    Offset? bottomLeft,
  }) =>
      CropQuad(
        topLeft:     topLeft     ?? this.topLeft,
        topRight:    topRight    ?? this.topRight,
        bottomRight: bottomRight ?? this.bottomRight,
        bottomLeft:  bottomLeft  ?? this.bottomLeft,
      );
}

// ── Single captured page ───────────────────────────────────────────────────────

class CapturedDocument {
  /// Unique id — milliseconds-since-epoch at capture time.
  final String id;

  /// Original file from [CameraController.takePicture]. Never overwritten.
  final File rawFile;

  /// Wall-clock time of capture.
  final DateTime capturedAt;

  // ── Phase 3 mutable fields ─────────────────────────────────────────────────

  /// 4-corner crop quad in raw-image pixel coordinates.
  /// Null until [EdgeDetectionService] has run (or user sets it manually).
  CropQuad? cropQuad;

  /// The processed output file (cropped + filtered).
  /// Null until [ImageProcessor.process] has been called.
  File? processedFile;

  /// Which filter to apply. Defaults to [DocumentFilter.original].
  DocumentFilter filter;

  /// True while the background processor is working on this page.
  bool isProcessing;

  CapturedDocument({
    required this.id,
    required this.rawFile,
    required this.capturedAt,
    this.cropQuad,
    this.processedFile,
    this.filter = DocumentFilter.original,
    this.isProcessing = false,
  });

  factory CapturedDocument.fromXFile(XFile xfile) {
    final now = DateTime.now();
    return CapturedDocument(
      id: now.millisecondsSinceEpoch.toString(),
      rawFile: File(xfile.path),
      capturedAt: now,
    );
  }

  /// The best available image to show in the UI.
  File get displayFile => processedFile ?? rawFile;
}

// ── Session ────────────────────────────────────────────────────────────────────

class CaptureSession extends ChangeNotifier {
  final List<CapturedDocument> _pages = [];

  List<CapturedDocument> get pages => List.unmodifiable(_pages);
  int    get count      => _pages.length;
  bool   get isEmpty    => _pages.isEmpty;
  bool   get isNotEmpty => _pages.isNotEmpty;

  CapturedDocument? get lastPage => _pages.isEmpty ? null : _pages.last;

  CapturedDocument? pageById(String id) {
    try {
      return _pages.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  void addPage(CapturedDocument doc) {
    _pages.add(doc);
    notifyListeners();
  }

  void removePage(String id) {
    _pages.removeWhere((d) => d.id == id);
    notifyListeners();
  }

  /// Update crop quad for a single page and notify.
  void setCropQuad(String id, CropQuad quad) {
    pageById(id)?.cropQuad = quad;
    notifyListeners();
  }

  /// Update filter for a single page and notify.
  void setFilter(String id, DocumentFilter filter) {
    pageById(id)?.filter = filter;
    notifyListeners();
  }

  /// Apply the same filter to every page.
  void applyFilterToAll(DocumentFilter filter) {
    for (final p in _pages) {
      p.filter = filter;
    }
    notifyListeners();
  }

  /// Mark a page as processed (or clear its processed file).
  void setProcessedFile(String id, File? file) {
    final page = pageById(id);
    if (page == null) return;
    page.processedFile = file;
    page.isProcessing  = false;
    notifyListeners();
  }

  void setProcessing(String id, bool value) {
    pageById(id)?.isProcessing = value;
    notifyListeners();
  }

  void clear() {
    _pages.clear();
    notifyListeners();
  }
}
