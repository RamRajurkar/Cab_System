// -------------------- FIXED & CLEANED MAP_SCREEN.DART -----------------------

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
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

class MapScreen extends StatefulWidget {
  const MapScreen({Key? key}) : super(key: key);

  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  late final AnimatedMapController _animatedMapController;
  flutter_map.MapController get _mapController =>
      _animatedMapController.mapController;

  LatLng? _currentLocation;
  LatLng? _sourceLocation;
  LatLng? _destinationLocation;
  List<LatLng> _routePoints = [];

  Database? _database;
  List<Map<String, dynamic>> _cabLocations = [];

  final TextEditingController _sourceController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();
  Timer? _cabTimer;

  bool _isLoading = false;
  String? _errorMessage;
  Map<String, dynamic>? _foundCabDetails;
  Map<String, dynamic>? _assignedCab;

  late DraggableScrollableController _sheetController;

  @override
  void initState() {
    super.initState();

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
    _fetchCabLocations();
    _cabTimer =
        Timer.periodic(const Duration(seconds: 5), (t) => _fetchCabLocations());
  }

  @override
  void dispose() {
    _sourceController.dispose();
    _destinationController.dispose();
    _database?.close();
    _cabTimer?.cancel();
    _animatedMapController.dispose();
    _sheetController.dispose();
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

    _mapController.move(_currentLocation!, 13);

    Geolocator.getPositionStream().listen((p) async {
      setState(() => _currentLocation = LatLng(p.latitude, p.longitude));
      await _insertLocation(p);
    });
  }

  // ---------------------- FETCH CAB LOCATIONS ----------------------

  Future<void> _fetchCabLocations() async {
    final url = Uri.parse('${ApiConfig.baseUrl}/api/cabs');

    try {
      final resp = await http.get(url);

      if (resp.statusCode == 200) {
        final List<dynamic> data = json.decode(resp.body);

        final List<Map<String, dynamic>> cabs = [];
        for (var c in data) {
          if (c['latitude'] != null && c['longitude'] != null) {
            cabs.add({
              'cab_id': c['cab_id'],
              'name': c['name'] ?? 'Cab',
              'status': c['status'] ?? 'Unknown',
              'position': LatLng(c['latitude'], c['longitude']),
            });
          }
        }

        setState(() => _cabLocations = cabs);
      }
    } catch (e) {
      debugPrint("💥 Fetch cabs error: $e");
    }
  }

  // ---------------------- ROUTE ----------------------

  Future<void> _calculateRoute() async {
    if (_sourceLocation == null || _destinationLocation == null) return;

    try {
      final url = Uri.parse(
          'https://router.project-osrm.org/route/v1/driving/${_sourceLocation!.longitude},${_sourceLocation!.latitude};${_destinationLocation!.longitude},${_destinationLocation!.latitude}?overview=full&geometries=geojson');

      final resp = await http.get(url);

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0]['geometry']['coordinates'] as List;

          setState(() {
            _routePoints = route.map((e) => LatLng(e[1], e[0])).toList();
          });
        }
      }
    } catch (e) {
      debugPrint("💥 Route error: $e");
    }
  }

  // ---------------------- FIND CAB ----------------------

  Future<void> _findCab() async {
    if (_sourceLocation == null || _destinationLocation == null) {
      setState(() => _errorMessage = 'Select both pickup & drop.');
      return;
    }

    setState(() => _isLoading = true);

    final url = Uri.parse('${ApiConfig.baseUrl}/api/find_cab');

    final body = json.encode({
      'start_latitude': _sourceLocation!.latitude,
      'start_longitude': _sourceLocation!.longitude,
      'end_latitude': _destinationLocation!.latitude,
      'end_longitude': _destinationLocation!.longitude,
    });

    try {
      final resp = await http.post(url,
          headers: {'Content-Type': 'application/json'}, body: body);

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        setState(() => _foundCabDetails = data);
      } else {
        setState(() => _errorMessage = 'Failed: ${resp.statusCode}');
      }
    } catch (e) {
      setState(() => _errorMessage = 'Error finding cab: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ---------------------- BOOK CAB ----------------------

  Future<void> _bookRide(Map<String, dynamic> option) async {
    final cab = option['cab'];
    final cabId = cab['cab_id'];

    final url = Uri.parse('${ApiConfig.baseUrl}/api/book_cab');

    final body = json.encode({
      'cab_id': cabId,
      'start_latitude': _sourceLocation!.latitude,
      'start_longitude': _sourceLocation!.longitude,
      'end_latitude': _destinationLocation!.latitude,
      'end_longitude': _destinationLocation!.longitude,
      'is_shared': option['is_shared'] ?? false,
    });

    try {
      setState(() => _isLoading = true);

      final resp = await http.post(url,
          headers: {'Content-Type': 'application/json'}, body: body);

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        setState(() => _assignedCab = data);

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ride booked successfully!')),
        );
      }
    } catch (e) {
      debugPrint("💥 Booking error: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _onBookNow(int cabId, Map<String, dynamic> option) async {
    await _bookRide(option);

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Cab Booking'),
        actions: [
          IconButton(
              onPressed: _fetchCabLocations, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Stack(
        children: [
          // ---------------- MAP ----------------

          flutter_map.FlutterMap(
            mapController: _mapController,
            options: flutter_map.MapOptions(
              initialCenter: _currentLocation ?? const LatLng(20.5937, 78.9629),
              initialZoom: 13,
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
                      strokeWidth: 4),
                ]),

              const CurrentLocationLayer(
                alignPositionOnUpdate: AlignOnUpdate.always,
                alignDirectionOnUpdate: AlignOnUpdate.never,
              ),

              flutter_map.MarkerLayer(
                markers: _cabLocations.map<flutter_map.Marker>((cab) {
                  final LatLng p = cab['position'];
                  return flutter_map.Marker(
                    point: p,
                    width: 60,
                    height: 60,
                    child: Icon(
                      Icons.local_taxi,
                      color: cab['status'] == 'Available'
                          ? Colors.green
                          : Colors.red,
                      size: 32,
                    ),
                  );
                }).toList(),
              ),
            ],
          ),

          // ---------------- LOADING ----------------

          if (_isLoading)
            const Center(
              child: SpinKitChasingDots(color: Colors.blue, size: 40),
            ),

          // ---------------- ERROR MESSAGE ----------------

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
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            ),

          // ---------------- BOTTOM SHEET ----------------

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
                  boxShadow: [
                    BoxShadow(color: Colors.black26, blurRadius: 8)
                  ],
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
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),

                      const SizedBox(height: 12),

                      _buildTextField(
                          _sourceController, 'Pickup Location', Icons.location_on),

                      const SizedBox(height: 10),

                      _buildTextField(_destinationController,
                          'Drop Location', Icons.flag),

                      const SizedBox(height: 14),

                      ElevatedButton.icon(
                        onPressed: _findCab,
                        icon: const Icon(Icons.search),
                        label: const Text('Find Cab'),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(45),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      ),

                      const SizedBox(height: 12),

                      // -------- SHOW AVAILABLE CABS --------

                      if (_foundCabDetails != null &&
                          _foundCabDetails!['available_cabs'] != null) ...[
                        ..._buildAvailableCabs(),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ---------------------- CAB LIST BUILDER ----------------------

  List<Widget> _buildAvailableCabs() {
    final List options = _foundCabDetails!['available_cabs'];

    return List.generate(options.length, (i) {
      final option = options[i];
      final cab = option['cab'];

      // Safe extraction
      final rawFare = option['fare'];
      final rawDist = option['total_distance'];
      final rawPickup = option['pickup_distance'];

      // Safe conversion
      final fareValue = (rawFare is num)
          ? rawFare.toDouble()
          : double.tryParse(rawFare.toString()) ?? 0.0;

      final distValue = (rawDist is num)
          ? rawDist.toDouble()
          : double.tryParse(rawDist.toString()) ?? 0.0;

      final pickupValue = (rawPickup is num)
          ? rawPickup.toDouble()
          : double.tryParse(rawPickup.toString()) ?? 0.0;

      return RideCard(
        cabName: cab['name'] ?? 'Cab',
        cabStatus: option['status'] ?? 'Available',

        distanceToCab: "${pickupValue.toStringAsFixed(0)} m",
        distanceToDestination: "${distValue.toStringAsFixed(0)} m",

        startCoords:
            '${_sourceLocation?.latitude.toStringAsFixed(3)}, ${_sourceLocation?.longitude.toStringAsFixed(3)}',

        endCoords:
            '${_destinationLocation?.latitude.toStringAsFixed(3)}, ${_destinationLocation?.longitude.toStringAsFixed(3)}',

        isShared: option['is_shared'] ?? false,

        fare: fareValue.toStringAsFixed(2),

        cabId: cab['cab_id'],
        onBookNow: (cabId) => _onBookNow(cabId, option),
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
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
