class Ride {
  final String cabName;
  final bool isShared;
  final String startCoords;
  final String endCoords;
  final double fare;
  final DateTime timestamp;
  final String rideStatus;

  Ride({
    required this.cabName,
    required this.isShared,
    required this.startCoords,
    required this.endCoords,
    required this.fare,
    required this.timestamp,
    required this.rideStatus,
  });

  factory Ride.fromJson(Map<String, dynamic> json) {
    return Ride(
      cabName: json['cab_name'],
      isShared: json['shared'],
      startCoords: '(${json['start_x']}, ${json['start_y']})',
      endCoords: '(${json['end_x']}, ${json['end_y']})',
      fare: (json['fare'] as num?)?.toDouble() ?? 0.0,
      timestamp: DateTime.parse(json['timestamp']),
      rideStatus: 'Completed', // Assuming 'Completed' for now
    );
  }
}