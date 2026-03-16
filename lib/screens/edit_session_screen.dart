import 'dart:io';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:ml_objecdetection/screens/providers/capture_session.dart';
import 'package:share_plus/share_plus.dart';
import '../utils/edge_detection_service.dart';
import '../utils/image_processor.dart';
import '../widgets/crop/crop_editor.dart';
import '../widgets/filter/filter_strip.dart';

/// Phase 3 — Edit screen.
///
/// Layout:
///   ┌──────────────────────────────┐
///   │  Top bar (back | title | done│
///   ├──────────────────────────────┤
///   │                              │
///   │   Main editor area           │
///   │   (image + crop overlay)     │
///   │                              │
///   ├──────────────────────────────┤
///   │   Filter strip               │
///   ├──────────────────────────────┤
///   │   Page thumbnail rail        │
///   └──────────────────────────────┘
///
/// Design decisions
/// ───────────────
/// • Crop and filter are *per-page*; switching thumbnail saves the current
///   quad immediately to [CaptureSession], so nothing is lost.
/// • "Apply filter to all" propagates the active page's filter to every page.
/// • The user may tap Done, review the result, return to the editor, adjust,
///   and tap Done again any number of times — processing is always re-run
///   with the latest quad/filter.
/// • During crop mode the image is NOT wrapped in InteractiveViewer because
///   that would make the viewer intercept pan gestures meant for the crop
///   handle. Pinch-to-zoom is re-enabled when crop mode is off.
class EditSessionScreen extends StatefulWidget {
  final CaptureSession session;

  const EditSessionScreen({super.key, required this.session});

  @override
  State<EditSessionScreen> createState() => _EditSessionScreenState();
}

class _EditSessionScreenState extends State<EditSessionScreen> {
  CaptureSession get _session => widget.session;

  /// Index of the page currently shown in the editor.
  int _activeIndex = 0;

  /// Normalised [0..1] crop quad shown in the crop editor for the active page.
  CropQuad _normQuad = const CropQuad(
    topLeft:     Offset(0, 0),
    topRight:    Offset(1, 0),
    bottomRight: Offset(1, 1),
    bottomLeft:  Offset(0, 1),
  );

  /// Whether the crop-handle overlay is shown.
  bool _cropMode = true;

  /// Whether the edge-detection pass is running for the current page.
  bool _detecting = false;

  /// Pixel dimensions of the active page's raw file (for coord conversion).
  Size? _rawImageSize;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadPage(0);
  }

  // ── Page switching ─────────────────────────────────────────────────────────

  Future<void> _loadPage(int index) async {
    if (index < 0 || index >= _session.count) return;

    setState(() {
      _activeIndex = index;
      _rawImageSize = null;
      _detecting = false;
    });

    final page = _session.pages[index];

    // 1. Decode image size (needed for coordinate conversion).
    final size = await _getImageSize(page.rawFile);
    if (!mounted) return;
    setState(() => _rawImageSize = size);

    // 2. Run edge detection if this page has no quad yet.
    if (page.cropQuad == null && size != null) {
      setState(() => _detecting = true);

      final detected = await EdgeDetectionService.detectCorners(page.rawFile);
      if (!mounted) return;

      final quad = detected ?? CropQuad.fullImage(size.width, size.height);
      _session.setCropQuad(page.id, quad);

      setState(() {
        _normQuad  = _toNorm(quad, size);
        _detecting = false;
      });
    } else if (page.cropQuad != null && size != null) {
      // Page already has a quad — just display it.
      setState(() => _normQuad = _toNorm(page.cropQuad!, size));
    } else {
      // No size available (should not happen) — show full-frame default.
      setState(() => _normQuad = const CropQuad(
        topLeft:     Offset(0, 0),
        topRight:    Offset(1, 0),
        bottomRight: Offset(1, 1),
        bottomLeft:  Offset(0, 1),
      ));
    }
  }

  Future<Size?> _getImageSize(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final codec = await instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final w     = frame.image.width.toDouble();
      final h     = frame.image.height.toDouble();
      frame.image.dispose();
      return Size(w, h);
    } catch (_) {
      return null;
    }
  }

  // ── Coordinate conversion ──────────────────────────────────────────────────

  CropQuad _toNorm(CropQuad q, Size s) => CropQuad(
    topLeft:     Offset(q.topLeft.dx / s.width,     q.topLeft.dy / s.height),
    topRight:    Offset(q.topRight.dx / s.width,    q.topRight.dy / s.height),
    bottomRight: Offset(q.bottomRight.dx / s.width, q.bottomRight.dy / s.height),
    bottomLeft:  Offset(q.bottomLeft.dx / s.width,  q.bottomLeft.dy / s.height),
  );

  CropQuad _toPixel(CropQuad q, Size s) => CropQuad(
    topLeft:     Offset(q.topLeft.dx * s.width,     q.topLeft.dy * s.height),
    topRight:    Offset(q.topRight.dx * s.width,    q.topRight.dy * s.height),
    bottomRight: Offset(q.bottomRight.dx * s.width, q.bottomRight.dy * s.height),
    bottomLeft:  Offset(q.bottomLeft.dx * s.width,  q.bottomLeft.dy * s.height),
  );

  // ── Crop callbacks ─────────────────────────────────────────────────────────

  /// Called by [CropEditor] on every drag update.
  void _onQuadChanged(CropQuad normQuad) {
    setState(() => _normQuad = normQuad);
    // Persist immediately so a page switch never loses the edit.
    final size = _rawImageSize;
    if (size != null) {
      _session.setCropQuad(
          _session.pages[_activeIndex].id, _toPixel(normQuad, size));
    }
  }

  void _resetCrop() {
    final size = _rawImageSize;
    if (size == null) return;
    final fullQuad = CropQuad.fullImage(size.width, size.height);
    _session.setCropQuad(_session.pages[_activeIndex].id, fullQuad);
    setState(() => _normQuad = _toNorm(fullQuad, size));
  }

  void _redetect() async {
    final page = _session.pages[_activeIndex];
    final size = _rawImageSize;
    setState(() => _detecting = true);

    final detected = await EdgeDetectionService.detectCorners(page.rawFile);
    if (!mounted) return;

    final quad = detected ?? (size != null
        ? CropQuad.fullImage(size.width, size.height)
        : null);

    if (quad != null) {
      _session.setCropQuad(page.id, quad);
      setState(() {
        if (size != null) _normQuad = _toNorm(quad, size);
        _detecting = false;
      });
    } else {
      setState(() => _detecting = false);
    }
  }

  // ── Filter callbacks ───────────────────────────────────────────────────────

  void _onFilterSelected(DocumentFilter filter) {
    final page = _session.pages[_activeIndex];
    _session.setFilter(page.id, filter);
    setState(() {});
  }

  void _applyFilterToAll() {
    final filter = _session.pages[_activeIndex].filter;
    _session.applyFilterToAll(filter);
    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${filter.label} applied to all ${_session.count} pages'),
      backgroundColor: const Color(0xFF1E1E1E),
      duration: const Duration(seconds: 2),
    ));
  }

  // ── Delete page ────────────────────────────────────────────────────────────

  Future<void> _deletePage(int index) async {
    if (_session.count == 1) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Delete last page?',
              style: TextStyle(color: Colors.white)),
          content: const Text(
              'This is the only page. Deleting it will close the editor.',
              style: TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.white54))),
            TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete',
                    style: TextStyle(color: Colors.redAccent))),
          ],
        ),
      );
      if (confirmed != true) return;
      _session.removePage(_session.pages[index].id);
      if (mounted) Navigator.of(context).maybePop();
      return;
    }

    _session.removePage(_session.pages[index].id);
    final newIndex = index >= _session.count ? _session.count - 1 : index;
    await _loadPage(newIndex);
  }

  // ── Process & done ─────────────────────────────────────────────────────────
  //
  // The user may tap Done multiple times (adjust crop → Done → inspect →
  // come back → adjust → Done again). Each call re-processes from the
  // latest quad/filter stored in the session.

  Future<void> _onDone() async {
    // Show processing dialog.
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ProcessingDialog(),
    );

    for (final page in _session.pages) {
      _session.setProcessing(page.id, true);
      final result = await ImageProcessor.process(page);
      _session.setProcessedFile(page.id, result);
      _session.setProcessing(page.id, false);
    }

    if (!mounted) return;
    Navigator.of(context).pop(); // close processing dialog

    _showDoneSummary();
  }

  void _showDoneSummary() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DoneSummarySheet(
        session: _session,
        // "Keep editing" simply pops the sheet — the editor is still beneath.
        onKeepEditing: () => Navigator.of(context).pop(),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: SafeArea(child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      children: [
        _buildTopBar(),
        Expanded(child: _buildEditorArea()),
        _buildFilterStrip(),
        _buildPageRail(),
      ],
    );
  }

  // ── Top bar ────────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: const Color(0xFF1A1A1A),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: 'Back',
          ),

          const Spacer(),

          Text(
            'Page ${_activeIndex + 1} of ${_session.count}',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),

          const Spacer(),

          // Crop toggle — switches between crop-handle mode and free-pan mode.
          IconButton(
            onPressed: () => setState(() => _cropMode = !_cropMode),
            icon: Icon(
              Icons.crop,
              color: _cropMode ? const Color(0xFF00E676) : Colors.white70,
            ),
            tooltip: _cropMode ? 'Hide crop handles' : 'Show crop handles',
          ),

          if (_cropMode) ...[
            // Reset to full image.
            IconButton(
              onPressed: _resetCrop,
              icon: const Icon(Icons.crop_free, color: Colors.white54),
              tooltip: 'Reset to full image',
            ),
            // Re-run auto-detect.
            IconButton(
              onPressed: _detecting ? null : _redetect,
              icon: const Icon(Icons.auto_fix_high, color: Colors.white54),
              tooltip: 'Re-detect edges',
            ),
          ],

          // Done — processes all pages and shows the export sheet.
          TextButton(
            onPressed: _onDone,
            child: const Text(
              'Done',
              style: TextStyle(
                color: Color(0xFF00E676),
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Editor area ────────────────────────────────────────────────────────────
  //
  // Key insight: the crop overlay must be positioned *exactly* over the
  // rendered portion of the image. Flutter's Image widget with BoxFit.contain
  // letterboxes the image; we must compute the same letterbox rect and size
  // the overlay widget to match it precisely.
  //
  // We do this with [_FittedImageWithOverlay], which uses a single
  // LayoutBuilder to measure available space, computes the letterbox rect,
  // places the image, and stacks the overlay at the same offset and size.
  //
  // During crop mode we disable InteractiveViewer so that pan drags are not
  // consumed by the viewer before reaching the crop handles.

  Widget _buildEditorArea() {
    if (_session.isEmpty) {
      return const Center(
          child: Text('No pages', style: TextStyle(color: Colors.white38)));
    }

    final page = _session.pages[_activeIndex];

    return Stack(
      fit: StackFit.expand,
      children: [
        _FittedImageWithOverlay(
          imageFile:   page.rawFile,
          normQuad:    _normQuad,
          cropMode:    _cropMode,
          onQuadChanged: _onQuadChanged,
        ),

        // Detecting spinner (while edge detection runs for this page).
        if (_detecting)
          Container(
            color: Colors.black38,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF00E676)),
                  SizedBox(height: 14),
                  Text('Detecting edges…',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                ],
              ),
            ),
          ),

        // Per-page processing spinner.
        if (page.isProcessing)
          const Center(child: CircularProgressIndicator(
              color: Color(0xFF00E676))),
      ],
    );
  }

  // ── Filter strip ───────────────────────────────────────────────────────────

  Widget _buildFilterStrip() {
    if (_session.isEmpty) return const SizedBox.shrink();
    final page = _session.pages[_activeIndex];

    return Container(
      color: const Color(0xFF181818),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: FilterStrip(
        previewFile:      page.rawFile,
        selectedFilter:   page.filter,
        onFilterSelected: _onFilterSelected,
        onApplyToAll:     _session.count > 1 ? _applyFilterToAll : null,
      ),
    );
  }

  // ── Page thumbnail rail ────────────────────────────────────────────────────

  Widget _buildPageRail() {
    return Container(
      height: 90,
      color: const Color(0xFF141414),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        itemCount: _session.count,
        itemBuilder: (_, i) {
          final page     = _session.pages[i];
          final isActive = i == _activeIndex;

          return GestureDetector(
            onTap:      () => _loadPage(i),
            onLongPress: () => _deletePage(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 52,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isActive
                      ? const Color(0xFF00E676)
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.file(page.displayFile, fit: BoxFit.cover),
                  ),
                  // Page number badge.
                  Positioned(
                    bottom: 2,
                    left: 3,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text('${i + 1}',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 9)),
                    ),
                  ),
                  // Delete button.
                  Positioned(
                    top: 2, right: 2,
                    child: GestureDetector(
                      onTap: () => _deletePage(i),
                      child: Container(
                        width: 18, height: 18,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.65),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close,
                            color: Colors.white, size: 11),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _FittedImageWithOverlay
// ─────────────────────────────────────────────────────────────────────────────
//
// This widget solves the overlay-alignment problem precisely:
//
//   1. It measures the available viewport via LayoutBuilder.
//   2. It decodes the image dimensions once (cached via didUpdateWidget).
//   3. It computes BoxFit.contain letterbox geometry — the exact same
//      rectangle that Flutter's Image widget renders the pixels into.
//   4. It positions a SizedBox at that rectangle and mounts the CropEditor
//      (or just the image in pan mode) inside it.
//
// Because both the image and the overlay are children of the same Stack
// and positioned with identical offsets/sizes, the handles are always
// perfectly aligned regardless of image aspect ratio or screen size.

class _FittedImageWithOverlay extends StatefulWidget {
  final File imageFile;
  final CropQuad normQuad;
  final bool cropMode;
  final ValueChanged<CropQuad> onQuadChanged;

  const _FittedImageWithOverlay({
    required this.imageFile,
    required this.normQuad,
    required this.cropMode,
    required this.onQuadChanged,
  });

  @override
  State<_FittedImageWithOverlay> createState() =>
      _FittedImageWithOverlayState();
}

class _FittedImageWithOverlayState extends State<_FittedImageWithOverlay> {
  Size? _imageSize;
  String? _loadedPath;

  @override
  void initState() {
    super.initState();
    _loadImageSize();
  }

  @override
  void didUpdateWidget(_FittedImageWithOverlay old) {
    super.didUpdateWidget(old);
    if (old.imageFile.path != widget.imageFile.path) {
      _loadImageSize();
    }
  }

  Future<void> _loadImageSize() async {
    final path = widget.imageFile.path;
    try {
      final bytes = await widget.imageFile.readAsBytes();
      final codec = await instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      // Only update if the path hasn't changed while we were waiting.
      if (widget.imageFile.path == path) {
        setState(() {
          _imageSize  = Size(frame.image.width.toDouble(),
              frame.image.height.toDouble());
          _loadedPath = path;
        });
      }
      frame.image.dispose();
    } catch (_) {}
  }

  /// Compute the [Rect] that BoxFit.contain maps the image into within
  /// [viewportSize].  This mirrors Flutter's internal FittedBox maths.
  Rect _fittedRect(Size viewportSize) {
    final imgSize = _imageSize!;
    final imgRatio   = imgSize.width / imgSize.height;
    final viewRatio  = viewportSize.width / viewportSize.height;

    double fitW, fitH;
    if (viewRatio > imgRatio) {
      // Viewport is wider than image → constrained by height.
      fitH = viewportSize.height;
      fitW = fitH * imgRatio;
    } else {
      // Viewport is taller than image → constrained by width.
      fitW = viewportSize.width;
      fitH = fitW / imgRatio;
    }

    // Centre within the viewport.
    final dx = (viewportSize.width  - fitW) / 2;
    final dy = (viewportSize.height - fitH) / 2;
    return Rect.fromLTWH(dx, dy, fitW, fitH);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;

        if (_imageSize == null) {
          // Still loading dimensions — show the raw image alone.
          return Image.file(widget.imageFile, fit: BoxFit.contain,
              width: viewport.width, height: viewport.height);
        }

        final rect = _fittedRect(viewport);

        return Stack(
          fit: StackFit.expand,
          children: [
            // ── Base image ─────────────────────────────────────────────────
            // When cropMode is OFF we wrap in InteractiveViewer so the user
            // can inspect the image at full resolution. When cropMode is ON
            // InteractiveViewer is removed so it doesn't swallow the drag
            // gestures meant for the crop handles.
            if (!widget.cropMode)
              InteractiveViewer(
                minScale: 0.8,
                maxScale: 5.0,
                child: Image.file(
                  widget.imageFile,
                  fit: BoxFit.contain,
                  width: viewport.width,
                  height: viewport.height,
                ),
              )
            else
              Image.file(
                widget.imageFile,
                fit: BoxFit.contain,
                width: viewport.width,
                height: viewport.height,
              ),

            // ── Crop overlay — sized and positioned to match the image ──────
            if (widget.cropMode)
              Positioned(
                left:   rect.left,
                top:    rect.top,
                width:  rect.width,
                height: rect.height,
                child: CropEditor(
                  normQuad:      widget.normQuad,
                  onQuadChanged: widget.onQuadChanged,
                ),
              ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ProcessingDialog
// ─────────────────────────────────────────────────────────────────────────────

class _ProcessingDialog extends StatelessWidget {
  const _ProcessingDialog();

  @override
  Widget build(BuildContext context) {
    return const AlertDialog(
      backgroundColor: Color(0xFF1E1E1E),
      content: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF00E676)),
            SizedBox(height: 20),
            Text('Processing pages…',
                style: TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// Done Summary Sheet — Save Images & Share
//
// pubspec.yaml dependencies needed:
//   gal: ^2.3.0
//   share_plus: ^10.0.0
//
// Android — AndroidManifest.xml (only needed for API < 29):
//   <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
//       android:maxSdkVersion="28"/>
//
// iOS — Info.plist:
//   <key>NSPhotoLibraryAddUsageDescription</key>
//   <string>$(PRODUCT_NAME) saves your scanned documents to Photos.</string>

class _DoneSummarySheet extends StatefulWidget {
  final CaptureSession session;
  final VoidCallback onKeepEditing;

  const _DoneSummarySheet({
    required this.session,
    required this.onKeepEditing,
  });

  @override
  State<_DoneSummarySheet> createState() => _DoneSummarySheetState();
}

class _DoneSummarySheetState extends State<_DoneSummarySheet> {
  // Which action is currently in progress (prevents double-taps).
  _Action? _busy;

  // Result banner shown after an action completes.
  _Result? _result;

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Returns the processed file for each page, falling back to the raw file
  /// if processing hasn't produced an output yet.
  List<File> get _files => widget.session.pages
      .map((p) => p.processedFile ?? p.rawFile)
      .toList();

  bool get _isMultiple => widget.session.count > 1;

  // ── Save to gallery ───────────────────────────────────────────────────────

  Future<void> _saveToGallery() async {
    if (_busy != null) return;
    setState(() {
      _busy   = _Action.save;
      _result = null;
    });

    try {
      // Request gallery access (gal handles the platform differences).
      final hasAccess = await Gal.hasAccess(toAlbum: true);
      if (!hasAccess) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) {
          _setResult(_Result.error('Gallery permission denied.'));
          return;
        }
      }

      final files = _files;
      int saved = 0;

      for (final file in files) {
        // putImage saves to the default Photos / Gallery album.
        // Pass album: 'AppName' if you want a dedicated sub-album.
        await Gal.putImage(file.path);
        saved++;
      }

      _setResult(_Result.success(
        saved == 1
            ? 'Image saved to gallery.'
            : '$saved images saved to gallery.',
      ));
    } on GalException catch (e) {
      _setResult(_Result.error(_galErrorMessage(e)));
    } catch (e) {
      _setResult(_Result.error('Could not save: $e'));
    }
  }

  // ── Share ─────────────────────────────────────────────────────────────────

  Future<void> _share() async {
    if (_busy != null) return;
    setState(() {
      _busy   = _Action.share;
      _result = null;
    });

    try {
      final files  = _files;
      final xFiles = files.map((f) => XFile(f.path)).toList();

      final params = ShareParams(
        files:   xFiles,
        // A subject line helps email clients pre-fill a subject.
        subject: _isMultiple
            ? 'Scanned documents (${files.length} images)'
            : 'Scanned document',
      );

      final result = await SharePlus.instance.share(params);

      if (result.status == ShareResultStatus.success) {
        _setResult(_Result.success('Shared successfully.'));
      } else if (result.status == ShareResultStatus.dismissed) {
        // User closed the share sheet — not an error, just clear the busy state.
        setState(() => _busy = null);
      } else {
        _setResult(_Result.error('Share was unavailable.'));
      }
    } catch (e) {
      _setResult(_Result.error('Could not share: $e'));
    }
  }

  void _setResult(_Result r) {
    if (!mounted) return;
    setState(() {
      _busy   = null;
      _result = r;
    });
  }

  String _galErrorMessage(GalException e) {
    return switch (e.type) {
      GalExceptionType.accessDenied    => 'Gallery permission denied.',
      GalExceptionType.notEnoughSpace  => 'Not enough storage space.',
      GalExceptionType.notSupportedFormat => 'Image format not supported.',
      GalExceptionType.unexpected      => 'An unexpected error occurred.',
    };
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final count = widget.session.count;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ────────────────────────────────────────────────────────
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Ready to export',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    count == 1
                        ? '1 page processed'
                        : '$count pages processed',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
              const Spacer(),
              TextButton(
                onPressed: widget.onKeepEditing,
                child: const Text(
                  'Edit more',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // ── Page thumbnails (quick preview) ───────────────────────────────
          if (count > 1) ...[
            SizedBox(
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: count,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final file = _files[i];
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: AspectRatio(
                      aspectRatio: 3 / 4,
                      child: Image.file(file, fit: BoxFit.cover),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
          ],

          // ── Result banner ─────────────────────────────────────────────────
          if (_result != null) ...[
            _ResultBanner(result: _result!),
            const SizedBox(height: 16),
          ],

          // ── Actions ───────────────────────────────────────────────────────
          _ActionTile(
            icon:     Icons.save_alt_rounded,
            label:    _isMultiple ? 'Save all to Gallery' : 'Save to Gallery',
            sublabel: _isMultiple
                ? 'Save ${count} images to your Photos / Gallery'
                : 'Save to your Photos / Gallery',
            loading:  _busy == _Action.save,
            onTap:    _saveToGallery,
          ),

          const SizedBox(height: 10),

          _ActionTile(
            icon:     Icons.ios_share_rounded,
            label:    _isMultiple ? 'Share all images' : 'Share image',
            sublabel: _isMultiple
                ? 'Send ${count} images via any app'
                : 'Send via WhatsApp, email, and more',
            loading:  _busy == _Action.share,
            onTap:    _share,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Action tile
// ─────────────────────────────────────────────────────────────────────────────

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   sublabel;
  final bool     loading;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: AnimatedOpacity(
        opacity: loading ? 0.6 : 1.0,
        duration: const Duration(milliseconds: 200),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            children: [
              // Icon
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF00E676).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: const Color(0xFF00E676), size: 20),
              ),
              const SizedBox(width: 14),
              // Labels
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(sublabel,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Trailing: spinner or chevron
              if (loading)
                const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(
                      color: Color(0xFF00E676), strokeWidth: 2),
                )
              else
                const Icon(Icons.chevron_right,
                    color: Colors.white24, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Result banner
// ─────────────────────────────────────────────────────────────────────────────

class _ResultBanner extends StatelessWidget {
  final _Result result;
  const _ResultBanner({required this.result});

  @override
  Widget build(BuildContext context) {
    final isSuccess = result.isSuccess;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isSuccess
            ? const Color(0xFF00E676).withOpacity(0.10)
            : Colors.redAccent.withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSuccess
              ? const Color(0xFF00E676).withOpacity(0.40)
              : Colors.redAccent.withOpacity(0.40),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isSuccess ? Icons.check_circle_outline : Icons.error_outline,
            color: isSuccess ? const Color(0xFF00E676) : Colors.redAccent,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              result.message,
              style: TextStyle(
                color: isSuccess
                    ? const Color(0xFF00E676)
                    : Colors.redAccent,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal data types
// ─────────────────────────────────────────────────────────────────────────────

enum _Action { save, share }

class _Result {
  final String message;
  final bool   isSuccess;

  const _Result.success(this.message) : isSuccess = true;
  const _Result.error(this.message)   : isSuccess = false;
}