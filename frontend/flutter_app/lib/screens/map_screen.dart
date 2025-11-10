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
import '../utils/constants.dart';

import '../widgets/ride_card.dart';

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
  Map<String, dynamic>? _foundCabDetails; // New state variable for found cab before booking
  String? _errorMessage;
  bool _isRideCardVisible = true;

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
    ); // Returns distance in meters
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
    _cabLocationTimer =
        Timer.periodic(const Duration(seconds: 5), (timer) => _fetchCabLocations());
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

    _positionStreamSub =
        Geolocator.getPositionStream(locationSettings: locationSettings)
            .listen((Position position) async {
      final posLatLng = LatLng(position.latitude, position.longitude);
      setState(() => _currentLocation = posLatLng);
      _mapController.move(posLatLng, _currentZoom);
      await _insertLocation(position);
    });
  }

  Future<void> _fetchCabLocations() async {
    try {
      final response =
          await http.get(Uri.parse('${AppConstants.baseUrl}/api/cabs'));
      if (response.statusCode == 200) {
        final List<dynamic> fetchedCabData = json.decode(response.body);
        List<Map<String, dynamic>> availableCabs = [];

        for (var cab in fetchedCabData) {
          if (cab['latitude'] != null &&
              cab['longitude'] != null) {
            final cabLatLng = LatLng(cab['latitude'], cab['longitude']);
            double? distance;
            if (_sourceLocation != null) {
              distance = _getDistance(_sourceLocation!, cabLatLng);
            }
            availableCabs.add({
              'id': cab['cab_id'], // Use cab_id from backend
              'name': cab['name'], // Add cab name
              'position': cabLatLng,
              'in_use': cab['status'] != 'Available', // Derive in_use from status
              'status': cab['status'], // Add status
              'distance': distance,
            });
          }
        }

        if (_sourceLocation != null) {
          availableCabs.sort((a, b) {
            if (a['distance'] == null || b['distance'] == null) return 0;
            return (a['distance'] as double)
                .compareTo(b['distance'] as double);
          });
        }

        setState(() {
          _cabLocations = availableCabs;
          _isLoadingCabs = false;
        });
      } else {
        setState(() {
          _errorMessage =
              'Failed to load cab locations: ${response.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error fetching cab locations: $e';
      });
    }
  }

  Future<void> _findCab() async {
    if (_sourceLocation == null || _destinationLocation == null) {
      setState(() {
        _errorMessage = 'Please select both source and destination on map.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _assignedCab = null;
      _errorMessage = null;
    });

    try {
      final response = await http.post(
        Uri.parse('${AppConstants.baseUrl}/api/find_cab'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'start_latitude': _sourceLocation!.latitude,
          'start_longitude': _sourceLocation!.longitude,
          'end_latitude': _destinationLocation!.latitude,
          'end_longitude': _destinationLocation!.longitude,
        }),
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = json.decode(response.body);
        if (responseData.containsKey('available_cabs') && responseData['available_cabs'] is List) {

          setState(() {
            _foundCabDetails = responseData; // Store the entire response, including all available cabs
            print('Assigned Cab Details: $_assignedCab'); // Debug print for assigned cab
           _isLoading = false;
          });
          _showCabSelectionDialog(); // Show a new dialog for cab selection
        } else {
          setState(() {
            _errorMessage = 'Cab ID not found in response.';
            print('Assigned Cab Details: $_assignedCab'); // Debug print for assigned cab
           _isLoading = false;
          });
        }
      } else {
        final errorData = json.decode(response.body);
        setState(() {
          _errorMessage = errorData['error'] ?? 'Failed to find a cab';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error connecting to server: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _bookRide(Map<String, dynamic> selectedCabOption) async {
    if (_sourceLocation == null || _destinationLocation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Source or destination not set.')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http.post(
        Uri.parse('${AppConstants.baseUrl}/api/book_cab'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'cab_id': selectedCabOption['cab']['cab_id'],
          'start_latitude': _sourceLocation!.latitude,
          'start_longitude': _sourceLocation!.longitude,
          'end_latitude': _destinationLocation!.latitude,
          'end_longitude': _destinationLocation!.longitude,
          'is_shared': selectedCabOption['is_shared'],
        }),
      );
      print('Booking Request Body: ${json.encode({
         'cab_id': selectedCabOption['cab']['cab_id'],
         'start_latitude': _sourceLocation!.latitude,
         'start_longitude': _sourceLocation!.longitude,
         'end_latitude': _destinationLocation!.latitude,
         'end_longitude': _destinationLocation!.longitude,
         'is_shared': selectedCabOption['is_shared'],
       })}');

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = json.decode(response.body);
        setState(() {
          _assignedCab = responseData; // Store the booked ride details
          print('Assigned Cab Details: $_assignedCab'); // Debug print for assigned cab
          _isLoading = false;
          _foundCabDetails = null; // Clear found cab details after booking
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ride booked successfully!')), 
        );
      } else {
        final errorData = json.decode(response.body);
        setState(() {
          _errorMessage = errorData['error'] ?? 'Failed to book cab';
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to book ride: ${_errorMessage}')), 
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error connecting to server: $e';
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error booking ride: $e')),
      );
    }
  }

  Future<void> _showCabSelectionDialog() async {
    if (_foundCabDetails == null || !_foundCabDetails!.containsKey('available_cabs')) return;

    List<dynamic> availableCabs = _foundCabDetails!['available_cabs'];

    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Select Your Cab'),
          content: SingleChildScrollView(
            child: ListBody(
              children: availableCabs.map((option) {
                final cab = option['cab'];
                final distance = option['pickup_distance'] ?? 0.0;
                final isShared = option['is_shared'] ?? false;
                final status = option['status'] ?? 'Unknown';

                final totalDistance = option['total_distance'] ?? 0.0;
                final fare = option['fare'] ?? 0.0;

                return RideCard(
                  cabName: cab['name'] ?? 'Unknown Cab',
                  cabStatus: status,
                  distanceToCab: _formatDistance(distance),
                  distanceToDestination: _formatDistance(totalDistance), // Assuming totalDistance from backend is source to destination
                  startCoords: '${_sourceLocation!.latitude.toStringAsFixed(2)}, ${_sourceLocation!.longitude.toStringAsFixed(2)}',
                  endCoords: '${_destinationLocation!.latitude.toStringAsFixed(2)}, ${_destinationLocation!.longitude.toStringAsFixed(2)}',
                  isShared: isShared,
                  fare: fare.toStringAsFixed(2),
                  totalDistance: _formatDistance(totalDistance),
                  onTap: () {
                    Navigator.of(context).pop(); // Close the selection dialog
                    _bookRide(option); // Book the selected cab
                  },
                );
              }).toList().cast<Widget>(),
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                setState(() {
                  _foundCabDetails = null;
                  print('Assigned Cab Details: $_assignedCab'); // Debug print for assigned cab
           _isLoading = false;
                });
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _completeRide(int cabId) async {
    if (_assignedCab == null) return;
    setState(() => _isLoading = true);

    try {
      final url = '${AppConstants.baseUrl}/api/complete_ride/$cabId';
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        setState(() {
          _assignedCab = null;
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ride completed successfully!')),
        );
      } else {
        setState(() {
          _errorMessage = 'Failed to complete ride';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error connecting to server: $e';
        _isLoading = false;
      });
    }
  }

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
          '${AppConstants.osrmBaseUrl}/route/v1/driving/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?overview=full&geometries=geojson'));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0]['geometry']['coordinates'] as List;
          setState(() {
            _routePoints =
                route.map((coord) => LatLng(coord[1], coord[0])).toList();
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
          _errorMessage =
              'Failed to calculate route: ${response.statusCode}';
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
                    _sourceController.text =
                        '${latlng.latitude}, ${latlng.longitude}';
                    _destinationLocation = null;
                    _destinationController.clear();
                    _routePoints.clear();
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
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.app',
              ),
              if (_routePoints.isNotEmpty)
                flutter_map.PolylineLayer(
                  polylines: [
                    flutter_map.Polyline(
                      points: _routePoints,
                      color: Colors.blue,
                      strokeWidth: 5.0,
                    ),
                  ],
                ),
              const CurrentLocationLayer(alignPositionOnUpdate: AlignOnUpdate.always),
              if (_sourceLocation != null)
                flutter_map.MarkerLayer(
                  markers: [
                    flutter_map.Marker(
                      point: _sourceLocation!,
                      width: 80,
                      height: 80,
                      child:
                          const Icon(Icons.location_on, color: Colors.green, size: 40),
                    ),
                  ],
                ),
              if (_destinationLocation != null)
                flutter_map.MarkerLayer(
                  markers: [
                    flutter_map.Marker(
                      point: _destinationLocation!,
                      width: 80,
                      height: 80,
                      child:
                          const Icon(Icons.location_on, color: Colors.red, size: 40),
                    ),
                  ],
                ),
              flutter_map.MarkerLayer(
                markers: _cabLocations.map((cab) {
                  return flutter_map.Marker(
                    point: cab['position'],
                    width: 80,
                    height: 80,
                    child: Icon(
                      Icons.car_rental,
                      color: cab['in_use'] ? Colors.red : Colors.green,
                      size: 30,
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
          if (_isLoading)
            const Center(
              child: SpinKitChasingDots(color: Colors.blue, size: 50.0),
            ),
          if (_errorMessage != null)
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(10),
                color: Colors.red,
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Column(
              children: [
                TextFormField(
                  controller: _sourceController,
                  decoration: InputDecoration(
                    hintText: 'Source Location',
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.my_location),
                      onPressed: () {
                        if (_currentLocation != null) {
                          setState(() {
                            _sourceLocation = _currentLocation;
                            _sourceController.text = '${_currentLocation!.latitude}, ${_currentLocation!.longitude}';
                            _destinationLocation = null;
                            _destinationController.clear();
                            _routePoints.clear();
                          });
                        }
                      },
                    ),
                  ),
                  readOnly: true,
                  onTap: () async {
                    LatLng? latLng = await showLocationPickerDialog(context);
                    if (latLng != null) {
                      setState(() {
                        _sourceLocation = latLng;
                        _sourceController.text = '${latLng.latitude}, ${latLng.longitude}';
                        _destinationLocation = null;
                        _destinationController.clear();
                        _routePoints.clear();
                        _animatedMapController.animateTo(
                            dest: latLng,
                            zoom: _currentZoom,
                            duration: const Duration(milliseconds: 500));
                      });
                    }
                  },
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _destinationController,
                  decoration: InputDecoration(
                    hintText: 'Destination Location',
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  readOnly: true,
                  onTap: () async {
                    LatLng? latLng = await showLocationPickerDialog(context);
                    if (latLng != null) {
                      setState(() {
                        _destinationLocation = latLng;
                        _destinationController.text = '${latLng.latitude}, ${latLng.longitude}';
                        _animatedMapController.animateTo(
                            dest: latLng,
                            zoom: _currentZoom,
                            duration: const Duration(milliseconds: 500));
                      });
                      if (_sourceLocation != null && _destinationLocation != null) {
                        _calculateRoute();
                      }
                    }
                  },
                ),
                const SizedBox(height: 10),
                ElevatedButton(
                  onPressed: _findCab,
                  child: const Text('Find Cab'),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Column(
              children: [
                if (_assignedCab != null && _isRideCardVisible)
                  RideCard(
                    cabName: _assignedCab!['cab']['name'] ?? 'Unknown Cab',
                    cabStatus: _assignedCab!['status'] ?? 'Unknown Status',
                    distanceToCab:
                        _formatDistance(_assignedCab!['distance'] ?? 0.0),
                    distanceToDestination:
                        _formatDistance(_assignedCab!['source_destination_distance'] ?? 0.0),
                    startCoords:
                        '${_assignedCab!['start_latitude']?.toStringAsFixed(2)}, ${_assignedCab!['start_longitude']?.toStringAsFixed(2)}',
                    endCoords:
                        '${_assignedCab!['end_latitude']?.toStringAsFixed(2)}, ${_assignedCab!['end_longitude']?.toStringAsFixed(2)}',
                    isShared: _assignedCab!['is_shared'] ?? false,
                    cabId: _assignedCab!['cab_id'],
                    onCompleteRide: (id) => _completeRide(id),
                    fare: _assignedCab!['fare']?.toStringAsFixed(2) ?? 'N/A',
                    totalDistance: _formatDistance(_assignedCab!['total_distance'] ?? 0.0),
                  ),
              ],
            ),
          ),
          Positioned(
            bottom: 10,
            right: 10,
            child: FloatingActionButton(
              onPressed: () {
                setState(() {
                  _isRideCardVisible = !_isRideCardVisible;
                });
              },
              child: Icon(
                _isRideCardVisible ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ✅ Simple coordinate picker dialog
Future<LatLng?> showLocationPickerDialog(BuildContext context) async {
  final TextEditingController latController = TextEditingController();
  final TextEditingController lonController = TextEditingController();

  return showDialog<LatLng>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text("Enter Coordinates"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: latController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Latitude"),
            ),
            TextField(
              controller: lonController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Longitude"),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () {
              double? lat = double.tryParse(latController.text);
              double? lon = double.tryParse(lonController.text);
              if (lat != null && lon != null) {
                Navigator.pop(context, LatLng(lat, lon));
              }
            },
            child: const Text("OK"),
          ),
        ],
      );
    },
  );
}
