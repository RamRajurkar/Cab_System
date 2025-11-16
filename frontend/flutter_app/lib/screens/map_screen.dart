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
import '../services/cab_service.dart';
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
  String? _newRequestId;

  late CabService _cabService;

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
    _cabService = CabService();

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

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _foundCabDetails = null;
      _assignedCab = null;
      _newRequestId = null; // Reset new request ID
    });

    try {
      // final cabService = CabService(); // No longer needed as it's a class member
      final response = await _cabService.findCab(
        _sourceLocation!.latitude,
        _sourceLocation!.longitude,
        _destinationLocation!.latitude,
        _destinationLocation!.longitude,
      );

      if (response != null) {
        setState(() {
          _foundCabDetails = response;
          _newRequestId = response['new_request_id']; // Store new request ID
        });
        _sheetController.animateTo(0.5, // Expand to show options
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut);
      } else {
        setState(() => _errorMessage = 'No cabs or shared rides found.');
      }
    } catch (e) {
      setState(() => _errorMessage = 'Error finding cab: $e');
      debugPrint('Error finding cab: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ---------------------- BOOK CAB ----------------------

  Future<void> _bookCab(Map<String, dynamic> selectedOption) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // final cabService = CabService(); // No longer needed as it's a class member
      final isShared = selectedOption['is_shared'] ?? false;
      final primaryRequestId = selectedOption['primary_request_id'];

      final response = await _cabService.bookCab(
        _sourceLocation!.latitude,
        _sourceLocation!.longitude,
        _destinationLocation!.latitude,
        _destinationLocation!.longitude,
        selectedOption['cab_id'] as int,
        isShared: isShared,
        primaryRequestId: primaryRequestId,
        newRequestId: _newRequestId, // Pass the new request ID
      );

      if (response != null && response['ride_id'] != null) {
        setState(() {
          _assignedCab = selectedOption;
          _foundCabDetails = null;
        });
        _sheetController.animateTo(0.0, // Collapse the sheet
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => BookingStatusScreen(
              rideId: response['ride_id'],
              cabId: selectedOption['cab_id'],
              cabInitialPosition: LatLng(selectedOption['latitude'], selectedOption['longitude']),
              userSource: _sourceLocation!,
              userDestination: _destinationLocation!,
              fare: selectedOption['fare'].toDouble(),
              cabName: selectedOption['cab_name'],
              onCabsRefresh: _fetchCabLocations,
              onRideCompleted: () {
                _sheetController.animateTo(0.0,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut);
                _fetchCabLocations();
              },
            ),
          ),
        );
      } else {
        setState(() => _errorMessage = 'Failed to book cab.');
      }
    } catch (e) {
      setState(() => _errorMessage = 'Error booking cab: $e');
      debugPrint('Error booking cab: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ---------------------- UI ----------------------

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

                      if (_foundCabDetails != null) ...[
                        if (_foundCabDetails!['individual_cabs'] != null)
                          ...(_foundCabDetails!['individual_cabs'] as List)
                              .map((cab) => RideCard(
                                     cabName: cab['name'],
                                     fare: (cab['fare'] as num).toDouble(),
                                     cabId: cab['cab_id'],
                                     onTap: () => _bookCab(cab),
                                   ))
                               .toList(),
                        if (_foundCabDetails!['shared_rides'] != null)
                          ...(_foundCabDetails!['shared_rides'] as List)
                              .map((ride) => RideCard(
                                     cabName: ride['name'],
                                     fare: (ride['fare'] as num).toDouble(),
                                     isShared: true,
                                     primaryRequestId: ride['primary_request_id'],
                                     cabId: ride['cab_id'],
                                     onTap: () => _bookCab(ride),
                                   ))
                               .toList(),
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
