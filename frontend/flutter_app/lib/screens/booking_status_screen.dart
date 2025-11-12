import 'dart:async';
import 'dart:convert';
import 'dart:math' show atan2, pi;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as flutter_map;
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import '../config/api_config.dart';

class BookingStatusScreen extends StatefulWidget {
  final int cabId;
  final LatLng cabInitialPosition;
  final LatLng userSource;
  final LatLng userDestination;
  final double fare;

  const BookingStatusScreen({
    Key? key,
    required this.cabId,
    required this.cabInitialPosition,
    required this.userSource,
    required this.userDestination,
    required this.fare,
  }) : super(key: key);

  @override
  State<BookingStatusScreen> createState() => _BookingStatusScreenState();
}

class _BookingStatusScreenState extends State<BookingStatusScreen>
    with TickerProviderStateMixin {
  late flutter_map.MapController _mapController;
  late WebSocketChannel _channel;
  LatLng? _cabPosition;
  LatLng? _targetPosition;
  double _cabRotation = 0.0;

  late AnimationController _animationController;
  late Animation<double> _animation;
  Timer? _positionTimer;

  String _rideStatus = "Driver is on the way 🚗";
  bool _isRideCompleted = false;
  bool _isArrived = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _mapController = flutter_map.MapController();
    _cabPosition = widget.cabInitialPosition;
    _connectWebSocket();

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  void dispose() {
    _channel.sink.close(status.goingAway);
    _animationController.dispose();
    _positionTimer?.cancel();
    super.dispose();
  }

  // 🛰️ Connect to WebSocket for real-time movement
  void _connectWebSocket() {
    final wsUrl = ApiConfig.wsUrl;
    _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

    _channel.stream.listen((event) {
      final data = jsonDecode(event);
      if (data["cab_id"] == widget.cabId) {
        final newLat = data["latitude"]?.toDouble();
        final newLng = data["longitude"]?.toDouble();

        if (newLat != null && newLng != null) {
          _startSmoothMovement(LatLng(newLat, newLng));
        }

        if (data["status"] == "Arrived" && !_isArrived) {
          _isArrived = true;
          _rideStatus = "Your driver has arrived 🚕";
          _showArrivalDialog();
        }
      }
    }, onError: (error) {
      debugPrint("⚠️ WebSocket error: $error");
    });
  }

  // 🧭 Smooth animation logic
  void _startSmoothMovement(LatLng newPos) {
    if (_cabPosition == null) {
      _cabPosition = newPos;
      return;
    }

    _targetPosition = newPos;
    final oldPos = _cabPosition!;
    const steps = 60; // smooth 2s transition (FPS ~30)
    int currentStep = 0;

    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 33), (timer) {
      if (currentStep >= steps) {
        timer.cancel();
        _cabPosition = _targetPosition;
        return;
      }
      currentStep++;
      final t = currentStep / steps;
      final lat = oldPos.latitude + (newPos.latitude - oldPos.latitude) * t;
      final lon = oldPos.longitude + (newPos.longitude - oldPos.longitude) * t;

      // Update rotation toward new direction
      _cabRotation = atan2(newPos.longitude - oldPos.longitude,
              newPos.latitude - oldPos.latitude) *
          (180 / pi);

      setState(() {
        _cabPosition = LatLng(lat, lon);
      });
    });
  }

  void _showArrivalDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("🚕 Driver Arrived"),
        content:
            const Text("Your cab has arrived at your pickup location. Please board soon."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  Future<void> _completeRide() async {
    setState(() => _isLoading = true);
    final url = Uri.parse('${ApiConfig.baseUrl}/api/complete_ride/${widget.cabId}');
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        setState(() {
          _rideStatus = "Ride completed ✅";
          _isRideCompleted = true;
        });
      } else {
        debugPrint("❌ Ride completion failed: ${response.body}");
      }
    } catch (e) {
      debugPrint("💥 Error completing ride: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // 🎨 Bottom panel UI
  Widget _buildBottomCard() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
      height: 260,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              height: 5,
              width: 50,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _rideStatus,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              if (_isLoading)
                const SizedBox(width: 24, height: 24, child: CircularProgressIndicator()),
            ],
          ),
          const SizedBox(height: 12),
          Text("Fare: ₹${widget.fare.toStringAsFixed(2)}",
              style: const TextStyle(fontSize: 16, color: Colors.black87)),
          const SizedBox(height: 6),
          Text(
              "Pickup: (${widget.userSource.latitude.toStringAsFixed(4)}, ${widget.userSource.longitude.toStringAsFixed(4)})",
              style: const TextStyle(fontSize: 14, color: Colors.grey)),
          Text(
              "Destination: (${widget.userDestination.latitude.toStringAsFixed(4)}, ${widget.userDestination.longitude.toStringAsFixed(4)})",
              style: const TextStyle(fontSize: 14, color: Colors.grey)),
          const Spacer(),
          if (!_isRideCompleted)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.flag_circle_outlined),
                label: const Text("Ride Completed"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade600,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _completeRide,
              ),
            ),
          if (_isRideCompleted)
            Center(
              child: Text(
                "✅ Cab is now available again",
                style: TextStyle(
                    color: Colors.green.shade700, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
    );
  }

  // 🗺️ Main build
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Ride Tracking'),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          flutter_map.FlutterMap(
            mapController: _mapController,
            options: flutter_map.MapOptions(
              initialCenter: widget.cabInitialPosition,
              initialZoom: 15,
            ),
            children: [
              flutter_map.TileLayer(
                urlTemplate:
                    "https://api.maptiler.com/maps/streets/{z}/{x}/{y}.png?key=NF4AhANXs6D1lsaZ3uik",
                userAgentPackageName: 'com.example.smart_cab_allocation',
              ),
              if (_cabPosition != null)
                flutter_map.MarkerLayer(
                  markers: [
                    flutter_map.Marker(
                      point: _cabPosition!,
                      width: 60,
                      height: 60,
                      child: Transform.rotate(
                        angle: _cabRotation * pi / 180,
                        child: const Icon(Icons.local_taxi,
                            color: Colors.orangeAccent, size: 40),
                      ),
                    ),
                    flutter_map.Marker(
                      point: widget.userSource,
                      width: 60,
                      height: 60,
                      child: const Icon(Icons.location_pin,
                          color: Colors.blueAccent, size: 35),
                    ),
                    flutter_map.Marker(
                      point: widget.userDestination,
                      width: 60,
                      height: 60,
                      child: const Icon(Icons.flag,
                          color: Colors.green, size: 35),
                    ),
                  ],
                ),
            ],
          ),
          Positioned(bottom: 0, left: 0, right: 0, child: _buildBottomCard()),
        ],
      ),
    );
  }
}
