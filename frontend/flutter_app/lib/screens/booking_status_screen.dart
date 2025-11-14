import 'dart:async';
import 'dart:convert';
import 'dart:math' show atan2, pi;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as flutter_map;
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:lottie/lottie.dart';

import '../config/api_config.dart';

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
  late WebSocketChannel _channel;

  LatLng? _cabPosition;
  LatLng? _targetPosition;
  double _cabRotation = 0.0;

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
  }

  @override
  void dispose() {
    _channel.sink.close(status.goingAway);
    _positionTimer?.cancel();
    super.dispose();
  }

  // ------------------------ WebSocket ------------------------

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
    }, onError: (e) {
      debugPrint("⚠️ WebSocket error: $e");
    });
  }

  // --------------------- Smooth Animation ---------------------

  void _startSmoothMovement(LatLng newPos) {
    if (_cabPosition == null) {
      _cabPosition = newPos;
      return;
    }

    _targetPosition = newPos;
    final oldPos = _cabPosition!;
    const int steps = 60;
    int current = 0;

    _positionTimer?.cancel();
    _positionTimer =
        Timer.periodic(const Duration(milliseconds: 33), (timer) {
      if (current >= steps) {
        timer.cancel();
        _cabPosition = newPos;
        return;
      }

      current++;
      final t = current / steps;
      final lat = oldPos.latitude + (newPos.latitude - oldPos.latitude) * t;
      final lng = oldPos.longitude + (newPos.longitude - oldPos.longitude) * t;

      _cabRotation =
          atan2(newPos.longitude - oldPos.longitude, newPos.latitude - oldPos.latitude) *
              (180 / pi);

      setState(() {
        _cabPosition = LatLng(lat, lng);
        _mapController.move(_cabPosition!, _mapController.camera.zoom);
      });
    });
  }

  // ---------------------- Arrived Alert -----------------------

  void _showArrivalDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text("🚕 Driver Arrived"),
        content: const Text("Your cab has reached the pickup point."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK"),
          )
        ],
      ),
    );
  }

  // ---------------------- Complete Ride -----------------------

 Future<void> _completeRide() async {
  debugPrint("🚀 _completeRide() called");

  setState(() => _isLoading = true);

  final url = Uri.parse('${ApiConfig.baseUrl}/api/complete_ride/${widget.cabId}');
  debugPrint("🌐 API CALL → $url");

  try {
    final response = await http.get(url);

    debugPrint("📩 API STATUS: ${response.statusCode}");
    debugPrint("📩 API BODY: ${response.body}");

    if (response.statusCode == 200) {
      debugPrint("🎉 API success → calling _showSuccessSheet()");
      setState(() => _isRideCompleted = true);

      widget.onCabsRefresh();
      widget.onRideCompleted();

      _showSuccessSheet();
    } else {
      debugPrint("❌ API did NOT return 200");
    }
  } catch (e) {
    debugPrint("💥 EXCEPTION: $e");
  } finally {
    setState(() => _isLoading = false);
  }
}

  // --------------------- Success Bottom Sheet -----------------------

void _showSuccessSheet() {
  debugPrint("🔥 _showSuccessSheet() CALLED");

  showModalBottomSheet(
    context: context,
    isDismissible: true,
    enableDrag: true,
    builder: (_) {
      return Container(
        padding: const EdgeInsets.all(24),
        height: 200,
        child: const Center(
          child: Text(
            "🎉 Ride Completed Successfully!",
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
        ),
      );
    },
  );
}

  // ---------------------- UI Bottom Card ----------------------

  Widget _buildBottomCard() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
      padding: const EdgeInsets.all(16),
      height: 260,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 12,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 50,
              height: 5,
              margin: const EdgeInsets.only(bottom: 10),
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
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              if (_isLoading)
                const CircularProgressIndicator(strokeWidth: 3),
            ],
          ),
          const SizedBox(height: 10),
          Text("Fare: ₹${widget.fare.toStringAsFixed(2)}",
              style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 4),
          Text(
            "Pickup: (${widget.userSource.latitude.toStringAsFixed(4)}, ${widget.userSource.longitude.toStringAsFixed(4)})",
            style: const TextStyle(color: Colors.grey),
          ),
          Text(
            "Destination: (${widget.userDestination.latitude.toStringAsFixed(4)}, ${widget.userDestination.longitude.toStringAsFixed(4)})",
            style: const TextStyle(color: Colors.grey),
          ),
          const Spacer(),
          if (!_isRideCompleted)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.flag_circle_outlined),
                label: const Text("Ride Completed"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _completeRide,
              ),
            ),
        ],
      ),
    );
  }

  // ----------------------- Build UI -----------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Live Ride Tracking"),
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

          // Bottom Panel
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildBottomCard(),
          ),
        ],
      ),
    );
  }
}
