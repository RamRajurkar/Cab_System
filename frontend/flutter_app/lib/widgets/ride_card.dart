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
  final ValueChanged<int>? onCompleteRide;
  final VoidCallback? onTap;
  final String? fare;
  final String? totalDistance;
  final ValueChanged<int>? onBookNow;

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
    this.onCompleteRide,
    this.onTap,
    this.fare,
    this.totalDistance,
    this.onBookNow,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    cabName,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                  ),
                  _buildStatusChip(context),
                ],
              ),
              const SizedBox(height: 16),
              Divider(height: 1, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.15)),
              const SizedBox(height: 16),
              _buildInfoRow(context, Icons.location_on, 'From:', startCoords),
              const SizedBox(height: 10),
              _buildInfoRow(context, Icons.location_searching, 'To:', endCoords),
              const SizedBox(height: 10),
              _buildInfoRow(context, Icons.straighten, 'Distance to Cab:', distanceToCab),
              const SizedBox(height: 10),
              _buildInfoRow(context, Icons.alt_route, 'Distance to Destination:', distanceToDestination),
              if (totalDistance != null) ...[
                const SizedBox(height: 10),
                _buildInfoRow(context, Icons.map, 'Total Distance:', totalDistance!),
              ],
              if (fare != null) ...[
                const SizedBox(height: 10),
                _buildInfoRow(context, Icons.attach_money, 'Fare:', fare!),
              ],
              if (timestamp != null) ...[
                const SizedBox(height: 10),
                _buildInfoRow(context, Icons.access_time, 'Time:', timestamp!),
              ],
              if (onBookNow != null && cabId != null) ...[
                const SizedBox(height: 20),
                Center(
                  child: ElevatedButton.icon(
                    onPressed: () => onBookNow!(cabId!),
                    icon: const Icon(Icons.book_online, color: Colors.white),
                    label: Text(
                      'Book Now',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                      elevation: 5,
                    ),
                  ),
                ),
              ],
              if (onCompleteRide != null && cabId != null) ...[
                const SizedBox(height: 20),
                Center(
                  child: ElevatedButton.icon(
                    onPressed: () => onCompleteRide!(cabId!),
                    icon: const Icon(Icons.check_circle_outline, color: Colors.white),
                    label: Text(
                      'Complete Ride',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.secondary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                      elevation: 5,
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

  Widget _buildStatusChip(BuildContext context) {
    Color chipColor;
    IconData chipIcon;
    String statusText;

    if (isShared) {
      chipColor = Theme.of(context).colorScheme.tertiary;
      chipIcon = Icons.people;
      statusText = 'Shared - $cabStatus';
    } else if (cabStatus == 'Busy') {
      chipColor = Theme.of(context).colorScheme.error;
      chipIcon = Icons.directions_car;
      statusText = 'Busy';
    } else if (cabStatus == 'Available') {
      chipColor = Theme.of(context).colorScheme.secondary;
      chipIcon = Icons.check_circle;
      statusText = 'Available';
    } else {
      chipColor = Theme.of(context).colorScheme.onSurface.withOpacity(0.6); // Default color for unknown status
      chipIcon = Icons.info_outline;
      statusText = cabStatus; // Display original status if unknown
    }

    return Chip(
      avatar: Icon(chipIcon, color: Theme.of(context).colorScheme.onPrimary, size: 18),
      label: Text(
        statusText,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onPrimary, fontWeight: FontWeight.bold),
      ),
      backgroundColor: chipColor,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
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