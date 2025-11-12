import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // for kIsWeb
import 'package:flutter_map/flutter_map.dart' as flutter_map;
import 'package:flutter_map_animations/flutter_map_animations.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:geocoding/geocoding.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import '../widgets/ride_card.dart';
import '../config/api_config.dart'; // ✅ new config import

class MapScreen extends StatefulWidget {
  const MapScreen({Key? key}) : super(key: key);

  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  late final AnimatedMapController _animatedMapController;
  flutter_map.MapController get _mapController => _animatedMapController.mapController;

  LatLng? _currentLocation;
  bool _isLocating = false;
  LatLng? _sourceLocation;
  LatLng? _destinationLocation;
  List<LatLng> _routePoints = [];

  Database? _database;
  bool _isLoadingCabs = false;

  final TextEditingController _sourceController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();

  bool _isLoadingRoute = false;
  StreamSubscription<Position>? _positionStreamSub;
  double _currentZoom = 13.0;
  List<Map<String, dynamic>> _cabLocations = [];
  Timer? _cabLocationTimer;

  bool _isLoading = false;
  Map<String, dynamic>? _assignedCab;
  Map<String, dynamic>? _foundCabDetails;
  String? _errorMessage;
  bool _isRideCardVisible = true;

  // 📏 Utility
  String _formatDistance(double distanceInMeters) {
    if (distanceInMeters < 1000) {
      return '${distanceInMeters.toStringAsFixed(0)} m';
    } else {
      return '${(distanceInMeters / 1000).toStringAsFixed(2)} km';
    }
  }

  double _getDistance(LatLng point1, LatLng point2) {
    return Geolocator.distanceBetween(
      point1.latitude,
      point1.longitude,
      point2.latitude,
      point2.longitude,
    );
  }

  @override
  void initState() {
    if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
    } else {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    _animatedMapController = AnimatedMapController(vsync: this);
    _initDatabase();
    _getCurrentLocation();
    _fetchCabLocations();
    _cabLocationTimer = Timer.periodic(const Duration(seconds: 5), (timer) => _fetchCabLocations());
    super.initState();
  }

  @override
  void dispose() {
    _positionStreamSub?.cancel();
    _sourceController.dispose();
    _destinationController.dispose();
    _database?.close();
    _cabLocationTimer?.cancel();
    _animatedMapController.dispose();
    super.dispose();
  }

  // 🧱 Local DB setup
  Future<void> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final dbFilePath = p.join(dbPath, 'location_database.db');
    _database = await openDatabase(
      dbFilePath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          "CREATE TABLE locations(id INTEGER PRIMARY KEY AUTOINCREMENT, latitude REAL, longitude REAL, timestamp TEXT)",
        );
      },
    );
  }

  Future<void> _insertLocation(Position position) async {
    if (_database == null) return;
    await _database!.insert(
      'locations',
      {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'timestamp': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // 📍 Location
  void _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    if (permission == LocationPermission.deniedForever) return;

    final locationSettings = const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    );

    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        setState(() {
          _currentLocation = LatLng(last.latitude, last.longitude);
        });
        _mapController.move(_currentLocation!, _currentZoom);
      }
    } catch (_) {}

    _positionStreamSub = Geolocator.getPositionStream(locationSettings: locationSettings)
        .listen((Position position) async {
      final posLatLng = LatLng(position.latitude, position.longitude);
      setState(() => _currentLocation = posLatLng);
      _mapController.move(posLatLng, _currentZoom);
      await _insertLocation(position);
    });
  }

  // 🚕 Fetch cabs from backend
  Future<void> _fetchCabLocations() async {
    try {
      final response = await http.get(Uri.parse('${ApiConfig.baseUrl}/api/cabs'));
      if (response.statusCode == 200) {
        final List<dynamic> fetchedCabData = json.decode(response.body);
        List<Map<String, dynamic>> availableCabs = [];

        for (var cab in fetchedCabData) {
          if (cab['latitude'] != null && cab['longitude'] != null) {
            final cabLatLng = LatLng(cab['latitude'], cab['longitude']);
            double? distance;
            if (_sourceLocation != null) {
              distance = _getDistance(_sourceLocation!, cabLatLng);
            }
            availableCabs.add({
              'id': cab['cab_id'],
              'name': cab['name'],
              'position': cabLatLng,
              'in_use': cab['status'] != 'Available',
              'status': cab['status'],
              'distance': distance,
            });
          }
        }

        if (_sourceLocation != null) {
          availableCabs.sort((a, b) {
            if (a['distance'] == null || b['distance'] == null) return 0;
            return (a['distance'] as double).compareTo(b['distance'] as double);
          });
        }

        setState(() {
          _cabLocations = availableCabs;
          _isLoadingCabs = false;
        });
      } else {
        setState(() => _errorMessage = 'Failed to load cabs: ${response.statusCode}');
      }
    } catch (e) {
      setState(() => _errorMessage = 'Error fetching cab locations: $e');
    }
  }

  // 🌍 Route calculation remains unchanged (for OSRM)
  Future<void> _calculateRoute() async {
    setState(() {
      _isLoadingRoute = true;
      _routePoints.clear();
      _errorMessage = null;
    });

    LatLng? start = _sourceLocation;
    LatLng? end = _destinationLocation;

    if (start == null || end == null) {
      setState(() {
        _errorMessage = 'Please select both source and destination.';
        _isLoadingRoute = false;
      });
      return;
    }

    try {
      final response = await http.get(Uri.parse(
          'https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?overview=full&geometries=geojson'));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0]['geometry']['coordinates'] as List;
          setState(() {
            _routePoints = route.map((coord) => LatLng(coord[1], coord[0])).toList();
            _isLoadingRoute = false;
          });
        } else {
          setState(() {
            _errorMessage = 'No route found.';
            _isLoadingRoute = false;
          });
        }
      } else {
        setState(() {
          _errorMessage = 'Failed to calculate route: ${response.statusCode}';
          _isLoadingRoute = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error calculating route: $e';
        _isLoadingRoute = false;
      });
    }
  }

  // 🧭 UI
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cab Booking'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchCabLocations),
        ],
      ),
      body: Stack(
        children: [
          flutter_map.FlutterMap(
            mapController: _mapController,
            options: flutter_map.MapOptions(
              initialCenter: _currentLocation ?? const LatLng(20.5937, 78.9629),
              initialZoom: _currentZoom,
              onTap: (tapPosition, latlng) {
                setState(() {
                  if (_sourceLocation == null) {
                    _sourceLocation = latlng;
                    _sourceController.text = '${latlng.latitude}, ${latlng.longitude}';
                    _destinationLocation = null;
                    _destinationController.clear();
                    _routePoints.clear();
                  } else if (_destinationLocation == null) {
                    _destinationLocation = latlng;
                    _destinationController.text = '${latlng.latitude}, ${latlng.longitude}';
                    _calculateRoute();
                  } else {
                    _sourceLocation = latlng;
                    _sourceController.text = '${latlng.latitude}, ${latlng.longitude}';
                    _destinationLocation = null;
                    _destinationController.clear();
                    _routePoints.clear();
                  }
                });
              },
            ),
            children: [
              // ✅ MapTiler fix
              flutter_map.TileLayer(
                urlTemplate: "https://api.maptiler.com/maps/streets/{z}/{x}/{y}.png?key=KBzdrfmOoPBjC10ncZB6	",
                userAgentPackageName: 'com.example.smart_cab_allocation',
              ),
              if (_routePoints.isNotEmpty)
                flutter_map.PolylineLayer(
                  polylines: [
                    flutter_map.Polyline(points: _routePoints, color: Colors.blue, strokeWidth: 5.0),
                  ],
                ),
              const CurrentLocationLayer(alignPositionOnUpdate: AlignOnUpdate.always),
              flutter_map.MarkerLayer(
                markers: _cabLocations.map((cab) {
                  return flutter_map.Marker(
                    point: cab['position'],
                    width: 80,
                    height: 80,
                    child: Icon(Icons.car_rental,
                        color: cab['in_use'] ? Colors.red : Colors.green, size: 30),
                  );
                }).toList(),
              ),
            ],
          ),
          if (_isLoading)
            const Center(child: SpinKitChasingDots(color: Colors.blue, size: 50.0)),
          if (_errorMessage != null)
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(10),
                color: Colors.red,
                child: Text(_errorMessage!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
              ),
            ),
        ],
      ),
    );
  }
}
