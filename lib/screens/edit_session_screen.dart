import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ml_objecdetection/screens/providers/capture_session.dart';

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
/// The user taps a thumbnail at the bottom to switch the active page.
/// Crop and filter are per-page but "Apply to All" propagates the current
/// filter to every page.
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

  /// Whether the crop editor is visible (vs just the image).
  bool _cropMode = true;

  /// Image size of the active page's raw file (for coord conversion).
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
      _activeIndex   = index;
      _rawImageSize  = null;
    });

    final page = _session.pages[index];

    // Load image size
    final size = await _getImageSize(page.rawFile);
    if (!mounted) return;
    setState(() => _rawImageSize = size);

    // Run edge detection if we don't have a quad yet
    if (page.cropQuad == null && size != null) {
      final detected = await EdgeDetectionService.detectCorners(page.rawFile);
      if (!mounted) return;

      final quad = detected ?? CropQuad.fullImage(size.width, size.height);
      _session.setCropQuad(page.id, quad);
      setState(() => _normQuad = _toNorm(quad, size));
    } else if (page.cropQuad != null && size != null) {
      setState(() => _normQuad = _toNorm(page.cropQuad!, size));
    } else {
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
      final bytes    = await file.readAsBytes();
      final codec    = await instantiateImageCodec(bytes);
      final frame    = await codec.getNextFrame();
      final w        = frame.image.width.toDouble();
      final h        = frame.image.height.toDouble();
      frame.image.dispose();
      return Size(w, h);
    } catch (_) {
      return null;
    }
  }

  // ── Coordinate conversion ──────────────────────────────────────────────────

  /// Convert a pixel-space quad to normalised [0..1] quad.
  CropQuad _toNorm(CropQuad q, Size s) => CropQuad(
    topLeft:     Offset(q.topLeft.dx / s.width,     q.topLeft.dy / s.height),
    topRight:    Offset(q.topRight.dx / s.width,    q.topRight.dy / s.height),
    bottomRight: Offset(q.bottomRight.dx / s.width, q.bottomRight.dy / s.height),
    bottomLeft:  Offset(q.bottomLeft.dx / s.width,  q.bottomLeft.dy / s.height),
  );

  /// Convert a normalised quad back to pixel space.
  CropQuad _toPixel(CropQuad q, Size s) => CropQuad(
    topLeft:     Offset(q.topLeft.dx * s.width,     q.topLeft.dy * s.height),
    topRight:    Offset(q.topRight.dx * s.width,    q.topRight.dy * s.height),
    bottomRight: Offset(q.bottomRight.dx * s.width, q.bottomRight.dy * s.height),
    bottomLeft:  Offset(q.bottomLeft.dx * s.width,  q.bottomLeft.dy * s.height),
  );

  // ── Crop callbacks ─────────────────────────────────────────────────────────

  void _onQuadChanged(CropQuad normQuad) {
    setState(() => _normQuad = normQuad);
    // Store in pixel space immediately so we don't lose it on page switch
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

  // ── Process & done ─────────────────────────────────────────────────────────

  Future<void> _onDone() async {
    // Process every page that hasn't been processed yet (or has been changed).
    final pages = _session.pages;

    // Show processing dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ProcessingDialog(),
    );

    for (final page in pages) {
      _session.setProcessing(page.id, true);
      final result = await ImageProcessor.process(page);
      _session.setProcessedFile(page.id, result);
    }

    if (!mounted) return;
    Navigator.of(context).pop(); // close dialog

    // TODO Phase 4: navigate to export/share screen
    // For now show a summary
    _showDoneSummary();
  }

  void _showDoneSummary() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DoneSummarySheet(session: _session),
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
          // Back
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: 'Back',
          ),

          const Spacer(),

          // Page indicator
          Text(
            'Page ${_activeIndex + 1} of ${_session.count}',
            style: const TextStyle(
                color: Colors.white70, fontSize: 13),
          ),

          const Spacer(),

          // Crop toggle
          IconButton(
            onPressed: () => setState(() => _cropMode = !_cropMode),
            icon: Icon(
              Icons.crop,
              color: _cropMode ? const Color(0xFF00E676) : Colors.white70,
            ),
            tooltip: _cropMode ? 'Hide crop' : 'Show crop',
          ),

          // Reset crop
          if (_cropMode)
            IconButton(
              onPressed: _resetCrop,
              icon: const Icon(Icons.crop_free, color: Colors.white54),
              tooltip: 'Reset crop to full image',
            ),

          // Done
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

  Widget _buildEditorArea() {
    if (_session.isEmpty) {
      return const Center(
          child: Text('No pages', style: TextStyle(color: Colors.white38)));
    }

    final page = _session.pages[_activeIndex];

    return LayoutBuilder(builder: (_, constraints) {
      return Stack(
        fit: StackFit.expand,
        children: [
          // Image
          Center(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 4.0,
              child: Image.file(
                page.rawFile,
                fit: BoxFit.contain,
              ),
            ),
          ),

          // Crop overlay
          if (_cropMode)
            Center(
              child: AspectRatioImageOverlay(
                imageFile: page.rawFile,
                availableSize: constraints.biggest,
                child: CropEditor(
                  normQuad:     _normQuad,
                  onQuadChanged: _onQuadChanged,
                ),
              ),
            ),

          // Processing spinner for this page
          if (page.isProcessing)
            const Center(child: CircularProgressIndicator(
                color: Color(0xFF00E676))),
        ],
      );
    });
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
            onTap: () => _loadPage(i),
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
                    child: Image.file(
                      page.displayFile,
                      fit: BoxFit.cover,
                    ),
                  ),
                  // Page number badge
                  Positioned(
                    bottom: 2,
                    right: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 9),
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

// ── Helpers ────────────────────────────────────────────────────────────────────

/// Sizes a child widget to match the rendered size of [imageFile] inside
/// [availableSize] (respecting aspect ratio), so overlays align exactly.
class AspectRatioImageOverlay extends StatefulWidget {
  final File imageFile;
  final Size availableSize;
  final Widget child;

  const AspectRatioImageOverlay({
    super.key,
    required this.imageFile,
    required this.availableSize,
    required this.child,
  });

  @override
  State<AspectRatioImageOverlay> createState() =>
      _AspectRatioImageOverlayState();
}

class _AspectRatioImageOverlayState extends State<AspectRatioImageOverlay> {
  Size? _imageSize;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AspectRatioImageOverlay old) {
    super.didUpdateWidget(old);
    if (old.imageFile.path != widget.imageFile.path) _load();
  }

  Future<void> _load() async {
    final bytes = await widget.imageFile.readAsBytes();
    final codec = await instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() => _imageSize =
          Size(frame.image.width.toDouble(), frame.image.height.toDouble()));
      frame.image.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_imageSize == null) return const SizedBox.shrink();

    final imgRatio     = _imageSize!.width / _imageSize!.height;
    final screenRatio  = widget.availableSize.width / widget.availableSize.height;

    final double w, h;
    if (screenRatio > imgRatio) {
      h = widget.availableSize.height;
      w = h * imgRatio;
    } else {
      w = widget.availableSize.width;
      h = w / imgRatio;
    }

    return SizedBox(width: w, height: h, child: widget.child);
  }
}

// ── Processing dialog ──────────────────────────────────────────────────────────

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

// ── Done summary sheet ─────────────────────────────────────────────────────────

class _DoneSummarySheet extends StatelessWidget {
  final CaptureSession session;
  const _DoneSummarySheet({required this.session});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Ready to export',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('${session.count} pages processed',
              style: const TextStyle(color: Colors.white54, fontSize: 14)),
          const SizedBox(height: 24),

          // Export actions — Phase 4 will wire these up
          _ActionRow(
            icon: Icons.picture_as_pdf,
            label: 'Export as PDF',
            onTap: () {},
          ),
          const SizedBox(height: 12),
          _ActionRow(
            icon: Icons.image,
            label: 'Save as Images',
            onTap: () {},
          ),
          const SizedBox(height: 12),
          _ActionRow(
            icon: Icons.share,
            label: 'Share',
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF00E676), size: 22),
            const SizedBox(width: 14),
            Text(label,
                style: const TextStyle(
                    color: Colors.white, fontSize: 15)),
            const Spacer(),
            const Icon(Icons.chevron_right,
                color: Colors.white38, size: 20),
          ],
        ),
      ),
    );
  }
}
