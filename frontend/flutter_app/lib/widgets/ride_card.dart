import 'package:flutter/material.dart';

class RideCard extends StatelessWidget {
  final String cabName;
  final double? fare;
  final bool isShared;
  final String? primaryRequestId;
  final String? timestamp;
  final String? cabId;
  final ValueChanged<String>? onCompleteRide;
  final VoidCallback? onTap;

  const RideCard({
    Key? key,
    required this.cabName,
    this.fare,
    this.isShared = false,
    this.primaryRequestId,
    this.timestamp,
    this.cabId,
    this.onCompleteRide,
    this.onTap,
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
                  _buildStatusChip(context),
                ],
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.1)), // Add a divider for visual separation
              const SizedBox(height: 12),
              if (fare != null) ...[
                const SizedBox(height: 8),
                _buildInfoRow(context, Icons.money, 'Fare:', '₹${fare!.toStringAsFixed(2)}'),
              ],
              if (timestamp != null) ...[
                const SizedBox(height: 8),
                _buildInfoRow(context, Icons.access_time, 'Time:', timestamp!), 
              ],
              if (onCompleteRide != null && cabId != null) ...[
                const SizedBox(height: 16),
                Center(
                  child: ElevatedButton.icon(
                        onPressed: () => onCompleteRide!(cabId as String),
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

  Widget _buildStatusChip(BuildContext context) {
    Color chipColor;
    IconData chipIcon;
    String statusText;

    if (isShared) {
      chipColor = Colors.blueAccent;
      chipIcon = Icons.people;
      statusText = 'Shared Ride';
    } else {
      chipColor = Colors.green;
      chipIcon = Icons.check_circle;
      statusText = 'Available';
    }

    return Chip(
      avatar: Icon(chipIcon, color: Colors.white, size: 18),
      label: Text(
        statusText,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
      ),
      backgroundColor: chipColor,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );
  }

  Widget _buildInfoRow(
      BuildContext context, IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7), size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '$label ',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                ),
          ),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              ),
        ),
      ],
    );
  }
}