import 'dart:async';
import 'dart:convert';
import 'dart:math' show atan2, pi;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as flutter_map;
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:lottie/lottie.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

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
  double _cabRotation = 0.0;

  Timer? _positionTimer;

  /// UI Stage Flow:
  /// arrival_animation → show_start_button → ride_starting → show_complete_button → completed
  String _uiStage = "arrival_animation"; 

  bool _isLoading = false;
  bool _isRideCompleted = false;

  @override
  void initState() {
    super.initState();

    _mapController = flutter_map.MapController();
    _cabPosition = widget.cabInitialPosition;

    _connectWebSocket();

    // Show arrival animation for 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      setState(() => _uiStage = "show_start_button");
    });
  }

  @override
  void dispose() {
    _channel.sink.close(status.goingAway);
    _positionTimer?.cancel();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // 🛰️ WebSocket live tracking
  // ─────────────────────────────────────────────

  void _connectWebSocket() {
    _channel = WebSocketChannel.connect(Uri.parse(ApiConfig.wsUrl));

    _channel.stream.listen((event) {
      final data = jsonDecode(event);

      if (data["cab_id"] == widget.cabId) {
        final newLat = data["latitude"]?.toDouble();
        final newLng = data["longitude"]?.toDouble();

        if (newLat != null && newLng != null) {
          _updateCabMovement(LatLng(newLat, newLng));
        }
      }
    });
  }

  void _updateCabMovement(LatLng newPos) {
    if (_cabPosition == null) {
      setState(() => _cabPosition = newPos);
      return;
    }

    final old = _cabPosition!;
    final dir = atan2(newPos.longitude - old.longitude,
            newPos.latitude - old.latitude) *
        (180 / pi);

    setState(() {
      _cabPosition = newPos;
      _cabRotation = dir;
    });
  }

  // ─────────────────────────────────────────────
  // 🎉 Complete Ride
  // ─────────────────────────────────────────────

  Future<void> _completeRide() async {
    setState(() => _isLoading = true);

    final url =
        Uri.parse("${ApiConfig.baseUrl}/api/complete_ride/${widget.cabId}");

    final response = await http.get(url);

    if (response.statusCode == 200) {
      setState(() => _isRideCompleted = true);

      Future.delayed(const Duration(seconds: 2), () {
        _showSuccessSheet();
      });
    }

    setState(() => _isLoading = false);
  }

  // ─────────────────────────────────────────────
  // 🎉 Success Modal
  // ─────────────────────────────────────────────

  void _showSuccessSheet() {
    showModalBottomSheet(
      context: context,
      isDismissible: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) {
        return SizedBox(
          height: 330,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Lottie.asset("assets/animations/success.json",
                  height: 160, repeat: false),
              const SizedBox(height: 8),
              const Text("Ride Completed!",
                  style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 5),
              const Text("Thank you for riding with us.",
                  style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.pop(context);
                  widget.onRideCompleted();
                },
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(200, 45),
                  backgroundColor: Colors.green,
                ),
                child: const Text("Done"),
              ),
            ],
          ),
        );
      },
    );
  }

  // ─────────────────────────────────────────────
  // 🧭 Bottom UI based on stage
  // ─────────────────────────────────────────────

  Widget _buildBottomUI() {
    switch (_uiStage) {
      case "arrival_animation":
        return Lottie.asset("assets/animations/driver_arriving.json", height: 180);

      case "show_start_button":
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Driver is arriving...",
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500)),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () {
                setState(() => _uiStage = "ride_starting");

                Future.delayed(const Duration(seconds: 2), () {
                  setState(() => _uiStage = "show_complete_button");
                });
              },
              style: ElevatedButton.styleFrom(
                  minimumSize: const Size(200, 45)),
              child: const Text("Start Ride"),
            ),
          ],
        );

      case "ride_starting":
        return Lottie.asset("assets/animations/ride_starting.json", height: 180);

      case "show_complete_button":
        return ElevatedButton(
          onPressed: _completeRide,
          style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              minimumSize: const Size(230, 48)),
          child: _isLoading
              ? const CircularProgressIndicator(color: Colors.white)
              : const Text("Ride Completed"),
        );
    }
    return const SizedBox();
  }

  // ─────────────────────────────────────────────
  // 🗺 Main UI
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Live Ride Tracking")),
      body: Stack(
        children: [
          // MAP
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
                userAgentPackageName: 'smart_cab_allocation',
              ),

              // CAB Marker
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
                            size: 40, color: Colors.orange),
                      ),
                    ),
                  ],
                ),

              // User markers
              flutter_map.MarkerLayer(
                markers: [
                  flutter_map.Marker(
                    point: widget.userSource,
                    width: 60,
                    height: 60,
                    child: const Icon(Icons.location_pin,
                        color: Colors.blueAccent, size: 38),
                  ),
                  flutter_map.Marker(
                    point: widget.userDestination,
                    width: 60,
                    height: 60,
                    child: const Icon(Icons.flag,
                        color: Colors.green, size: 38),
                  ),
                ],
              ),
            ],
          ),

          // BOTTOM UI
          Positioned(
            bottom: 25,
            left: 0,
            right: 0,
            child: Center(child: _buildBottomUI()),
          ),
        ],
      ),
    );
  }
}
