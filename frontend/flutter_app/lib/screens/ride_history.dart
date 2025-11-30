import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import '../services/auth_service.dart';
import '../widgets/ride_card.dart';
import '../utils/constants.dart';

class RideHistoryScreen extends StatefulWidget {
  const RideHistoryScreen({Key? key}) : super(key: key);

  @override
  _RideHistoryScreenState createState() => _RideHistoryScreenState();
}

class _RideHistoryScreenState extends State<RideHistoryScreen> {
  List<dynamic> _rides = [];
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchRideHistory();
  }

  Future<void> _fetchRideHistory() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final String? token = await AuthService.getAuthToken();

      if (token == null) {
        setState(() {
          _errorMessage = 'Authentication token not found. Please log in.';
          _isLoading = false;
        });
        return;
      }

      final response = await http.get(
        Uri.parse('${AppConstants.baseUrl}/api/ride_history'),
        headers: {
          'x-access-token': token,
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        setState(() {
          _rides = json.decode(response.body);
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = 'Failed to fetch ride history (Status ${response.statusCode})';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ride History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchRideHistory,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.red),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: _fetchRideHistory,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _rides.isEmpty
                  ? const Center(child: Text('No ride history available'))
                  : RefreshIndicator(
                      onRefresh: _fetchRideHistory,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _rides.length,
                        itemBuilder: (context, index) {
                          final ride = _rides[index];
                          final timestamp = DateTime.parse(ride['timestamp']);
                          final formattedDate =
                              DateFormat('MMM dd, yyyy - HH:mm').format(timestamp);

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: RideCard(
                              cabName: ride['cab_name'],
                              cabStatus: ride['shared'] ? 'Shared Ride' : 'Single Ride',
                              startCoords:
                                  '(${ride['start_x']}, ${ride['start_y']})',
                              endCoords:
                                  '(${ride['end_x']}, ${ride['end_y']})',
                              isShared: ride['shared'],
                              fare: '₹${(ride['fare'] ?? 0).toString()}',
                              timestamp: formattedDate,
                              rideStatus: 'Completed',
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
