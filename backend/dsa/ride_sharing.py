import math
from .graph import RouteOptimizer
from .db_utils import DatabaseUtils

class RideSharing:
    def __init__(self, db_path='../database.db'):
        self.db_utils = DatabaseUtils(db_path)
        self.route_optimizer = RouteOptimizer()

    def _calculate_distance(self, lat1, lon1, lat2, lon2):
        # Haversine formula to calculate distance between two lat/lon points
        R = 6371  # Radius of Earth in kilometers

        lat1_rad = math.radians(lat1)
        lon1_rad = math.radians(lon1)
        lat2_rad = math.radians(lat2)
        lon2_rad = math.radians(lon2)

        dlon = lon2_rad - lon1_rad
        dlat = lat2_rad - lat1_rad

        a = math.sin(dlat / 2)**2 + math.cos(lat1_rad) * math.cos(lat2_rad) * math.sin(dlon / 2)**2
        c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))

        distance = R * c
        return distance

    def find_shared_ride(self, new_request_id):
        new_request = self.db_utils.get_ride_request_by_id(new_request_id)
        if not new_request:
            print(f"New ride request with ID {new_request_id} not found.")
            return None

        new_start_lat, new_start_lon = new_request[2], new_request[3]
        new_end_lat, new_end_lon = new_request[4], new_request[5]

        # For simplicity, let's assume we are looking for existing unshared ride requests
        # In a real scenario, we would query for active, unshared rides.
        # For now, let's just get all ride requests and filter.
        all_ride_requests = self.db_utils.get_all_ride_requests() # Assuming this method exists or will be created

        potential_shared_rides = []

        for existing_request in all_ride_requests:
            if existing_request[0] == new_request_id or existing_request[6]: # Skip self and already shared rides
                continue

            existing_start_lat, existing_start_lon = existing_request[2], existing_request[3]
            existing_end_lat, existing_end_lon = existing_request[4], existing_request[5]

            # Calculate paths for both rides
            path_new = self.route_optimizer.find_shortest_path(
                (new_start_lat, new_start_lon), (new_end_lat, new_end_lon))
            path_existing = self.route_optimizer.find_shortest_path(
                (existing_start_lat, existing_start_lon), (existing_end_lat, existing_end_lon))

            if path_new and path_existing:
                # Check for path overlap. A simple check could be if the new ride's start and end points
                # are "on" or "near" the existing ride's path.
                # This is a simplified check and would need more sophisticated logic for real-world TSP.

                # For demonstration, let's check if new ride's start and end are within the bounding box
                # of the existing ride's path.
                min_lat_existing = min(p[0] for p in path_existing)
                max_lat_existing = max(p[0] for p in path_existing)
                min_lon_existing = min(p[1] for p in path_existing)
                max_lon_existing = max(p[1] for p in path_existing)

                new_start_within_existing_bounds = (
                    min_lat_existing <= new_start_lat <= max_lat_existing and
                    min_lon_existing <= new_start_lon <= max_lon_existing
                )
                new_end_within_existing_bounds = (
                    min_lat_existing <= new_end_lat <= max_lat_existing and
                    min_lon_existing <= new_end_lon <= max_lon_existing
                )

                # A more robust check would involve actual path intersection or proximity
                # For now, if both start and end are within bounds, consider it a potential share.
                if new_start_within_existing_bounds and new_end_within_existing_bounds:
                    potential_shared_rides.append(existing_request)

        return potential_shared_rides

    def calculate_fare_division(self, primary_ride_distance, secondary_ride_distance, total_fare):
        """
        Calculate fare division between primary and secondary riders.
        A simple approach: fare is proportional to the distance traveled by each rider.
        """
        total_shared_distance = primary_ride_distance + secondary_ride_distance
        if total_shared_distance == 0:
            return 0, 0 # Avoid division by zero

        primary_fare = (primary_ride_distance / total_shared_distance) * total_fare
        secondary_fare = (secondary_ride_distance / total_shared_distance) * total_fare

        return primary_fare, secondary_fare

    def confirm_shared_ride(self, primary_request_id, secondary_request_id, fare_division):
        """
        Confirms a shared ride and updates the database.
        """
        shared_ride_id = self.db_utils.add_shared_ride(primary_request_id, secondary_request_id, fare_division)
        if shared_ride_id:
            # Update the ride requests to mark them as shared
            self.db_utils.update_ride_request_shared_status(primary_request_id, True)
            self.db_utils.update_ride_request_shared_status(secondary_request_id, True)
            # Add participants to the shared ride
            primary_request = self.db_utils.get_ride_request_by_id(primary_request_id)
            secondary_request = self.db_utils.get_ride_request_by_id(secondary_request_id)
            if primary_request and secondary_request:
                self.db_utils.add_ride_participant(shared_ride_id, primary_request[1]) # user_id is at index 1
                self.db_utils.add_ride_participant(shared_ride_id, secondary_request[1])
            return shared_ride_id
        return None