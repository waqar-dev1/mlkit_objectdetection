import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:permission_handler/permission_handler.dart';

import '../painters/document_overlay_painter.dart';
import '../utils/camera_utils.dart';
import '../utils/object_detector_service.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with WidgetsBindingObserver {
  // Camera
  List<CameraDescription>? _cameras;
  CameraController? _cameraController;
  int _selectedCameraIndex = 0;
  bool _isCameraInitialized = false;

  // Detection
  final ObjectDetectorService _detectorService = ObjectDetectorService();
  List<DetectedObject> _detectedObjects = [];
  Size? _imageSize;
  InputImageRotation _rotation = InputImageRotation.rotation0deg;

  // State
  bool _hasPermission = false;
  String? _errorMessage;
  bool _isFlashOn = false;

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
      _startCamera(_selectedCameraIndex);
    }
  }

  Future<void> _initializeApp() async {
    await _requestPermissions();
    if (_hasPermission) {
      await _detectorService.initialize();
      await _loadCameras();
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

  Future<void> _loadCameras() async {
    try {
      _cameras = await availableCameras();
      if (_cameras != null && _cameras!.isNotEmpty) {
        await _startCamera(0);
      } else {
        setState(() => _errorMessage = 'No cameras found on this device.');
      }
    } on CameraException catch (e) {
      setState(() => _errorMessage = 'Failed to load cameras: ${e.description}');
    }
  }

  Future<void> _startCamera(int cameraIndex) async {
    if (_cameras == null || _cameras!.isEmpty) return;

    final camera = _cameras![cameraIndex];

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

      // Reset flash
      _isFlashOn = false;

      setState(() {
        _selectedCameraIndex = cameraIndex;
        _isCameraInitialized = true;
        _errorMessage = null;
        _detectedObjects = [];
      });

      // Start processing frames
      await controller.startImageStream(_processFrame);
    } on CameraException catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Camera error: ${e.description}');
      }
    }
  }

  Future<void> _stopCamera() async {
    final controller = _cameraController;
    if (controller == null) return;

    if (controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
    await controller.dispose();
    _cameraController = null;

    if (mounted) {
      setState(() => _isCameraInitialized = false);
    }
  }

  void _processFrame(CameraImage image) {
    if (!mounted) return;

    final camera = _cameras![_selectedCameraIndex];
    final inputImage = CameraUtils.cameraImageToInputImage(image, camera);
    if (inputImage == null) return;

    // Capture the rotation used so the painter can correct coordinates.
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

  Future<void> _toggleFlash() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    setState(() => _isFlashOn = !_isFlashOn);
    await controller.setFlashMode(
      _isFlashOn ? FlashMode.torch : FlashMode.off,
    );
  }

  Future<void> _switchCamera() async {
    if (_cameras == null || _cameras!.length < 2) return;
    await _stopCamera();
    final nextIndex = (_selectedCameraIndex + 1) % _cameras!.length;
    await _startCamera(nextIndex);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopCamera();
    _detectorService.dispose();
    super.dispose();
  }

  // ─────────────────────────── UI ───────────────────────────

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
    if (_errorMessage != null) {
      return _buildErrorView();
    }

    if (!_isCameraInitialized || _cameraController == null) {
      return _buildLoadingView();
    }

    return _buildCameraView();
  }

  Widget _buildLoadingView() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Color(0xFF00E676)),
          SizedBox(height: 16),
          Text(
            'Starting camera…',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
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
            Icon(Icons.camera_alt_outlined, color: Colors.white38, size: 64),
            const SizedBox(height: 20),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.5),
            ),
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

  Widget _buildCameraView() {
    final controller = _cameraController!;

    // controller.value.aspectRatio is the RAW sensor ratio (landscape, e.g. 1.77).
    // The camera plugin rotates the preview to match device orientation, so on a
    // portrait device the effective display ratio is the INVERSE (e.g. 0.56).
    // We must use the inverted value so our overlay SizedBox matches what is
    // actually rendered on screen.
    final rawRatio    = controller.value.aspectRatio; // sensor: w/h (>1 on most phones)
    final screenSize  = MediaQuery.of(context).size;
    final isPortrait  = screenSize.height > screenSize.width;

    // Effective preview ratio as it appears on screen
    final previewRatio = isPortrait ? (1.0 / rawRatio) : rawRatio;
    final screenRatio  = screenSize.width / screenSize.height;

    double previewW, previewH;
    if (screenRatio > previewRatio) {
      // Screen is wider than preview → preview fills height, pillarboxed
      previewH = screenSize.height;
      previewW = previewH * previewRatio;
    } else {
      // Screen is taller than preview → preview fills width, letterboxed
      previewW = screenSize.width;
      previewH = previewW / previewRatio;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // ── Camera preview ──
        CameraPreview(controller),

        // ── Detection overlay — sized & centred to match the preview rect ──
        if (_detectedObjects.isNotEmpty && _imageSize != null)
          Center(
            child: SizedBox(
              width:  previewW,
              height: previewH,
              child: CustomPaint(
                painter: DocumentOverlayPainter(
                  detectedObjects: _detectedObjects,
                  absoluteImageSize: _imageSize!,
                  rotation: _rotation,
                  isFrontCamera: _cameras![_selectedCameraIndex].lensDirection ==
                      CameraLensDirection.front,
                ),
              ),
            ),
          ),

        // ── Viewfinder guide (when nothing detected) ──
        if (_detectedObjects.isEmpty) _buildViewfinderGuide(),

        // ── Top bar ──
        _buildTopBar(),

        // ── Bottom bar ──
        _buildBottomBar(),

        // ── Detection status pill ──
        _buildStatusPill(),
      ],
    );
  }

  Widget _buildViewfinderGuide() {
    return Center(
      child: FractionallySizedBox(
        widthFactor: 0.85,
        heightFactor: 0.6,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: Colors.white.withOpacity(0.25),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.document_scanner_outlined,
                    color: Colors.white38, size: 40),
                SizedBox(height: 10),
                Text(
                  'Point at a document',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 8,
          left: 16,
          right: 16,
          bottom: 12,
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
            const SizedBox(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.document_scanner, color: Color(0xFF00E676), size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Doc Scanner',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            // Flash toggle
            _IconButton(
              icon: _isFlashOn ? Icons.flash_on : Icons.flash_off,
              color: _isFlashOn ? const Color(0xFFFFD600) : Colors.white70,
              onTap: _toggleFlash,
              tooltip: 'Toggle flash',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final hasMultipleCameras = (_cameras?.length ?? 0) > 1;

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + 20,
          top: 20,
          left: 24,
          right: 24,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withOpacity(0.75), Colors.transparent],
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (hasMultipleCameras)
              _IconButton(
                icon: Icons.flip_camera_ios_outlined,
                color: Colors.white,
                onTap: _switchCamera,
                tooltip: 'Switch camera',
                size: 28,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusPill() {
    final count = _detectedObjects.length;
    final isDetecting = count > 0;

    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 88,
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
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDetecting
                      ? const Color(0xFF00E676)
                      : Colors.white38,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                isDetecting
                    ? count == 1
                    ? '1 object detected'
                    : '$count objects detected'
                    : 'Scanning…',
                style: TextStyle(
                  color: isDetecting ? const Color(0xFF00E676) : Colors.white54,
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

// ── Small reusable icon button ──────────────────────────────────────────────

class _IconButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String tooltip;
  final double size;

  const _IconButton({
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
          decoration: BoxDecoration(
            color: Colors.black26,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: size),
        ),
      ),
    );
  }
}