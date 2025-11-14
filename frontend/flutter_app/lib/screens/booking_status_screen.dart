// booking_status_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math'; // gives max(), atan2(), pi
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_map/flutter_map.dart' as flutter_map;
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

// Optional lottie - if missing, code uses fallbacks
// Add `lottie` to pubspec.yaml for best effect
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
  // Map & realtime
  late flutter_map.MapController _mapController;
  late WebSocketChannel _channel;
  LatLng? _cabPosition;
  double _cabRotation = 0.0;

  // UI & state
  String _stage =
      'finding_driver'; // finding_driver -> arriving -> show_start -> ride_started -> show_complete -> completed
  bool _isLoading = false;
  bool _isRideCompleted = false;
  bool _arrivedDialogShown = false;

  // ETA
  Timer? _etaTimer;
  Duration _eta = const Duration(minutes: 3); // initial estimated ETA

  // animation controllers
  late AnimationController _pickupPulseController;
  late Animation<double> _pickupPulseAnim;

  // polyline (simple straight interpolation)
  List<LatLng> _routePoints = [];

  // smoothing movement
  Timer? _moveTimer;
  LatLng? _targetPos;

  @override
  void initState() {
    super.initState();
    _mapController = flutter_map.MapController();
    _cabPosition = widget.cabInitialPosition;

    // pulse
    _pickupPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _pickupPulseAnim =
        Tween<double>(begin: 0.7, end: 1.15).animate(CurvedAnimation(parent: _pickupPulseController, curve: Curves.easeOut));
    _pickupPulseController.repeat(reverse: true);

    // start connecting
    _connectWebSocket();

    // compute simple route (straight interpolation) to draw polyline
    _routePoints = _computeRoute(widget.cabInitialPosition, widget.userSource, widget.userDestination);

    // finding-driver stage: after small delay move to arriving
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _stage = 'arriving');
        // start ETA countdown
        _startEtaCountdown();
      }
    });
  }

  @override
  void dispose() {
    _channel.sink.close(status.goingAway);
    _etaTimer?.cancel();
    _moveTimer?.cancel();
    _pickupPulseController.dispose();
    super.dispose();
  }

  // ---------------- WebSocket & movement ----------------

  void _connectWebSocket() {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(ApiConfig.wsUrl));
      _channel.stream.listen((event) {
        try {
          final data = jsonDecode(event);
          if (data['cab_id'] == widget.cabId) {
            final nlat = data['latitude']?.toDouble();
            final nlng = data['longitude']?.toDouble();
            if (nlat != null && nlng != null) {
              _startSmoothMove(LatLng(nlat, nlng));
            }
            if (data['status'] == 'Arrived') {
              _onCabArrived();
            }
          }
        } catch (e) {
          debugPrint("ws parse error: $e");
        }
      }, onError: (e) {
        debugPrint("ws err: $e");
      });
    } catch (e) {
      debugPrint("ws connect failed: $e");
    }
  }

  // Smooth interpolation to new position
  void _startSmoothMove(LatLng newPos) {
    _moveTimer?.cancel();
    final old = _cabPosition ?? newPos;
    const steps = 30;
    int step = 0;
    _targetPos = newPos;
    _moveTimer = Timer.periodic(const Duration(milliseconds: 33), (t) {
      step++;
      if (step >= steps) {
        t.cancel();
        setState(() {
          _cabPosition = newPos;
          _cabRotation = _calcRotation(old, newPos);
        });
        return;
      }
      final f = step / steps;
      final lat = old.latitude + (newPos.latitude - old.latitude) * f;
      final lng = old.longitude + (newPos.longitude - old.longitude) * f;
      setState(() {
        _cabPosition = LatLng(lat, lng);
        _cabRotation = _calcRotation(old, newPos);
      });
    });
  }

  double _calcRotation(LatLng a, LatLng b) {
    return atan2(b.longitude - a.longitude, b.latitude - a.latitude) * (180 / pi);
  }

  void _onCabArrived() {
    // haptic + dialog
    HapticFeedback.vibrate();
    if (!_arrivedDialogShown && mounted) {
      _arrivedDialogShown = true;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text("Driver arrived"),
          content: const Text("Your driver is at the pickup point. Please board the vehicle."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("OK")),
          ],
        ),
      );
      setState(() {
        _stage = 'show_start';
      });
    }
  }

  // ---------------- ETA countdown ----------------

  void _startEtaCountdown() {
    // crude ETA calculation: distance / assumed speed
    _eta = _estimateEta(_cabPosition ?? widget.cabInitialPosition, widget.userSource);
    _etaTimer?.cancel();
    _etaTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_eta.inSeconds <= 0) {
        t.cancel();
        return;
      }
      setState(() => _eta = _eta - const Duration(seconds: 1));
    });
  }

  Duration _estimateEta(LatLng from, LatLng to) {
    final km = Distance().as(LengthUnit.Kilometer, from, to);
    // assume average speed 30 km/h = 0.5 km/min
    final minutes = (km / 0.5).ceil();
    return Duration(minutes: max<int>(1, minutes));
  }

  // ---------------- polyline generator ----------------

  List<LatLng> _computeRoute(LatLng cab, LatLng src, LatLng dest) {
    // simple polyline: cab -> src -> dest with interpolation
    final points = <LatLng>[];
    // interpolation helper
    List<LatLng> interp(LatLng a, LatLng b, int parts) {
      final out = <LatLng>[];
      for (int i = 0; i <= parts; i++) {
        final t = i / parts;
        out.add(LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t));
      }
      return out;
    }

    points.addAll(interp(cab, src, 6));
    points.addAll(interp(src, dest, 10));
    return points;
  }

  // ---------------- Ride actions ----------------

  Future<void> _startRidePressed() async {
    HapticFeedback.mediumImpact();
    setState(() => _stage = 'ride_starting');

    // small delay/animation then set on trip
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _stage = 'on_trip');
  }

  Future<void> _completeRide() async {
    setState(() => _isLoading = true);

    final url = Uri.parse('${ApiConfig.baseUrl}/api/complete_ride/${widget.cabId}');
    try {
      final resp = await http.get(url);
      debugPrint('complete ride resp: ${resp.statusCode} ${resp.body}');
      if (resp.statusCode == 200) {
        HapticFeedback.heavyImpact();
        setState(() {
          _stage = 'completed';
          _isRideCompleted = true;
        });
        // show success
        _showSuccessSheet();
        // refresh cabs in parent
        widget.onCabsRefresh();
        widget.onRideCompleted();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Complete ride failed (${resp.statusCode})')));
      }
    } catch (e) {
      debugPrint('complete error: $e');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Network error')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ---------------- Success sheet ----------------

  void _showSuccessSheet() {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isDismissible: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(18),
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // try Lottie, fallback to icon
                SizedBox(
                  height: 150,
                  child: Builder(builder: (context) {
                    try {
                      return Lottie.asset('assets/animations/success.json', repeat: false);
                    } catch (_) {
                      return const Icon(Icons.check_circle, size: 120, color: Colors.green);
                    }
                  }),
                ),
                const SizedBox(height: 8),
                const Text('Ride Completed!', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                const Text('Thanks for riding with us.', textAlign: TextAlign.center),
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    if (Navigator.canPop(context)) Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  child: const Text('Done'),
                ),
                const SizedBox(height: 8),
                _buildRideTimeline(),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------- Ride timeline ----------------

  Widget _buildRideTimeline() {
    final List<Map<String, dynamic>> steps = [
      {'label': 'Pickup', 'done': _stage != 'finding_driver'},
      {'label': 'Start', 'done': _stage == 'on_trip' || _stage == 'completed'},
      {'label': 'On Trip', 'done': _stage == 'on_trip' || _stage == 'completed'},
      {'label': 'Completed', 'done': _stage == 'completed'},
    ];

    return Column(
      children: steps.map((s) {
        return Row(
          children: [
            Icon(s['done'] ? Icons.check_circle : Icons.radio_button_unchecked, color: s['done'] ? Colors.green : Colors.grey),
            const SizedBox(width: 8),
            Text(s['label'], style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        );
      }).toList(),
    );
  }

  // ---------------- UI pieces ----------------

  String _formatEta() {
    final m = _eta.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _eta.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${_eta.inHours > 0 ? '${_eta.inHours}:' : ''}$m:$s';
  }

  String _pickupDistanceLabel() {
    if (_cabPosition == null) return '';
    final meters = Distance().as(LengthUnit.Meter, _cabPosition!, widget.userSource).round();
    if (meters >= 1000) {
      final km = (meters / 1000);
      return '${km.toStringAsFixed(1)} km';
    }
    return '$meters m';
  }

  // ---------------- Main build ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Ride Tracking'),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          // Map
          flutter_map.FlutterMap(
            mapController: _mapController,
            options: flutter_map.MapOptions(
              initialCenter: widget.cabInitialPosition,
              initialZoom: 14,
            ),
            children: [
              flutter_map.TileLayer(
                urlTemplate: "https://api.maptiler.com/maps/streets/{z}/{x}/{y}.png?key=NF4AhANXs6D1lsaZ3uik",
                userAgentPackageName: 'smart_cab_allocation',
              ),

              // route polyline
              if (_routePoints.isNotEmpty)
                flutter_map.PolylineLayer(
                  polylines: [
                    flutter_map.Polyline(points: _routePoints, strokeWidth: 4, color: Colors.blueAccent),
                  ],
                ),

              // cab marker
              if (_cabPosition != null)
                flutter_map.MarkerLayer(
                  markers: [
                    flutter_map.Marker(
                      point: _cabPosition!,
                      width: 60,
                      height: 60,
                      child: Transform.rotate(
                        angle: _cabRotation * pi / 180,
                        child: const Icon(Icons.local_taxi, size: 40, color: Colors.orange),
                      ),
                    ),
                  ],
                ),

              // pickup marker with pulsing effect + label
              flutter_map.MarkerLayer(
                markers: [
                  flutter_map.Marker(
                    point: widget.userSource,
                    width: 120,
                    height: 120,
                    child: Center(
                      child: AnimatedBuilder(
                        animation: _pickupPulseController,
                        builder: (_, __) {
                          final scale = _pickupPulseAnim.value;
                          return Column(
                            children: [
                              Transform.scale(
                                scale: scale,
                                child: Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: Colors.blue.withOpacity(0.15),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              const Icon(Icons.location_on, color: Colors.blueAccent, size: 36),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6)]),
                                child: Column(
                                  children: [
                                    Text('Pickup in', style: TextStyle(fontSize: 12, color: Colors.grey[700])),
                                    Text(_pickupDistanceLabel(), style: const TextStyle(fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),

                  // destination marker
                  flutter_map.Marker(
                    point: widget.userDestination,
                    width: 60,
                    height: 60,
                    child: const Icon(Icons.flag, color: Colors.green, size: 36),
                  ),
                ],
              ),
            ],
          ),

          // top-left driver mini-card
          Positioned(
            top: 18,
            left: 12,
            child: _driverMiniCard(),
          ),

          // draggable bottom sheet like UI (snap)
          Positioned(
            left: 0,
            right: 0,
            bottom: 18,
            child: _buildDraggableCard(context),
          ),
        ],
      ),
    );
  }

  // driver mini card widget
  Widget _driverMiniCard() {
    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        width: 240,
        child: Row(
          children: [
            // placeholder avatar
            ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: Container(
                width: 52,
                height: 52,
                color: Colors.grey[200],
                child: const Icon(Icons.person, size: 34, color: Colors.black54),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.cabName, style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Row(
                    children: const [
                      Icon(Icons.star, color: Colors.amber, size: 14),
                      SizedBox(width: 4),
                      Text('4.8', style: TextStyle(fontSize: 12)),
                      SizedBox(width: 10),
                      Text('Swift • KA-01-1234', style: TextStyle(fontSize: 12, color: Colors.black54)),
                    ],
                  )
                ],
              ),
            )
          ],
        ),
      ),
    );
  }

  // Draggable-like card (not full DraggableScrollableSheet to keep compatibility)
  Widget _buildDraggableCard(BuildContext ctx) {
    return GestureDetector(
      // allow tapping to expand - toggle between compact and expanded
      onTap: () {
        // cycles stages for demo: finding -> arriving -> show_start -> ride_starting -> on_trip -> show_complete -> completed
        if (_stage == 'finding_driver') {
          setState(() => _stage = 'arriving');
        } else if (_stage == 'arriving') {
          setState(() => _stage = 'show_start');
        } else if (_stage == 'show_start') {
          _startRidePressed();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 12)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // handle
            Container(width: 50, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(6))),
            const SizedBox(height: 10),

            // stage-specific content
            if (_stage == 'finding_driver') ...[
              _findingDriverContent(),
            ] else if (_stage == 'arriving') ...[
              _arrivingContent(),
            ] else if (_stage == 'show_start') ...[
              _startButtonContent(),
            ] else if (_stage == 'ride_starting') ...[
              _rideStartingContent(),
            ] else if (_stage == 'on_trip') ...[
              _onTripContent(),
            ] else if (_stage == 'show_complete') ...[
              _completeButtonContent(),
            ] else if (_stage == 'completed') ...[
              _completedContent(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _findingDriverContent() {
    return Row(
      children: [
        SizedBox(width: 72, height: 72, child: _lottieOrFallback('assets/animations/finding_driver.json', 72)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Finding best driver...', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text('We are checking nearby cabs and assigning the best match.', style: TextStyle(color: Colors.black54)),
          ]),
        ),
        IconButton(onPressed: () {}, icon: const Icon(Icons.more_horiz)),
      ],
    );
  }

  Widget _arrivingContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          SizedBox(width: 72, height: 72, child: _lottieOrFallback('assets/animations/driver_arriving.json', 72)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Driver is arriving', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('ETA: ${_formatEta()}', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('Pickup: ${widget.userSource.latitude.toStringAsFixed(4)}, ${widget.userSource.longitude.toStringAsFixed(4)}', style: const TextStyle(color: Colors.black54, fontSize: 12)),
          ])),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          ElevatedButton.icon(onPressed: () => setState(() => _stage = 'show_start'), icon: const Icon(Icons.call), label: const Text('Contact Driver')),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: () {}, child: const Text('Share ETA')),
        ])
      ],
    );
  }

  Widget _startButtonContent() {
    return Column(
      children: [
        const Text('Driver is here', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _startRidePressed,
          style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          child: const Text('Start Ride'),
        ),
      ],
    );
  }

  Widget _rideStartingContent() {
    return Row(
      children: [
        SizedBox(width: 72, height: 72, child: _lottieOrFallback('assets/animations/ride_starting.json', 72)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
          Text('Ride starting', style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 6),
          Text('Enjoy your ride. We will notify you when completed.'),
        ])),
      ],
    );
  }

  Widget _onTripContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('On trip • Fare: ₹${widget.fare.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('Tap button when your ride is complete.'),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: () {
            setState(() => _stage = 'show_complete');
          },
          style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          child: const Text('Mark as Complete'),
        ),
      ],
    );
  }

  Widget _completeButtonContent() {
    return Column(
      children: [
        const Text('Trip in progress', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _completeRide,
          style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(44), backgroundColor: Colors.green),
          child: _isLoading ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Text('Ride Completed'),
        )
      ],
    );
  }

  Widget _completedContent() {
    return Column(
      children: [
        const Text('Ride Completed', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Fare paid: ₹${widget.fare.toStringAsFixed(2)}'),
        const SizedBox(height: 8),
        ElevatedButton(onPressed: () => _showSuccessSheet(), child: const Text('View Receipt')),
      ],
    );
  }

  // helper: try to render lottie or fallback to simple icon
  Widget _lottieOrFallback(String asset, double size) {
    try {
      return Lottie.asset(asset, width: size, height: size, fit: BoxFit.contain);
    } catch (_) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        child: const Icon(Icons.directions_car, size: 36, color: Colors.orange),
      );
    }
  }
}
