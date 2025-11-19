import 'package:flutter/material.dart';

class RideCard extends StatelessWidget {
  final String cabName;
  final String cabStatus;
  final String? distanceToCab;
  final String? distanceToDestination;
  final String startCoords;
  final String endCoords;
  final bool isShared;
  final String fare;
  final String? timestamp;
  final int? cabId;
  final ValueChanged<int>? onCompleteRide;
  final VoidCallback? onTap;
  final ValueChanged<int>? onBookNow;
  final String? rideStatus;

  const RideCard({
    Key? key,
    required this.cabName,
    required this.cabStatus,
    this.distanceToCab,
    this.distanceToDestination,
    required this.startCoords,
    required this.endCoords,
    required this.isShared,
    required this.fare,
    this.timestamp,
    this.cabId,
    this.onCompleteRide,
    this.onTap,
    this.onBookNow,
    this.rideStatus,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap, // Make the entire card tappable
      child: Card(
        elevation: 6, // Slightly higher elevation for a more prominent look
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), // Add margin for better spacing
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    cabName,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ), // Use theme for better consistency
                  ),
                  if (rideStatus != null) _buildStatusChip(context, rideStatus!) else _buildStatusChip(context, cabStatus),
                ],
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.1)), // Add a divider for visual separation
              const SizedBox(height: 12),
              _buildInfoRow(context, Icons.location_on, 'From:', startCoords),
              const SizedBox(height: 8),
              _buildInfoRow(context, Icons.location_searching, 'To:', endCoords),
              const SizedBox(height: 8),
              if (distanceToCab != null) ...[
                _buildInfoRow(context, Icons.straighten, 'Distance to Cab:', distanceToCab!),
                const SizedBox(height: 8),
              ],
              if (distanceToDestination != null) ...[
                _buildInfoRow(context, Icons.alt_route, 'Distance to Destination:', distanceToDestination!),
                const SizedBox(height: 8),
              ],
              if (timestamp != null) ...[
                const SizedBox(height: 8),
                _buildInfoRow(context, Icons.access_time, 'Time:', timestamp!),
              ],
              if (onBookNow != null && cabId != null) ...[

                const SizedBox(height: 16),
                Center(
                  child: ElevatedButton.icon(
                    onPressed: () => onBookNow!(cabId!),
                    icon: const Icon(Icons.book_online, color: Colors.white),
                    label: Text(
                      'Book Now',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Colors.white),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary, // Use theme color
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      elevation: 4,
                    ),
                  ),
                ),
              ],
              if (onCompleteRide != null && cabId != null) ...[
                const SizedBox(height: 16),
                Center(
                  child: ElevatedButton.icon(
                        onPressed: () => onCompleteRide!(cabId!),
                    icon: const Icon(Icons.check_circle_outline, color: Colors.white),
                    label: Text(
                      'Complete Ride',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Colors.white),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.secondary, // Use theme color
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      elevation: 4,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip(BuildContext context, String status) {
    Color chipColor;
    IconData chipIcon;
    String statusText;

    switch (status) {
      case 'Shared':
        chipColor = Theme.of(context).colorScheme.tertiary;
        chipIcon = Icons.people;
        statusText = 'Shared';
        break;
      case 'Busy':
        chipColor = Theme.of(context).colorScheme.error;
        chipIcon = Icons.directions_car;
        statusText = 'Busy';
        break;
      case 'Available':
        chipColor = Theme.of(context).colorScheme.secondary;
        chipIcon = Icons.check_circle;
        statusText = 'Available';
        break;
      case 'Completed':
        chipColor = Colors.green;
        chipIcon = Icons.check_circle_outline;
        statusText = 'Completed';
        break;
      case 'Cancelled':
        chipColor = Colors.redAccent;
        chipIcon = Icons.cancel_outlined;
        statusText = 'Cancelled';
        break;
      default:
        chipColor = Theme.of(context).colorScheme.onSurface.withOpacity(0.6);
        chipIcon = Icons.info_outline;
        statusText = status;
        break;
    }

    return Chip(
      avatar: Icon(chipIcon, color: Theme.of(context).colorScheme.onPrimary, size: 16),
      label: Text(
        statusText,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onPrimary, fontWeight: FontWeight.bold),
      ),
      backgroundColor: chipColor,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), // Slightly more vertical padding
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), // More rounded corners
    );
  }

  Widget _buildInfoRow(BuildContext context, IconData icon, String title, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurface),
                overflow: TextOverflow.ellipsis, // Handle long text
              ),
            ],
          ),
        ),
      ],
    );
  }
}