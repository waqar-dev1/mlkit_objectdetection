import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../screens/providers/capture_session.dart';

/// Horizontal scrollable strip of filter thumbnails.
///
/// Each tile shows a live preview of the filter applied to [previewFile]
/// (a small version of the current page so rendering is fast).
class FilterStrip extends StatefulWidget {
  /// Small image file used to generate filter previews.
  final File previewFile;

  /// Currently active filter for this page.
  final DocumentFilter selectedFilter;

  /// Called when the user taps a filter tile.
  final ValueChanged<DocumentFilter> onFilterSelected;

  /// If true, shows an "Apply to All" button at the end of the strip.
  final VoidCallback? onApplyToAll;

  const FilterStrip({
    super.key,
    required this.previewFile,
    required this.selectedFilter,
    required this.onFilterSelected,
    this.onApplyToAll,
  });

  @override
  State<FilterStrip> createState() => _FilterStripState();
}

class _FilterStripState extends State<FilterStrip> {
  // Keyed by filter — we generate previews lazily and cache them.
  final Map<DocumentFilter, Image> _cache = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _generatePreviews();
  }

  @override
  void didUpdateWidget(FilterStrip old) {
    super.didUpdateWidget(old);
    if (old.previewFile.path != widget.previewFile.path) {
      setState(() {
        _cache.clear();
        _loading = true;
      });
      _generatePreviews();
    }
  }

  Future<void> _generatePreviews() async {
    final bytes = await widget.previewFile.readAsBytes();
    img.Image? source = img.decodeImage(bytes);
    if (source == null) return;

    // Downscale to thumbnail size for speed
    source = img.copyResize(source, width: 120);

    for (final filter in DocumentFilter.values) {
      if (!mounted) return;
      final processed = _applyFilterPreview(source!, filter);
      final thumb     = Image.memory(
        img.encodeJpg(processed, quality: 80),
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
      if (mounted) setState(() => _cache[filter] = thumb);
    }

    if (mounted) setState(() => _loading = false);
  }

  img.Image _applyFilterPreview(img.Image src, DocumentFilter filter) {
    switch (filter) {
      case DocumentFilter.original:
        return src;
      case DocumentFilter.grayscale:
        return img.grayscale(src);
      case DocumentFilter.blackWhite:
        return _threshold(img.grayscale(src), 128);
      case DocumentFilter.magic:
        return img.adjustColor(src,
            contrast: 1.25, brightness: 1.05, saturation: 0.95);
      case DocumentFilter.vivid:
        return img.adjustColor(src,
            saturation: 1.4, contrast: 1.2, brightness: 1.02);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 108,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          ...DocumentFilter.values.map((f) => _FilterTile(
            filter:   f,
            thumb:    _cache[f],
            loading:  _loading,
            selected: widget.selectedFilter == f,
            onTap:    () => widget.onFilterSelected(f),
          )),

          // "Apply to All" at the end — only shown when handler provided
          if (widget.onApplyToAll != null)
            _ApplyAllTile(onTap: widget.onApplyToAll!),
        ],
      ),
    );
  }
}

// ── Filter tile ────────────────────────────────────────────────────────────────

class _FilterTile extends StatelessWidget {
  final DocumentFilter filter;
  final Image? thumb;
  final bool loading;
  final bool selected;
  final VoidCallback onTap;

  static const _tileW = 68.0;
  static const _tileH = 80.0;

  const _FilterTile({
    required this.filter,
    required this.thumb,
    required this.loading,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: _tileW,
        margin: const EdgeInsets.only(right: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Thumbnail
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: _tileW,
              height: _tileH,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected
                      ? const Color(0xFF00E676)
                      : Colors.white24,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6.5),
                child: loading || thumb == null
                    ? const ColoredBox(
                  color: Color(0xFF1E1E1E),
                  child: Center(
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.white38,
                      ),
                    ),
                  ),
                )
                    : thumb!,
              ),
            ),

            const SizedBox(height: 5),

            // Label
            Text(
              filter.label,
              style: TextStyle(
                color: selected
                    ? const Color(0xFF00E676)
                    : Colors.white60,
                fontSize: 11,
                fontWeight: selected
                    ? FontWeight.w600
                    : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Apply-to-all tile ──────────────────────────────────────────────────────────

class _ApplyAllTile extends StatelessWidget {
  final VoidCallback onTap;

  const _ApplyAllTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 68,
        margin: const EdgeInsets.only(left: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 80,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white24),
                color: Colors.white.withOpacity(0.05),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.auto_awesome,
                      color: Colors.white60, size: 22),
                  SizedBox(height: 4),
                  Text('All',
                      style: TextStyle(
                          color: Colors.white60, fontSize: 10)),
                ],
              ),
            ),
            const SizedBox(height: 5),
            const Text('Apply All',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
// ── Manual threshold helper ───────────────────────────────────────────────────

img.Image _threshold(img.Image src, int level) {
  final out = img.Image(width: src.width, height: src.height);
  for (final pixel in src) {
    final lum = pixel.r.toInt();
    final val = lum >= level ? 255 : 0;
    out.setPixelRgb(pixel.x, pixel.y, val, val, val);
  }
  return out;
}