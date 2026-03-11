import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:ml_objecdetection/screens/providers/capture_session.dart';
import 'package:permission_handler/permission_handler.dart';
import '../painters/document_overlay_painter.dart';
import '../utils/camera_utils.dart';
import '../utils/object_detector_service.dart';
import '../widgets/capture_button.dart';
import 'edit_session_screen.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with WidgetsBindingObserver {
  // ── Camera (back only) ──────────────────────────────────────────────────
  CameraDescription? _backCamera;
  CameraController? _cameraController;
  bool _isCameraInitialized = false;

  // ── Detection ────────────────────────────────────────────────────────────
  final ObjectDetectorService _detectorService = ObjectDetectorService();
  List<DetectedObject> _detectedObjects = [];
  Size? _imageSize;
  InputImageRotation _rotation = InputImageRotation.rotation0deg;

  // ── Capture session ──────────────────────────────────────────────────────
  final CaptureSession _session = CaptureSession();
  bool _isCapturing = false;

  // ── UI state ─────────────────────────────────────────────────────────────
  bool _hasPermission = false;
  String? _errorMessage;
  bool _isFlashOn = false;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _stopCamera();
    } else if (state == AppLifecycleState.resumed) {
      _startCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopCamera();
    _detectorService.dispose();
    _session.dispose();
    super.dispose();
  }

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> _initializeApp() async {
    await _requestPermissions();
    if (_hasPermission) {
      await _detectorService.initialize();
      await _loadCamera();
    }
  }

  Future<void> _requestPermissions() async {
    final status = await Permission.camera.request();
    setState(() {
      _hasPermission = status.isGranted;
      if (!status.isGranted) {
        _errorMessage = status.isPermanentlyDenied
            ? 'Camera permission permanently denied.\nPlease enable it in Settings.'
            : 'Camera permission is required to scan documents.';
      }
    });
  }

  Future<void> _loadCamera() async {
    try {
      final cameras = await availableCameras();
      _backCamera = cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      await _startCamera();
    } on CameraException catch (e) {
      setState(() => _errorMessage = 'Failed to load camera: ${e.description}');
    }
  }

  Future<void> _startCamera() async {
    final camera = _backCamera;
    if (camera == null) return;

    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888,
    );
    _cameraController = controller;

    try {
      await controller.initialize();
      if (!mounted) return;
      _isFlashOn = false;
      setState(() {
        _isCameraInitialized = true;
        _errorMessage = null;
        _detectedObjects = [];
      });
      await controller.startImageStream(_processFrame);
    } on CameraException catch (e) {
      if (mounted) setState(() => _errorMessage = 'Camera error: ${e.description}');
    }
  }

  Future<void> _stopCamera() async {
    final controller = _cameraController;
    if (controller == null) return;
    if (controller.value.isStreamingImages) await controller.stopImageStream();
    await controller.dispose();
    _cameraController = null;
    if (mounted) setState(() => _isCameraInitialized = false);
  }

  // ── Frame processing ──────────────────────────────────────────────────────

  void _processFrame(CameraImage image) {
    if (!mounted) return;
    final camera = _backCamera;
    if (camera == null) return;

    final inputImage = CameraUtils.cameraImageToInputImage(image, camera);
    if (inputImage == null) return;

    final rotation = CameraUtils.rotationForCamera(camera);

    _detectorService.processImage(inputImage).then((objects) {
      if (!mounted || objects == null) return;
      setState(() {
        _detectedObjects = objects;
        _imageSize = Size(image.width.toDouble(), image.height.toDouble());
        if (rotation != null) _rotation = rotation;
      });
    });
  }

  // ── Capture ───────────────────────────────────────────────────────────────

  Future<void> _captureImage() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (_isCapturing) return;

    setState(() => _isCapturing = true);

    try {
      // Stop ML stream to free resources during capture
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }

      final xfile = await controller.takePicture();
      final doc = CapturedDocument.fromXFile(xfile);
      _session.addPage(doc);
      setState(() {}); // rebuild tray

      // Resume detection
      await controller.startImageStream(_processFrame);
    } on CameraException catch (e) {
      debugPrint('Capture error: ${e.description}');
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  // ── Flash ─────────────────────────────────────────────────────────────────

  Future<void> _toggleFlash() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    setState(() => _isFlashOn = !_isFlashOn);
    await controller.setFlashMode(
      _isFlashOn ? FlashMode.torch : FlashMode.off,
    );
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _goBack() => Navigator.of(context).maybePop();

  void _onComplete() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditSessionScreen(session: _session),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_errorMessage != null) return _buildErrorView();
    if (!_isCameraInitialized || _cameraController == null) return _buildLoadingView();
    return _buildCameraView();
  }

  Widget _buildLoadingView() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Color(0xFF00E676)),
          SizedBox(height: 16),
          Text('Starting camera…',
              style: TextStyle(color: Colors.white70, fontSize: 14)),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.camera_alt_outlined, color: Colors.white38, size: 64),
            const SizedBox(height: 20),
            Text(_errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white70, fontSize: 15, height: 1.5)),
            const SizedBox(height: 24),
            if (_errorMessage!.contains('Settings'))
              TextButton.icon(
                onPressed: openAppSettings,
                icon: const Icon(Icons.settings, color: Color(0xFF1A73E8)),
                label: const Text('Open Settings',
                    style: TextStyle(color: Color(0xFF1A73E8))),
              )
            else
              TextButton.icon(
                onPressed: _initializeApp,
                icon: const Icon(Icons.refresh, color: Color(0xFF1A73E8)),
                label: const Text('Retry',
                    style: TextStyle(color: Color(0xFF1A73E8))),
              ),
          ],
        ),
      ),
    );
  }

  // ── Camera view ───────────────────────────────────────────────────────────

  Widget _buildCameraView() {
    final controller = _cameraController!;

    final rawRatio    = controller.value.aspectRatio;
    final screenSize  = MediaQuery.of(context).size;
    final isPortrait  = screenSize.height > screenSize.width;
    final previewRatio = isPortrait ? (1.0 / rawRatio) : rawRatio;
    final screenRatio  = screenSize.width / screenSize.height;

    double previewW, previewH;
    if (screenRatio > previewRatio) {
      previewH = screenSize.height;
      previewW = previewH * previewRatio;
    } else {
      previewW = screenSize.width;
      previewH = previewW / previewRatio;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(controller),

        if (_detectedObjects.isNotEmpty && _imageSize != null)
          Center(
            child: SizedBox(
              width: previewW,
              height: previewH,
              child: CustomPaint(
                painter: DocumentOverlayPainter(
                  detectedObjects: _detectedObjects,
                  absoluteImageSize: _imageSize!,
                  rotation: _rotation,
                  isFrontCamera: false,
                ),
              ),
            ),
          ),

        if (_detectedObjects.isEmpty) _buildViewfinderGuide(),

        // White flash on capture
        if (_isCapturing)
          const ColoredBox(color: Colors.white24,
              child: SizedBox.expand()),

        _buildTopBar(),
        _buildBottomBar(),
        _buildStatusPill(),
      ],
    );
  }

  // ── Viewfinder guide ──────────────────────────────────────────────────────

  Widget _buildViewfinderGuide() {
    return Center(
      child: FractionallySizedBox(
        widthFactor: 0.85,
        heightFactor: 0.6,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
                color: Colors.white.withOpacity(0.25), width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.document_scanner_outlined,
                    color: Colors.white38, size: 40),
                SizedBox(height: 10),
                Text('Point at a document',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0.3)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    return Positioned(
      top: 0, left: 0, right: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 8,
          left: 16, right: 16, bottom: 12,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withOpacity(0.7), Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.document_scanner,
                    color: Color(0xFF00E676), size: 20),
                SizedBox(width: 8),
                Text('Doc Scanner',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3)),
              ],
            ),
            const Spacer(),
            _RoundIconButton(
              icon: _isFlashOn ? Icons.flash_on : Icons.flash_off,
              color: _isFlashOn
                  ? const Color(0xFFFFD600)
                  : Colors.white70,
              onTap: _toggleFlash,
              tooltip: 'Toggle flash',
            ),
          ],
        ),
      ),
    );
  }

  // ── Bottom bar ────────────────────────────────────────────────────────────

  Widget _buildBottomBar() {
    return Positioned(
      bottom: 0, left: 0, right: 0,
      child: Container(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + 20,
          top: 16, left: 24, right: 24,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withOpacity(0.85), Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Tray — only visible after first capture
            if (_session.isNotEmpty) ...[
              _buildCaptureTray(),
              const SizedBox(height: 16),
            ],

            // Action row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Left — back
                _RoundIconButton(
                  icon: Icons.arrow_back,
                  color: Colors.white,
                  onTap: _goBack,
                  tooltip: 'Back',
                ),

                // Centre — shutter
                CaptureButton(
                  onTap: _captureImage,
                  enabled: !_isCapturing,
                ),

                // Right — complete pill
                _CompletePill(
                  onTap: _session.isNotEmpty ? _onComplete : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Capture tray ──────────────────────────────────────────────────────────

  Widget _buildCaptureTray() {
    final last  = _session.lastPage!;
    final count = _session.count;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            // Thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                last.rawFile,
                width: 48,
                height: 64,
                fit: BoxFit.cover,
              ),
            ),
            // Count badge
            Positioned(
              top: -7,
              right: -7,
              child: Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: Color(0xFF00E676),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(width: 10),
        Text(
          count == 1 ? '1 page captured' : '$count pages captured',
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  // ── Status pill ───────────────────────────────────────────────────────────

  Widget _buildStatusPill() {
    final isDetecting = _detectedObjects.isNotEmpty;

    return Positioned(
      // Sits above the bottom bar; when tray is visible the bar is taller
      bottom: MediaQuery.of(context).padding.bottom +
          (_session.isNotEmpty ? 185 : 130),
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: isDetecting
                ? const Color(0xFF00E676).withOpacity(0.18)
                : Colors.black38,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDetecting
                  ? const Color(0xFF00E676).withOpacity(0.5)
                  : Colors.white12,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 6, height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDetecting
                      ? const Color(0xFF00E676)
                      : Colors.white38,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                isDetecting ? 'Document detected' : 'Scanning…',
                style: TextStyle(
                  color: isDetecting
                      ? const Color(0xFF00E676)
                      : Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────── Shared widgets ────────────────────────────────

class _CompletePill extends StatelessWidget {
  final VoidCallback? onTap;
  const _CompletePill({this.onTap});

  @override
  Widget build(BuildContext context) {
    final active = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFF00E676).withOpacity(0.15)
              : Colors.white10,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: active
                ? const Color(0xFF00E676).withOpacity(0.6)
                : Colors.white24,
            width: 1.5,
          ),
        ),
        child: Text(
          'Complete',
          style: TextStyle(
            color: active ? const Color(0xFF00E676) : Colors.white38,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String tooltip;
  final double size;

  const _RoundIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.tooltip,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            color: Colors.black26,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: size),
        ),
      ),
    );
  }
}
