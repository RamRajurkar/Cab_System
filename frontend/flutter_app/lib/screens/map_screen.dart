// lib/screens/map_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as flutter_map;
import 'package:flutter_map_animations/flutter_map_animations.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import '../config/api_config.dart';
import '../widgets/ride_card.dart';
import 'booking_status_screen.dart';
import '../services/websocket_service.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({Key? key}) : super(key: key);

  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  // Map controllers
  late final AnimatedMapController _animatedMapController;
  flutter_map.MapController get _mapController =>
      _animatedMapController.mapController;
  double _mapZoom = 13.0;

  // Location & route
  LatLng? _currentLocation;
  LatLng? _sourceLocation;
  LatLng? _destinationLocation;
  List<LatLng> _routePoints = [];

  // DB + UI
  Database? _database;
  final TextEditingController _sourceController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();

  // Cab data keyed by cab_id for quick updates
  final Map<int, Map<String, dynamic>> _cabMap = {};

  // Animation timers per cab
  final Map<int, Timer?> _animTimers = {};

  // fallback API timer (kept small for initial load only)
  Timer? _cabTimer;

  // UI states
  bool _isLoading = false;
  String? _errorMessage;
  Map<String, dynamic>? _foundCabDetails;
  Map<String, dynamic>? _assignedCab;

  late DraggableScrollableController _sheetController;

  // WebSocket callback handle
  void Function(Map<String, dynamic>)? _wsCallback;

  // Interpolation settings
  static const int _animSteps = 20;
  static const Duration _animStepDuration = Duration(milliseconds: 60);

  @override
  void initState() {
    super.initState();

    // DB factory setup for desktop/web
    if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
    } else {
      final isDesktop =
          Platform.isWindows || Platform.isLinux || Platform.isMacOS;
      if (isDesktop) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
    }

    _animatedMapController = AnimatedMapController(vsync: this);
    _sheetController = DraggableScrollableController();

    _initDatabase();
    _getCurrentLocation();

    // initial fetch (fallback)
    _fetchCabLocations();

    // fallback periodic fetch (only as backup)
    _cabTimer =
        Timer.periodic(const Duration(seconds: 10), (t) => _fetchCabLocations());

    // Register websocket listener (global WS service)
    _wsCallback = (Map<String, dynamic> msg) {
      _handleWsMessage(msg);
    };
    WebSocketService().addListener(_wsCallback!);
  }

  @override
  void dispose() {
    _sourceController.dispose();
    _destinationController.dispose();
    _database?.close();
    _cabTimer?.cancel();
    _animatedMapController.dispose();
    _sheetController.dispose();

    // cancel any running anim timers
    for (var t in _animTimers.values) {
      t?.cancel();
    }
    _animTimers.clear();

    // remove WS listener
    if (_wsCallback != null) WebSocketService().removeListener(_wsCallback!);

    super.dispose();
  }

  // ---------------------- DATABASE ----------------------
  Future<void> _initDatabase() async {
    try {
      final dbPath = await getDatabasesPath();
      final dbFile = p.join(dbPath, 'location_database.db');
      _database = await openDatabase(dbFile, version: 1, onCreate: (db, _) {
        db.execute(
          "CREATE TABLE IF NOT EXISTS locations(id INTEGER PRIMARY KEY, latitude REAL, longitude REAL, timestamp TEXT)",
        );
      });
    } catch (e) {
      debugPrint("⚠️ Database init failed: $e");
    }
  }

  Future<void> _insertLocation(Position pos) async {
    if (_database == null) return;
    await _database!.insert('locations', {
      'latitude': pos.latitude,
      'longitude': pos.longitude,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // ---------------------- LOCATION ----------------------
  void _getCurrentLocation() async {
    bool service = await Geolocator.isLocationServiceEnabled();
    if (!service) return;

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied)
      perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.deniedForever) return;

    final pos = await Geolocator.getCurrentPosition();
    setState(() => _currentLocation = LatLng(pos.latitude, pos.longitude));

    // initial move
    try {
      _mapController.move(_currentLocation!, _mapZoom);
    } catch (_) {}

    Geolocator.getPositionStream().listen((p) async {
      setState(() => _currentLocation = LatLng(p.latitude, p.longitude));
      await _insertLocation(p);
    });
  }

  // ---------------------- WEBSOCKET HANDLING ----------------------
  void _handleWsMessage(Map<String, dynamic> msg) {
    // Expecting keys: cab_id, latitude, longitude, status (optional)
    try {
      if (!msg.containsKey('cab_id')) return;
      final rawId = msg['cab_id'];
      final int cabId =
          rawId is int ? rawId : int.tryParse(rawId.toString()) ?? -1;
      if (cabId == -1) return;

      final lat = double.tryParse(msg['latitude']?.toString() ?? '') ??
          (_cabMap[cabId]?['position']?.latitude ?? 0.0);
      final lng = double.tryParse(msg['longitude']?.toString() ?? '') ??
          (_cabMap[cabId]?['position']?.longitude ?? 0.0);

      final status = (msg['status'] ?? _cabMap[cabId]?['status'] ?? 'Unknown')
          .toString();

      final newPos = LatLng(lat, lng);

      // Update or insert cab entry in cabMap with immediate 'latest' pos stored,
      // but animate visual marker from previous position -> newPos.
      final existing = _cabMap[cabId];
      if (existing == null) {
        // Insert with starting pos = newPos (no animation)
        _cabMap[cabId] = {
          'cab_id': cabId,
          'name': msg['name'] ?? 'Cab',
          'status': status,
          'position': newPos,
        };
        setState(() {});
      } else {
        // Update name/status and animate position
        existing['status'] = status;
        existing['name'] = existing['name'] ?? msg['name'] ?? existing['name'];
        _startSmoothMoveForCab(cabId, newPos);
      }
    } catch (e) {
      debugPrint('WS handle error: $e');
    }
  }

  // Smooth move one cab from current stored position to target in small steps
  void _startSmoothMoveForCab(int cabId, LatLng target) {
    // Cancel existing animator
    _animTimers[cabId]?.cancel();

    final entry = _cabMap[cabId];
    if (entry == null) {
      _cabMap[cabId] = {
        'cab_id': cabId,
        'name': 'Cab',
        'status': 'Unknown',
        'position': target
      };
      setState(() {});
      return;
    }

    final start = entry['position'] as LatLng;
    final end = target;

    // If identical, just set and return
    if ((start.latitude - end.latitude).abs() < 1e-6 &&
        (start.longitude - end.longitude).abs() < 1e-6) {
      entry['position'] = end;
      setState(() {});
      return;
    }

    int step = 0;
    _animTimers[cabId] =
        Timer.periodic(_animStepDuration, (Timer timer) {
      step++;
      final t = (step / _animSteps).clamp(0.0, 1.0);
      final lat = start.latitude + (end.latitude - start.latitude) * t;
      final lng = start.longitude + (end.longitude - start.longitude) * t;
      final newPos = LatLng(lat, lng);

      // compute a simple bearing for nicer marker rotation if you want (not used here)
      final dx = end.longitude - start.longitude;
      final dy = end.latitude - start.latitude;
      final bearing = math.atan2(dx, dy) * 180 / math.pi;

      entry['position'] = newPos;
      entry['bearing'] = bearing;
      // Request rebuild
      if (mounted) setState(() {});
      // Auto-pan map to show movement when zoomed in & marker near center? optional:
      // _mapController.move(newPos, _mapZoom);

      if (t >= 1.0) {
        timer.cancel();
        _animTimers.remove(cabId);
        entry['position'] = end;
        if (mounted) setState(() {});
      }
    });
  }

  // ---------------------- ROUTE / FIND / BOOK (unchanged logic but safe conversions) ----------------------

  Future<void> _findCab() async {
    if (_sourceLocation == null || _destinationLocation == null) {
      setState(() => _errorMessage = 'Select both pickup & drop.');
      return;
    }
    setState(() => _isLoading = true);

    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/find_cab');
      final body = json.encode({
        'start_latitude': _sourceLocation!.latitude,
        'start_longitude': _sourceLocation!.longitude,
        'end_latitude': _destinationLocation!.latitude,
        'end_longitude': _destinationLocation!.longitude,
      });

      final resp = await http.post(url, headers: {'Content-Type': 'application/json'}, body: body);

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        setState(() {
          _foundCabDetails = data;
          _errorMessage = null;
        });
      } else {
        setState(() {
          _foundCabDetails = null;
          _errorMessage = 'Error finding cab: ${resp.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        _foundCabDetails = null;
        _errorMessage = 'Error finding cab: $e';
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }




                LatLng(option['cab']['latitude'], option['cab']['longitude']),
            userSource: _sourceLocation!,
            userDestination: _destinationLocation!,
            fare: double.parse(option['fare'].toString()),
            cabName: option['cab']['name'] ?? 'Cab',
            onCabsRefresh: _fetchCabLocations,
            onRideCompleted: () {
              setState(() {
                _foundCabDetails = null;
                _assignedCab = null;
              });
              _fetchCabLocations();
            },
          ),
        ),
      );
    }
  }

  // ---------------------- UI BUILD ----------------------
  @override
  Widget build(BuildContext context) {
    // Build markers from _cabMap values
    final markers = _cabMap.values.map<flutter_map.Marker>((entry) {
      final LatLng p = entry['position'] as LatLng;
      final int id = entry['cab_id'] as int;
      final status = entry['status'] ?? 'Unknown';
      final name = entry['name'] ?? 'Cab';
      final bearing = (entry['bearing'] ?? 0.0) as double;

      return flutter_map.Marker(
        point: p,
        width: 60,
        height: 60,
        // child uses Transform.rotate for visual bearing
        child: Transform.rotate(
          angle: bearing * math.pi / 180,
          child: Tooltip(
            message: '$name ($id) - $status',
            child: Icon(
              Icons.local_taxi,
              color: status == 'Available' ? Colors.green : Colors.red,
              size: 32,
            ),
          ),
        ),
      );
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Cab Booking'),
        actions: [
          IconButton(onPressed: _fetchCabLocations, icon: const Icon(Icons.refresh))
        ],
      ),
      body: Stack(
        children: [
          flutter_map.FlutterMap(
            mapController: _mapController,
            options: flutter_map.MapOptions(
              initialCenter: _currentLocation ?? const LatLng(20.5937, 78.9629),
              initialZoom: _mapZoom,
              onTap: (tapPos, latlng) {
                setState(() {
                  if (_sourceLocation == null) {
                    _sourceLocation = latlng;
                    _sourceController.text =
                        '${latlng.latitude}, ${latlng.longitude}';
                  } else if (_destinationLocation == null) {
                    _destinationLocation = latlng;
                    _destinationController.text =
                        '${latlng.latitude}, ${latlng.longitude}';
                    _calculateRoute();
                  } else {
                    _sourceLocation = latlng;
                    _sourceController.text =
                        '${latlng.latitude}, ${latlng.longitude}';
                    _destinationLocation = null;
                    _destinationController.clear();
                    _routePoints.clear();
                  }
                });
              },
            ),
            children: [
              flutter_map.TileLayer(
                urlTemplate:
                    "https://api.maptiler.com/maps/streets/{z}/{x}/{y}.png?key=NF4AhANXs6D1lsaZ3uik",
                userAgentPackageName: 'com.example.smart_cab_allocation',
              ),

              if (_routePoints.isNotEmpty)
                flutter_map.PolylineLayer(polylines: [
                  flutter_map.Polyline(
                    points: _routePoints,
                    color: Colors.blue,
                    strokeWidth: 4,
                  )
                ]),

              const CurrentLocationLayer(
                alignPositionOnUpdate: AlignOnUpdate.always,
                alignDirectionOnUpdate: AlignOnUpdate.never,
              ),

              // MarkerLayer from live WS + fallback API
              flutter_map.MarkerLayer(markers: markers),
            ],
          ),

          if (_isLoading)
            const Center(child: SpinKitChasingDots(color: Colors.blue, size: 40)),

          if (_errorMessage != null)
            Positioned(
              top: 70,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: Colors.redAccent,
                    borderRadius: BorderRadius.circular(10)),
                child: Text(_errorMessage!,
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center),
              ),
            ),

          DraggableScrollableSheet(
            controller: _sheetController,
            initialChildSize: 0.25,
            minChildSize: 0.18,
            maxChildSize: 0.65,
            builder: (context, scrollController) {
              return Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                  boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8)],
                ),
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  controller: scrollController,
                  child: Column(
                    children: [
                      Container(
                        width: 50,
                        height: 5,
                        decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(5)),
                      ),
                      const SizedBox(height: 12),
                      _buildTextField(
                          _sourceController, 'Pickup Location', Icons.location_on),
                      const SizedBox(height: 10),
                      _buildTextField(
                          _destinationController, 'Drop Location', Icons.flag),
                      const SizedBox(height: 14),
                      ElevatedButton.icon(
                        onPressed: _findCab,
                        icon: const Icon(Icons.search),
                        label: const Text('Find Cab'),
                        style: ElevatedButton.styleFrom(
                            minimumSize: const Size.fromHeight(45),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10))),
                      ),

                      const SizedBox(height: 12),

                      if (_foundCabDetails != null &&
                          _foundCabDetails!['available_cabs'] != null) ...[
                        ..._buildAvailableCabs(),
                      ],
                    ],
                  ),
                ),
      
            },
          ),
        ],
      ),
    );
  }

  Future<void> _bookRide(Map<String, dynamic> cabOption, bool isShared) async {
    if (_sourceLocation == null || _destinationLocation == null) {
      setState(() => _errorMessage = 'Select both pickup & drop.');
      return;
    }
    setState(() => _isLoading = true);

    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/book_ride');
      final body = json.encode({
        'cab_id': cabOption['cab_id'],
        'start_latitude': _sourceLocation!.latitude,
        'start_longitude': _sourceLocation!.longitude,
        'end_latitude': _destinationLocation!.latitude,
        'end_longitude': _destinationLocation!.longitude,
        'is_shared': isShared,
      });

      final resp = await http.post(url, headers: {'Content-Type': 'application/json'}, body: body);

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        setState(() {
          _assignedCab = data;
          _errorMessage = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ride booked successfully!')),);
      } else {
        debugPrint('Booking HTTP ${resp.statusCode}: ${resp.body}');
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Booking failed: ${resp.statusCode}')));
      }
    } catch (e) {
      debugPrint("💥 Booking error: $e");
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Booking error')));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _onBookNow(int cabId) async {
    if (_foundCabDetails == null || _foundCabDetails!['available_cabs'] == null) {
      debugPrint('Error: _foundCabDetails or available_cabs is null');
      return;
    }
    final option = _foundCabDetails['available_cabs'].firstWhere(
      (opt) => opt['cab']['cab_id'] == cabId,
      orElse: () => null,
    );
    if (option == null) {
      debugPrint('Error: Option not found for cabId $cabId');
      return;
    }
    await _bookRide(option, option['is_shared'] ?? false);
    if (_assignedCab != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BookingStatusScreen(
            cabId: cabId,
            cabInitialPosition:
                LatLng(option['cab']['latitude'], option['cab']['longitude']),
            userSource: _sourceLocation!,
            userDestination: _destinationLocation!,
          ),
        ),
      );
    }
  }

  // ---------------------- CAB LIST BUILDER ----------------------
  List<Widget> _buildAvailableCabs() {
    final List options = _foundCabDetails!['available_cabs'];

    return List.generate(options.length, (i) {
      final option = options[i];
      final cab = option['cab'];

      final rawFare = option['fare'];
      final rawDist = option['total_distance'];




      final rawPickup = option['pickup_distance'];

      final fareValue = (rawFare is num)
          ? rawFare.toDouble()
          : double.tryParse(rawFare.toString()) ?? 0.0;

      final distValue = (rawDist is num)
          ? rawDist.toDouble()
          : double.tryParse(rawDist.toString()) ?? 0.0;

      final pickupValue = (rawPickup is num)
          ? rawPickup.toDouble()
          : double.tryParse(rawPickup.toString()) ?? 0.0;

      final isShared = option['is_shared'] ?? false;

      return RideCard(
        cabName: cab['name'] ?? 'Cab',
        cabStatus: option['status'] ?? 'Available',
        distanceToCab:
            "${pickupValue.toStringAsFixed(0)} m",
        distanceToDestination:
            "${distValue.toStringAsFixed(0)} m",
        startCoords:
            '${_sourceLocation?.latitude.toStringAsFixed(3)}, ${_sourceLocation?.longitude.toStringAsFixed(3)}',
        endCoords:
            '${_destinationLocation?.latitude.toStringAsFixed(3)}, ${_destinationLocation?.longitude.toStringAsFixed(3)}',
        isShared: isShared,
        fare: fareValue.toStringAsFixed(2),
        cabId: cab['cab_id'],
        onBookNow: _onBookNow,
      );
    });
  }

  // ---------------------- TEXT FIELD ----------------------
  Widget _buildTextField(TextEditingController c, String hint, IconData icon) {
    return TextField(
      controller: c,
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: Colors.blue),
        hintText: hint,
        filled: true,
        fillColor: Colors.grey[100],
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none),
      ),
    );
  }
}
