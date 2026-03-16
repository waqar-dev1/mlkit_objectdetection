import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'package:ml_objecdetection/screens/providers/capture_session.dart';
import '../utils/edge_detection_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Public result type returned by the debug pipeline
// ─────────────────────────────────────────────────────────────────────────────

/// One labelled stage image from the debug pipeline.
class _Stage {
  final String   label;
  final Uint8List png;   // PNG-encoded bytes, ready for Image.memory()
  const _Stage(this.label, this.png);
}

/// Everything the debug pipeline produces for one image.
class EdgeDebugResult {
  /// Original image re-encoded as PNG (for consistent display).
  final Uint8List originalPng;

  /// All intermediate mats as labelled PNGs (Pass A masks, Canny edges, etc.).
  final List<_Stage> stages;

  /// The final CropQuad returned by the real service (null = fallback/failed).
  final CropQuad? quad;

  /// Which pass succeeded: 'A', 'B', 'C', or 'fallback'.
  final String passName;

  const EdgeDebugResult({
    required this.originalPng,
    required this.stages,
    required this.quad,
    required this.passName,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Debug pipeline  (runs in an Isolate — same as the real service)
// ─────────────────────────────────────────────────────────────────────────────

/// Mirrors _opencvPipeline() but captures every intermediate mat as PNG.
/// Returns a flat list: [originalPng, ...stagePngs, quadJson]
/// We encode the quad as the last element (a String) so we can pass plain
/// objects through Isolate.run().
Future<EdgeDebugResult> runDebugPipeline(Uint8List bytes) async {
  // Isolate.run can only pass back plain objects, so we return a Map.
  final raw = await Isolate.run(() => _debugPipeline(bytes));

  final stages = <_Stage>[];
  for (final s in raw['stages'] as List) {
    stages.add(_Stage(s['label'] as String, s['png'] as Uint8List));
  }

  CropQuad? quad;
  final qm = raw['quad'] as Map<String, double>?;
  if (qm != null) {
    quad = CropQuad(
      topLeft:     ui.Offset(qm['tlx']!, qm['tly']!),
      topRight:    ui.Offset(qm['trx']!, qm['try_']!),
      bottomRight: ui.Offset(qm['brx']!, qm['bry']!),
      bottomLeft:  ui.Offset(qm['blx']!, qm['bly']!),
    );
  }

  return EdgeDebugResult(
    originalPng: raw['originalPng'] as Uint8List,
    stages:      stages,
    quad:        quad,
    passName:    raw['passName'] as String,
  );
}

// ── Isolate body ─────────────────────────────────────────────────────────────

Map<String, dynamic> _debugPipeline(Uint8List bytes) {
  final stages = <Map<String, dynamic>>[];

  void capture(String label, cv.Mat mat) {
    if (mat.isEmpty) return;
    // imencode returns PNG bytes
    final (_, encoded) = cv.imencode('.png', mat);
    stages.add({'label': label, 'png': encoded});
  }

  final original = cv.imdecode(bytes, cv.IMREAD_COLOR);
  if (original.isEmpty) {
    return {'originalPng': bytes, 'stages': stages,
      'quad': null, 'passName': 'error'};
  }

  final (_, origPng) = cv.imencode('.png', original);
  final origW = original.cols.toDouble();
  final origH = original.rows.toDouble();

  // Scale down
  const maxSide = 800;
  final scale = maxSide / math.max(origW, origH);
  final wW = math.max(4, (origW * scale).round());
  final wH = math.max(4, (origH * scale).round());
  final small = cv.resize(original, (wW, wH));
  capture('Resized (${wW}x$wH)', small);

  final minArea = wW * wH * 0.08;
  final maxArea = wW * wH * 0.92;

  // ── Pass A ──────────────────────────────────────────────────────────────
  String passName = 'fallback';
  CropQuad? finalQuad;

  try {
    final hsv    = cv.cvtColor(small, cv.COLOR_BGR2HSV);
    final sChan  = cv.extractChannel(hsv, 1);
    final vChan  = cv.extractChannel(hsv, 2);

    final (_, maskV)    = cv.threshold(vChan, 100, 255, cv.THRESH_BINARY);
    final (_, maskSInv) = cv.threshold(sChan,  80, 255, cv.THRESH_BINARY_INV);
    final mask = cv.bitwiseAND(maskV, maskSInv);
    capture('Pass A — HSV mask (V>100 & S<80)', mask);

    final bigKernel   = cv.getStructuringElement(cv.MORPH_RECT, (25, 25));
    final closed      = cv.morphologyEx(mask, cv.MORPH_CLOSE, bigKernel);
    capture('Pass A — After close (25×25)', closed);

    final smallKernel = cv.getStructuringElement(cv.MORPH_RECT, (7, 7));
    final opened      = cv.morphologyEx(closed, cv.MORPH_OPEN, smallKernel);
    _burnBorderDebug(opened, wW, wH, 0.04);
    capture('Pass A — After open + border burn', opened);

    // Draw contours on a colour copy for easy visualisation
    final (contours, _) = cv.findContours(
        opened, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

    final contourVis = small.clone();
    for (int i = 0; i < contours.length; i++) {
      cv.drawContours(contourVis, contours, i, cv.Scalar(0, 255, 0), thickness: 2);
    }
    capture('Pass A — All contours (${contours.length})', contourVis);

    // Find best quad from Pass A
    if (contours.isNotEmpty) {
      final sorted = contours.toList()
        ..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));
      final candidates = sorted
          .where((c) { final a = cv.contourArea(c); return a >= minArea && a <= maxArea; })
          .toList();

      if (candidates.isNotEmpty) {
        final quadA = _bestQuadDebug(candidates.first, wW, wH, minArea, maxArea);
        if (quadA != null) {
          final vis = small.clone();
          _drawQuad(vis, quadA);
          capture('Pass A — Detected quad', vis);

          final result = _scaleQuadDebug(quadA, origW / wW, origH / wH);
          if (_isPlausibleDebug(result, origW, origH)) {
            finalQuad = result;
            passName  = 'A (HSV)';
          } else {
            capture('Pass A — FAILED plausibility check', vis);
          }
        }
      }
    }
  } catch (e) {
    debugPrint('Debug Pass A error: $e');
  }

  // ── Pass B & C ───────────────────────────────────────────────────────────
  if (finalQuad == null) {
    try {
      final grey     = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
      capture('Greyscale', grey);

      final bilateral = cv.bilateralFilter(grey, 9, 75, 75);
      final filtered  = bilateral.isEmpty ? grey : bilateral;
      capture('Bilateral filter (d=9, σ=75)', filtered);

      final filteredBurned = filtered.clone();
      _burnBorderDebug(filteredBurned, wW, wH, 0.04);
      capture('After border burn', filteredBurned);

      // ── Canny ──────────────────────────────────────────────────────────
      final data   = filteredBurned.data;
      final median = _medianDebug(data);
      final lo     = math.max(10.0,  median * 0.33);
      final hi     = math.min(250.0, median * 1.33);
      final edges  = cv.canny(filteredBurned, lo, hi);
      capture('Pass B — Canny edges (lo=${lo.toInt()} hi=${hi.toInt()})', edges);

      final kernel  = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
      final dilated = cv.dilate(edges, kernel, iterations: 2);
      final closed  = cv.erode(dilated, kernel, iterations: 1);
      _burnBorderDebug(closed, wW, wH, 0.04);
      capture('Pass B — Dilate×2 + Erode×1 + border burn', closed);

      final (contoursB, _) = cv.findContours(
          closed, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
      final contourVisB = small.clone();
      for (int i = 0; i < contoursB.length; i++) {
        cv.drawContours(contourVisB, contoursB, i, cv.Scalar(255, 100, 0), thickness: 2);
      }
      capture('Pass B — All contours (${contoursB.length})', contourVisB);

      final candidatesB = contoursB.toList()
          .where((c) { final a = cv.contourArea(c); return a >= minArea && a <= maxArea; })
          .toList()
        ..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));

      for (final c in candidatesB.take(5)) {
        final quadB = _bestQuadDebug(c, wW, wH, minArea, maxArea);
        if (quadB != null) {
          final vis = small.clone();
          _drawQuad(vis, quadB);
          capture('Pass B — Detected quad', vis);
          final result = _scaleQuadDebug(quadB, origW / wW, origH / wH);
          if (_isPlausibleDebug(result, origW, origH)) {
            finalQuad = result;
            passName  = 'B (Canny)';
          }
          break;
        }
      }

      // ── Otsu ───────────────────────────────────────────────────────────
      if (finalQuad == null) {
        final (_, otsuMask) = cv.threshold(
            filteredBurned, 0, 255, cv.THRESH_BINARY | cv.THRESH_OTSU);
        _burnBorderDebug(otsuMask, wW, wH, 0.04);
        capture('Pass C — Otsu mask', otsuMask);

        final (contoursC, _) = cv.findContours(
            otsuMask, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
        final sortedC = contoursC.toList()
          ..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));

        for (final c in sortedC) {
          if (cv.contourArea(c) > maxArea) continue;
          final bbox = cv.boundingRect(c);
          final quadC = CropQuad(
            topLeft:     ui.Offset(bbox.x.toDouble(), bbox.y.toDouble()),
            topRight:    ui.Offset((bbox.x + bbox.width).toDouble(), bbox.y.toDouble()),
            bottomRight: ui.Offset((bbox.x + bbox.width).toDouble(), (bbox.y + bbox.height).toDouble()),
            bottomLeft:  ui.Offset(bbox.x.toDouble(), (bbox.y + bbox.height).toDouble()),
          );
          final vis = small.clone();
          _drawQuad(vis, quadC);
          capture('Pass C — Otsu bounding rect', vis);
          final result = _scaleQuadDebug(quadC, origW / wW, origH / wH);
          if (_isPlausibleDebug(result, origW, origH)) {
            finalQuad = result;
            passName  = 'C (Otsu)';
          }
          break;
        }
      }
    } catch (e) {
      debugPrint('Debug Pass B/C error: $e');
    }
  }

  // ── Final result drawn on original ───────────────────────────────────────
  if (finalQuad != null) {
    final resultVis = cv.resize(original, (wW, wH));
    final scaledQuad = _toWorkingSpace(finalQuad!, origW / wW, origH / wH);
    _drawQuad(resultVis, scaledQuad);
    capture('✓ Final result — Pass $passName', resultVis);
  } else {
    passName = 'fallback';
    capture('✗ All passes failed — inset fallback used', small);
  }

  // Serialise quad to plain map for Isolate boundary
  Map<String, double>? quadMap;
  if (finalQuad != null) {
    quadMap = {
      'tlx': finalQuad!.topLeft.dx,     'tly': finalQuad!.topLeft.dy,
      'trx': finalQuad!.topRight.dx,    'try_': finalQuad!.topRight.dy,
      'brx': finalQuad!.bottomRight.dx, 'bry': finalQuad!.bottomRight.dy,
      'blx': finalQuad!.bottomLeft.dx,  'bly': finalQuad!.bottomLeft.dy,
    };
  }

  return {
    'originalPng': origPng,
    'stages':      stages,
    'quad':        quadMap,
    'passName':    passName,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Isolated helpers (duplicated here to keep the Isolate self-contained)
// ─────────────────────────────────────────────────────────────────────────────

void _burnBorderDebug(cv.Mat mat, int w, int h, double ratio) {
  if (mat.isEmpty) return;
  final bx = math.max(1, (w * ratio).round());
  final by = math.max(1, (h * ratio).round());
  cv.rectangle(mat, cv.Rect(0,      0,      w,  by), cv.Scalar.black, thickness: -1);
  cv.rectangle(mat, cv.Rect(0,  h - by,     w,  by), cv.Scalar.black, thickness: -1);
  cv.rectangle(mat, cv.Rect(0,      0,      bx,  h), cv.Scalar.black, thickness: -1);
  cv.rectangle(mat, cv.Rect(w - bx, 0,      bx,  h), cv.Scalar.black, thickness: -1);
}

double _medianDebug(Uint8List data) {
  final hist = List<int>.filled(256, 0);
  for (int i = 0; i < data.length; i++) hist[data[i]]++;
  final half = data.length ~/ 2;
  int cumul = 0;
  for (int i = 0; i < 256; i++) {
    cumul += hist[i];
    if (cumul >= half) return i.toDouble();
  }
  return 127.0;
}

CropQuad? _bestQuadDebug(
    cv.VecPoint contour, int wW, int wH, double minArea, double maxArea) {
  final peri = cv.arcLength(contour, true);
  if (peri < 1) return null;
  for (final eps in [0.02, 0.03, 0.04, 0.05, 0.07, 0.10]) {
    final approx = cv.approxPolyDP(contour, eps * peri, true);
    if (approx.length == 4) {
      final area = cv.contourArea(approx);
      if (area >= minArea && area <= maxArea) {
        final ordered = _orderPtsDebug(approx.toList());
        return CropQuad(
          topLeft:     ui.Offset(ordered[0].x.toDouble(), ordered[0].y.toDouble()),
          topRight:    ui.Offset(ordered[1].x.toDouble(), ordered[1].y.toDouble()),
          bottomRight: ui.Offset(ordered[2].x.toDouble(), ordered[2].y.toDouble()),
          bottomLeft:  ui.Offset(ordered[3].x.toDouble(), ordered[3].y.toDouble()),
        );
      }
    }
  }
  final bbox = cv.boundingRect(contour);
  return CropQuad(
    topLeft:     ui.Offset(bbox.x.toDouble(), bbox.y.toDouble()),
    topRight:    ui.Offset((bbox.x + bbox.width).toDouble(), bbox.y.toDouble()),
    bottomRight: ui.Offset((bbox.x + bbox.width).toDouble(), (bbox.y + bbox.height).toDouble()),
    bottomLeft:  ui.Offset(bbox.x.toDouble(), (bbox.y + bbox.height).toDouble()),
  );
}

List<cv.Point> _orderPtsDebug(List<cv.Point> pts) {
  final bySum = List<cv.Point>.from(pts)
    ..sort((a, b) => (a.x + a.y).compareTo(b.x + b.y));
  final tl   = bySum.first;
  final br   = bySum.last;
  final rest = [bySum[1], bySum[2]]..sort((a, b) => a.x.compareTo(b.x));
  return [tl, rest[1], br, rest[0]];
}

CropQuad _scaleQuadDebug(CropQuad q, double sx, double sy) => CropQuad(
  topLeft:     ui.Offset(q.topLeft.dx * sx,     q.topLeft.dy * sy),
  topRight:    ui.Offset(q.topRight.dx * sx,    q.topRight.dy * sy),
  bottomRight: ui.Offset(q.bottomRight.dx * sx, q.bottomRight.dy * sy),
  bottomLeft:  ui.Offset(q.bottomLeft.dx * sx,  q.bottomLeft.dy * sy),
);

/// Scale from original space → working space (inverse of _scaleQuad)
CropQuad _toWorkingSpace(CropQuad q, double origToWork_X, double origToWork_Y) {
  // origToWork = wW / origW  = 1 / (origW/wW)
  final sx = 1.0 / origToWork_X;
  final sy = 1.0 / origToWork_Y;
  return _scaleQuadDebug(q, sx, sy);
}

bool _isPlausibleDebug(CropQuad q, double w, double h) {
  final xs = [q.topLeft.dx, q.topRight.dx, q.bottomRight.dx, q.bottomLeft.dx];
  final ys = [q.topLeft.dy, q.topRight.dy, q.bottomRight.dy, q.bottomLeft.dy];
  final bw = xs.reduce(math.max) - xs.reduce(math.min);
  final bh = ys.reduce(math.max) - ys.reduce(math.min);
  return bw > w * 0.08 && bh > h * 0.08 && bw < w * 0.95 && bh < h * 0.95;
}

void _drawQuad(cv.Mat mat, CropQuad q) {
  // Draw filled semi-transparent overlay using lines (opencv_dart has no alpha blend)
  final pts = [
    cv.Point(q.topLeft.dx.round(),     q.topLeft.dy.round()),
    cv.Point(q.topRight.dx.round(),    q.topRight.dy.round()),
    cv.Point(q.bottomRight.dx.round(), q.bottomRight.dy.round()),
    cv.Point(q.bottomLeft.dx.round(),  q.bottomLeft.dy.round()),
  ];
  final green  = cv.Scalar(0, 230, 118);
  final yellow = cv.Scalar(0, 230, 230);
  for (int i = 0; i < 4; i++) {
    cv.line(mat, pts[i], pts[(i + 1) % 4], green, thickness: 3);
  }
  // Corner circles
  for (final pt in pts) {
    cv.circle(mat, pt, 8, yellow, thickness: -1);
    cv.circle(mat, pt, 8, green,  thickness: 2);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

/// Drop-in replacement for EditSessionScreen during development.
/// Shows each image from the session followed by every intermediate
/// OpenCV stage so you can see exactly what the pipeline is doing.
///
/// Usage — replace EditSessionScreen with this in your navigator push:
///
///   Navigator.of(context).push(MaterialPageRoute(
///     builder: (_) => EdgeDetectionDebugScreen(session: _session),
///   ));
class EdgeDetectionDebugScreen extends StatefulWidget {
  final CaptureSession session;
  const EdgeDetectionDebugScreen({super.key, required this.session});

  @override
  State<EdgeDetectionDebugScreen> createState() =>
      _EdgeDetectionDebugScreenState();
}

class _EdgeDetectionDebugScreenState
    extends State<EdgeDetectionDebugScreen> {

  // Results indexed by page index
  final Map<int, EdgeDebugResult> _results = {};
  final Map<int, String>          _errors  = {};
  final Set<int>                  _running = {};

  @override
  void initState() {
    super.initState();
    // Kick off all pages in parallel
    for (int i = 0; i < widget.session.count; i++) {
      _runPage(i);
    }
  }

  Future<void> _runPage(int i) async {
    if (_running.contains(i)) return;
    setState(() { _running.add(i); _errors.remove(i); _results.remove(i); });

    try {
      final page  = widget.session.pages[i];
      final bytes = await page.rawFile.readAsBytes();
      final result = await runDebugPipeline(bytes);
      if (mounted) setState(() { _results[i] = result; _running.remove(i); });
    } catch (e) {
      if (mounted) setState(() {
        _errors[i]  = e.toString();
        _running.remove(i);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        foregroundColor: Colors.white,
        title: Text(
          'Edge Detection Debug  •  ${widget.session.count} page(s)',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        actions: [
          // Re-run all
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-run all',
            onPressed: () {
              _results.clear(); _errors.clear(); _running.clear();
              for (int i = 0; i < widget.session.count; i++) _runPage(i);
            },
          ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: widget.session.count,
        itemBuilder: (_, i) => _PageDebugCard(
          pageIndex: i,
          pageFile:  widget.session.pages[i].rawFile,
          result:    _results[i],
          error:     _errors[i],
          isRunning: _running.contains(i),
          onRerun:   () => _runPage(i),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-page debug card
// ─────────────────────────────────────────────────────────────────────────────

class _PageDebugCard extends StatefulWidget {
  final int             pageIndex;
  final File            pageFile;
  final EdgeDebugResult? result;
  final String?         error;
  final bool            isRunning;
  final VoidCallback    onRerun;

  const _PageDebugCard({
    required this.pageIndex,
    required this.pageFile,
    required this.result,
    required this.error,
    required this.isRunning,
    required this.onRerun,
  });

  @override
  State<_PageDebugCard> createState() => _PageDebugCardState();
}

class _PageDebugCardState extends State<_PageDebugCard> {
  bool _expanded = true; // all stages visible by default

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Card header ──────────────────────────────────────────────────
          _CardHeader(
            index:     widget.pageIndex,
            passName:  widget.result?.passName,
            isRunning: widget.isRunning,
            expanded:  _expanded,
            onToggle:  () => setState(() => _expanded = !_expanded),
            onRerun:   widget.onRerun,
          ),

          if (widget.isRunning)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(
                        color: Color(0xFF00E676), strokeWidth: 2),
                    SizedBox(height: 12),
                    Text('Running pipeline…',
                        style: TextStyle(color: Colors.white38, fontSize: 12)),
                  ],
                ),
              ),
            )
          else if (widget.error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Error: ${widget.error}',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            )
          else if (widget.result != null && _expanded) ...[
              // ── Original image ───────────────────────────────────────────
              _StageTile(
                label: 'Original image',
                badge: null,
                png:   widget.result!.originalPng,
              ),

              const _Divider(),

              // ── Pipeline stages ──────────────────────────────────────────
              ...widget.result!.stages.asMap().entries.map((e) => Column(
                children: [
                  _StageTile(
                    label: e.value.label,
                    badge: e.key + 1,
                    png:   e.value.png,
                  ),
                  if (e.key < widget.result!.stages.length - 1) const _Divider(),
                ],
              )),

              // ── Quad summary ─────────────────────────────────────────────
              if (widget.result!.quad != null)
                _QuadSummary(quad: widget.result!.quad!),

              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

class _CardHeader extends StatelessWidget {
  final int     index;
  final String? passName;
  final bool    isRunning;
  final bool    expanded;
  final VoidCallback onToggle;
  final VoidCallback onRerun;

  const _CardHeader({
    required this.index,
    required this.passName,
    required this.isRunning,
    required this.expanded,
    required this.onToggle,
    required this.onRerun,
  });

  Color get _badgeColor {
    if (isRunning || passName == null) return Colors.white24;
    if (passName!.startsWith('A')) return const Color(0xFF00E676);
    if (passName!.startsWith('B')) return Colors.amber;
    if (passName!.startsWith('C')) return Colors.orange;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Page number
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text('${index + 1}',
                  style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                      fontSize: 14)),
            ),
            const SizedBox(width: 12),

            // Title + pass badge
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Page',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                  const SizedBox(height: 2),
                  if (isRunning)
                    const Text('running…',
                        style: TextStyle(color: Colors.white38, fontSize: 11))
                  else if (passName != null)
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: _badgeColor.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: _badgeColor.withOpacity(0.5)),
                        ),
                        child: Text(
                          passName == 'fallback'
                              ? 'FALLBACK'
                              : 'Pass $passName',
                          style: TextStyle(
                              color: _badgeColor,
                              fontSize: 10,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ]),
                ],
              ),
            ),

            // Re-run
            if (!isRunning)
              IconButton(
                icon: const Icon(Icons.refresh, size: 18, color: Colors.white38),
                tooltip: 'Re-run this page',
                onPressed: onRerun,
              ),

            // Expand/collapse
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              color: Colors.white38, size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _StageTile extends StatelessWidget {
  final String   label;
  final int?     badge;
  final Uint8List png;

  const _StageTile({
    required this.label,
    required this.badge,
    required this.png,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Label row
          Row(
            children: [
              if (badge != null) ...[
                Container(
                  width: 20, height: 20,
                  decoration: const BoxDecoration(
                    color: Colors.white10,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text('$badge',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 10)),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: label.startsWith('✓')
                        ? const Color(0xFF00E676)
                        : label.startsWith('✗')
                        ? Colors.redAccent
                        : Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Stage image — fills width, respects aspect ratio
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              png,
              fit: BoxFit.contain,
              width: double.infinity,
              gaplessPlayback: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuadSummary extends StatelessWidget {
  final CropQuad quad;
  const _QuadSummary({required this.quad});

  String _fmt(ui.Offset o) =>
      '(${o.dx.toStringAsFixed(0)}, ${o.dy.toStringAsFixed(0)})';

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF00E676).withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF00E676).withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Detected CropQuad (pixel space)',
              style: TextStyle(
                  color: Color(0xFF00E676),
                  fontSize: 11,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          _Row('TL', _fmt(quad.topLeft)),
          _Row('TR', _fmt(quad.topRight)),
          _Row('BR', _fmt(quad.bottomRight)),
          _Row('BL', _fmt(quad.bottomLeft)),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String k, v;
  const _Row(this.k, this.v);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(children: [
      SizedBox(
        width: 28,
        child: Text(k,
            style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ),
      Text(v, style: const TextStyle(color: Colors.white70, fontSize: 11,
          fontFamily: 'monospace')),
    ]),
  );
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, color: Colors.white10, indent: 14, endIndent: 14);
}