import 'package:flutter/material.dart';

class RideCard extends StatelessWidget {
  final String cabName;
  final String cabStatus;
  final String distanceToCab;
  final String distanceToDestination;
  final String startCoords;
  final String endCoords;
  final bool isShared;
  final String? timestamp;
  final int? cabId;
  final String? fare;
  final String? totalDistance;
  final VoidCallback? onBookNow;
  final ValueChanged<int>? onCompleteRide;

  const RideCard({
    Key? key,
    required this.cabName,
    required this.cabStatus,
    required this.distanceToCab,
    required this.distanceToDestination,
    required this.startCoords,
    required this.endCoords,
    required this.isShared,
    this.timestamp,
    this.cabId,
    this.fare,
    this.totalDistance,
    this.onBookNow,
    this.onCompleteRide,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final ColorScheme color = Theme.of(context).colorScheme;

    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  cabName,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: color.primary,
                      ),
                ),
                _buildStatusChip(context),
              ],
            ),

            const SizedBox(height: 8),
            Divider(color: color.onSurface.withOpacity(0.1)),

            const SizedBox(height: 8),
            _buildInfoRow(context, Icons.location_on, 'Pickup:', startCoords),
            const SizedBox(height: 6),
            _buildInfoRow(context, Icons.flag, 'Drop:', endCoords),
            const SizedBox(height: 6),
            _buildInfoRow(context, Icons.local_taxi, 'Cab Distance:', distanceToCab),
            const SizedBox(height: 6),
            _buildInfoRow(context, Icons.alt_route, 'Ride Distance:', distanceToDestination),

            if (fare != null) ...[
              const SizedBox(height: 8),
              _buildInfoRow(context, Icons.currency_rupee, 'Fare:', '₹$fare'),
            ],

            const SizedBox(height: 12),

            // ✅ Book Now Button
            Center(
              child: ElevatedButton.icon(
                onPressed: onBookNow,
                icon: const Icon(Icons.local_taxi_rounded, color: Colors.white),
                label: const Text('Book Now',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade600,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
            ),

            if (onCompleteRide != null && cabId != null) ...[
              const SizedBox(height: 8),
              Center(
                child: OutlinedButton.icon(
                  onPressed: () => onCompleteRide!(cabId!),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Complete Ride'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(BuildContext context) {
    Color chipColor;
    IconData chipIcon;
    String statusText;

    if (isShared) {
      chipColor = Colors.purpleAccent;
      chipIcon = Icons.people;
      statusText = 'Shared';
    } else if (cabStatus == 'Busy') {
      chipColor = Colors.redAccent;
      chipIcon = Icons.directions_car_filled;
      statusText = 'Busy';
    } else if (cabStatus == 'Available') {
      chipColor = Colors.green;
      chipIcon = Icons.check_circle_outline;
      statusText = 'Available';
    } else {
      chipColor = Colors.grey;
      chipIcon = Icons.info_outline;
      statusText = cabStatus;
    }

    return Chip(
      avatar: Icon(chipIcon, color: Colors.white, size: 18),
      label: Text(statusText,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      backgroundColor: chipColor,
    );
  }

  Widget _buildInfoRow(BuildContext context, IconData icon, String title, String value) {
    final ColorScheme color = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: color.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: color.onSurface.withOpacity(0.7),
                      fontSize: 13)),
              const SizedBox(height: 2),
              Text(value,
                  style: TextStyle(color: color.onSurface, fontSize: 14),
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );
  }
}
