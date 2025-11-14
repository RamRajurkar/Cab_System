// lib/screens/booking_status_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' show atan2, pi;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as flutter_map;
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../services/websocket_service.dart';

class BookingStatusScreen extends StatefulWidget {
  final int cabId;
  final LatLng cabInitialPosition;
  final LatLng userSource;
  final LatLng userDestination;
  final double fare;
  final String cabName;
  final VoidCallback onCabsRefresh;
  final VoidCallback onRideCompleted;

  const BookingStatusScreen({
    Key? key,
    required this.cabId,
    required this.cabInitialPosition,
    required this.userSource,
    required this.userDestination,
    required this.fare,
    required this.cabName,
    required this.onCabsRefresh,
    required this.onRideCompleted,
  }) : super(key: key);

  @override
  State<BookingStatusScreen> createState() => _BookingStatusScreenState();
}

class _BookingStatusScreenState extends State<BookingStatusScreen>
    with TickerProviderStateMixin {
  late flutter_map.MapController _mapController;

  // Cab live position (drives the marker)
  late LatLng _cabPosition;

  // animation & timers
  Timer? _movementTimer;
  Timer? _simulateArrivalTimer; // optional small timer for UX
  double _cabRotationDeg = 0.0;
  double _currentZoom = 15.0; // use a stable zoom to avoid relying on controller getters

  // ride state
  bool _isArrived = false;
  bool _isOnTrip = false;
  bool _isLoading = false;
  bool _showSuccess = false;

  // success animation
  late final AnimationController _successController;
  late final Animation<double> _successScale;

  // ws listener callback reference (so we can remove)
  late final void Function(Map<String, dynamic>) _wsCallback;

  @override
  void initState() {
    super.initState();
    _mapController = flutter_map.MapController();
    _cabPosition = widget.cabInitialPosition;

    _successController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _successScale = CurvedAnimation(
      parent: _successController,
      curve: Curves.elasticOut,
    );

    // WebSocket callback — receives parsed map payloads
    _wsCallback = (Map<String, dynamic> msg) {
      try {
        final rawId = msg['cab_id'];
        final int receivedCabId =
            rawId is int ? rawId : int.tryParse(rawId.toString()) ?? -1;
        if (receivedCabId != widget.cabId) return;

        final lat = double.tryParse(msg['latitude'].toString()) ??
            _cabPosition.latitude;
        final lng = double.tryParse(msg['longitude'].toString()) ??
            _cabPosition.longitude;
        final status = (msg['status'] ?? '').toString();

        // Smooth animate movement toward new coordinates
        _startSmoothMove(LatLng(lat, lng));

        // update simple status flags
        final s = status.toLowerCase();
        setState(() {
          _isArrived = s.contains('arriv');
          _isOnTrip = s.contains('ontrip') || s.contains('busy') || s.contains('enroute');
          if (s.contains('available')) {
            _isOnTrip = false;
            _isArrived = false;
          }
        });
      } catch (e, st) {
        debugPrint('WS parse error in BookingStatusScreen: $e\n$st');
      }
    };

    // register listener with global WebSocketService
    WebSocketService().addListener(_wsCallback);
  }

  @override
  void dispose() {
    WebSocketService().removeListener(_wsCallback);
    _movementTimer?.cancel();
    _simulateArrivalTimer?.cancel();
    _successController.dispose();
    super.dispose();
  }

  // Smoothly interpolate the cab marker from current -> newPos over ~1.5s
  void _startSmoothMove(LatLng newPos, {int ms = 1500}) {
    _movementTimer?.cancel();

    final start = _cabPosition;
    final end = newPos;

    final dx = end.latitude - start.latitude;
    final dy = end.longitude - start.longitude;
    final dist = (dx * dx + dy * dy).abs().sqrt();

    // orientation: compute rotation in degrees (approx)
    final angleRad = atan2(dy, dx);
    final angleDeg = angleRad * 180 / pi;
    _cabRotationDeg = angleDeg;

    final int steps = (ms / 33).round().clamp(6, 120);
    int step = 0;

    _movementTimer = Timer.periodic(Duration(milliseconds: (ms / steps).round()),
        (t) {
      step++;
      final tnorm = step / steps;
      final lat = start.latitude + (dx * tnorm);
      final lng = start.longitude + (dy * tnorm);

      setState(() {
        _cabPosition = LatLng(lat, lng);
      });

      // center the map gently on the cab (optional)
      try {
        _mapController.move(_cabPosition, _currentZoom);
      } catch (_) {}

      if (step >= steps) {
        t.cancel();
        _movementTimer = null;
        setState(() {
          _cabPosition = end;
        });
      }
    });
  }

  Future<void> _startRide() async {
    // UX: small animation + change state
    setState(() => _isLoading = true);

    // simulate short delay to show "starting" animation
    await Future.delayed(const Duration(seconds: 2));
    setState(() {
      _isOnTrip = true;
      _isLoading = false;
      _isArrived = false;
    });
  }

  Future<void> _completeRide() async {
    setState(() => _isLoading = true);

    final url = Uri.parse('${ApiConfig.baseUrl}/api/complete_ride/${widget.cabId}');
    try {
      final resp = await http.get(url);
      if (resp.statusCode == 200) {
        // success -> show success animation and call callback
        setState(() {
          _showSuccess = true;
          _isOnTrip = false;
          _isArrived = false;
        });
        _successController.forward(from: 0.0);
        // notify parent after small delay
        await Future.delayed(const Duration(milliseconds: 900));
        widget.onCabsRefresh();
        widget.onRideCompleted();
      } else {
        final body = resp.body;
        debugPrint('❌ complete_ride failed: ${resp.statusCode} -> $body');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to complete ride: ${resp.statusCode}')),
        );
      }
    } catch (e) {
      debugPrint('Error calling complete_ride: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error completing ride: $e')),
      );
    } finally {
      setState(() => _isLoading = false);
      // hide success after a bit
      Future.delayed(const Duration(seconds: 2), () {
        setState(() => _showSuccess = false);
      });
    }
  }

  Widget _buildBottomPanel() {
    final statusText = _isArrived
        ? 'Driver has arrived — please board'
        : _isOnTrip
            ? 'Driver enroute / On trip'
            : 'Driver is on the way';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      height: 220,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 50,
              height: 5,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  statusText,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              if (_isLoading) const SizedBox(width: 12),
              if (_isLoading) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 10),
          Text("Cab: ${widget.cabName}", style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          Text("Fare: ₹${widget.fare.toStringAsFixed(2)}", style: const TextStyle(fontSize: 14)),
          const Spacer(),
          if (_showSuccess)
            Center(
              child: ScaleTransition(
                scale: _successScale,
                child: Column(
                  children: const [
                    Icon(Icons.check_circle, size: 74, color: Colors.green),
                    SizedBox(height: 6),
                    Text('Ride completed', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            )
          else if (!_isOnTrip && !_isArrived)
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start Ride'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: _isLoading ? null : _startRide,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.flag),
                    label: const Text('Cancel'),
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    onPressed: _isLoading ? null : () {
                      // Optionally allow cancelling booking (call backend if needed)
                      Navigator.pop(context);
                    },
                  ),
                ),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Ride Completed'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade600,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _isLoading ? null : _completeRide,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cabPos = _cabPosition;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Ride Tracking'),
      ),
      body: Stack(
        children: [
          flutter_map.FlutterMap(
            mapController: _mapController,
            options: flutter_map.MapOptions(
              center: cabPos,
              zoom: _currentZoom,
              interactiveFlags: flutter_map.InteractiveFlag.none, // keep map stable
            ),
            children: [
              flutter_map.TileLayer(
                urlTemplate:
                    "https://api.maptiler.com/maps/streets/{z}/{x}/{y}.png?key=NF4AhANXs6D1lsaZ3uik",
                userAgentPackageName: 'com.example.smart_cab_allocation',
              ),
              flutter_map.MarkerLayer(
                markers: [
                  // Cab marker (animated position)
                  flutter_map.Marker(
                    point: cabPos,
                    width: 60,
                    height: 60,
                    // use child to match your map_screen usage
                    child: Transform.rotate(
                      angle: _cabRotationDeg * pi / 180,
                      child: const Icon(Icons.local_taxi, size: 40, color: Colors.orangeAccent),
                    ),
                  ),

                  // pickup marker (user source)
                  flutter_map.Marker(
                    point: widget.userSource,
                    width: 50,
                    height: 50,
                    child: const Icon(Icons.location_pin, size: 36, color: Colors.blueAccent),
                  ),

                  // destination marker
                  flutter_map.Marker(
                    point: widget.userDestination,
                    width: 50,
                    height: 50,
                    child: const Icon(Icons.flag, size: 34, color: Colors.green),
                  ),
                ],
              ),
            ],
          ),

          // bottom panel
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildBottomPanel(),
          ),
        ],
      ),
    );
  }
}
