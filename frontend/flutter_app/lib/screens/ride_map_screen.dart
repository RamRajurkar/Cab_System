import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import '../utils/constants.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class RideMapScreen extends StatefulWidget {
  @override
  _RideMapScreenState createState() => _RideMapScreenState();
}

class _RideMapScreenState extends State<RideMapScreen> {
  MapController _mapController = MapController();
  LatLng? _currentLocation;
  List<LatLng> _routePoints = [];
  Database? _database;
  bool _isLoadingRoute = false; // New state variable for loading indicator

  @override
  void initState() {
    super.initState();
    _initDatabase();
    _getCurrentLocation();
  }

  @override
  void dispose() {
    _database?.close(); // Close the database when the widget is disposed
    super.dispose();
  }

  Future<void> _initDatabase() async {
    _database = await openDatabase(
      join(await getDatabasesPath(), 'location_database.db'),
      onCreate: (db, version) {
        return db.execute(
          'CREATE TABLE locations(id INTEGER PRIMARY KEY, latitude REAL, longitude REAL, timestamp TEXT)',
        );
      },
      version: 1,
    );
  }

  Future<void> _insertLocation(Position position) async {
    await _database?.insert(
      'locations',
      {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'timestamp': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  void _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return Future.error(
          'Location permissions are permanently denied, we cannot request permissions.');
    }

    Geolocator.getPositionStream(locationSettings: LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10, // Update every 10 meters
    )).listen((Position position) {
      setState(() {
        _currentLocation = LatLng(position.latitude, position.longitude);
        _mapController.move(_currentLocation!, _mapController.zoom);
      });
      _insertLocation(position);
    });
  }

  Future<void> _getRoute(LatLng start, LatLng end) async {
    setState(() {
      _isLoadingRoute = true;
    });
    try {
      final String osrmUrl = '${AppConstants.osrmBaseUrl}/route/v1/driving/'
          '${start.longitude},${start.latitude};${end.longitude},${end.latitude}'
          '?geometries=geojson&overview=full';

      final response = await http.get(Uri.parse(osrmUrl));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<dynamic> coordinates = data['routes'][0]['geometry']['coordinates'];
        setState(() {
          _routePoints = coordinates
              .map((coord) => LatLng(coord[1], coord[0]))
              .toList();
        });
      } else {
        print('Failed to load route: ${response.statusCode}');
        // Optionally show a user-friendly error message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load route: ${response.statusCode}')),
        );
      }
    } catch (e) {
      print('Error fetching route: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error fetching route: $e')),
      );
    } finally {
      setState(() {
        _isLoadingRoute = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ride Map'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
      ),
      body: _currentLocation == null
          ? const Center(child: CircularProgressIndicator()) // Show loading indicator while fetching current location
          : Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    center: _currentLocation,
                    zoom: 15.0,
                    onTap: (_, latlng) => _handleMapTap(latlng), // Allow setting destination by tapping
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                      subdomains: const ['a', 'b', 'c'],
                    ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          width: 40.0,
                          height: 40.0,
                          point: _currentLocation!,
                          builder: (ctx) => const Icon(
                            Icons.person_pin_circle,
                            color: Colors.blueAccent,
                            size: 40.0,
                          ),
                        ),
                        if (_routePoints.isNotEmpty) // Show destination marker if a route is present
                          Marker(
                            width: 40.0,
                            height: 40.0,
                            point: _routePoints.last, // Last point of the route is the destination
                            builder: (ctx) => const Icon(
                              Icons.location_on,
                              color: Colors.green,
                              size: 40.0,
                            ),
                          ),
                      ],
                    ),
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: _routePoints,
                          strokeWidth: 5.0,
                          color: Colors.blue,
                          // Add a gradient or custom pattern for better visual appeal
                        ),
                      ],
                    ),
                  ],
                ),
                if (_isLoadingRoute)
                  Container(
                    color: Colors.black.withOpacity(0.5),
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ), // Loading overlay
                Positioned(
                  bottom: 16.0,
                  left: 16.0,
                  right: 16.0,
                  child: Column(
                    children: [
                      FloatingActionButton.extended(
                        onPressed: _showDestinationInputDialog,
                        label: const Text('Set Destination'),
                        icon: const Icon(Icons.alt_route),
                        backgroundColor: Theme.of(context).colorScheme.secondary,
                        foregroundColor: Colors.white,
                      ),
                      const SizedBox(height: 8),
                      if (_routePoints.isNotEmpty)
                        FloatingActionButton.extended(
                          onPressed: () {
                            setState(() {
                              _routePoints.clear(); // Clear route
                            });
                          },
                          label: const Text('Clear Route'),
                          icon: const Icon(Icons.clear),
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  void _handleMapTap(LatLng latlng) {
    // This can be used to set a destination by tapping on the map
    // For now, we'll keep the dialog for explicit input.
    // You could update a temporary marker here and then confirm with a button.
  }

  void _showDestinationInputDialog() {
    TextEditingController latController = TextEditingController();
    TextEditingController lonController = TextEditingController();

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Enter Destination Coordinates'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: latController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Latitude'),
              ),
              TextField(
                controller: lonController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Longitude'),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            ElevatedButton(
              child: const Text('Get Route'),
              onPressed: () {
                final double? lat = double.tryParse(latController.text);
                final double? lon = double.tryParse(lonController.text);
                if (lat != null && lon != null && _currentLocation != null) {
                  _getRoute(_currentLocation!, LatLng(lat, lon));
                  Navigator.of(context).pop();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please enter valid coordinates.')),
                  );
                }
              },
            ),
          ],
        );
      },
    );
  }
}