class MinHeap:
    """
    Min Heap implementation for finding the nearest cab.
    The heap is organized based on the distance between a cab and a user.
    """
    def __init__(self):
        self.heap = []
        self.size = 0

    def parent(self, i):
        """
        Get the parent index of a node.
        """
        return (i - 1) // 2

    def left_child(self, i):
        """
        Get the left child index of a node.
        """
        return 2 * i + 1

    def right_child(self, i):
        """
        Get the right child index of a node.
        """
        return 2 * i + 2

    def swap(self, i, j):
        """
        Swap two nodes in the heap.
        """
        self.heap[i], self.heap[j] = self.heap[j], self.heap[i]

    def heapify_up(self, i):
        """
        Heapify up to maintain the min heap property.
        """
        while i > 0 and self.heap[self.parent(i)]['distance'] > self.heap[i]['distance']:
            self.swap(i, self.parent(i))
            i = self.parent(i)

    def heapify_down(self, i):
        """
        Heapify down to maintain the min heap property.
        """
        min_index = i
        left = self.left_child(i)
        right = self.right_child(i)

        if left < self.size and self.heap[left]['distance'] < self.heap[min_index]['distance']:
            min_index = left

        if right < self.size and self.heap[right]['distance'] < self.heap[min_index]['distance']:
            min_index = right

        if i != min_index:
            self.swap(i, min_index)
            self.heapify_down(min_index)

    def insert(self, cab, distance):
        """
        Insert a cab with its distance into the heap.
        """
        cab_with_distance = {'cab': cab, 'distance': distance}
        self.heap.append(cab_with_distance)
        self.size += 1
        self.heapify_up(self.size - 1)

    def extract_min(self):
        """
        Extract the cab with the minimum distance.
        """
        if self.size == 0:
            return None

        min_cab = self.heap[0]
        self.heap[0] = self.heap[self.size - 1]
        self.size -= 1
        self.heap.pop()
        
        if self.size > 0:
            self.heapify_down(0)
            
        return min_cab

    def peek(self):
        """
        Get the cab with the minimum distance without removing it.
        """
        if self.size == 0:
            return None
        return self.heap[0]

    def is_empty(self):
        """
        Check if the heap is empty.
        """
        return self.size == 0


from dsa.db_utils import DatabaseUtils
from dsa.graph import RouteOptimizer
from dsa.utils import calculate_distance

class CabFinder:
    """
    Utility class to find the nearest available cab using a Min Heap.
    """


    @staticmethod
    def find_nearest_cab(cabs, user_x, user_y, num_cabs=3):
        """
        Find the nearest available cabs using a Min Heap.
        
        Args:
            cabs: List of cab dictionaries with id, name, latitude, longitude, and status.
            user_x: User's x-coordinate.
            user_y: User's y-coordinate.
            num_cabs: The number of nearest cabs to return.
            
        Returns:
            A list of tuples, each containing (cab, distance), for the nearest available cabs.
        """
        min_heap = MinHeap()
        
        for cab in cabs:
            if cab['status'] == 'Available':
                distance = calculate_distance(user_x, user_y, cab['latitude'], cab['longitude'])
                min_heap.insert(cab, distance)
        
        nearest_cabs = []
        for _ in range(num_cabs):
            if not min_heap.is_empty():
                nearest_cab_info = min_heap.extract_min()
                nearest_cabs.append((nearest_cab_info['cab'], nearest_cab_info['distance']))
            else:
                break
        
        return nearest_cabs

    @staticmethod
    def find_shared_cab(cabs, user_start_latitude, user_start_longitude, user_end_latitude, user_end_longitude, max_detour_factor=1.5):
        """
        Find a cab that can be shared based on route overlap and minimal detour.
        
        Args:
            cabs: List of cab dictionaries with id, name, latitude, longitude, and status.
            user_start_latitude: User's starting latitude.
            user_start_longitude: User's starting longitude.
            user_end_latitude: User's ending latitude.
            user_end_longitude: User's ending longitude.
            max_detour_factor: Maximum allowed detour factor for sharing.
            
        Returns:
            A cab that can be shared and the calculated pickup distance, or None and infinity.
        """
        db = DatabaseUtils(db_path='database.db')
        active_rides = db.get_active_rides()
        db.disconnect()

        best_shared_cab = None
        min_detour_distance = float('inf')

        # Calculate the direct distance for the user's trip
        user_direct_distance = calculate_distance(
            user_start_latitude, user_start_longitude, user_end_latitude, user_end_longitude
        )

        for cab in cabs:
            cab_id = cab['cab_id']
            cab_latitude = cab['latitude']
            cab_longitude = cab['longitude']
            cab_status = cab['status']

            # Consider available cabs for direct sharing if they are close enough to pick up
            if cab_status == 'Available':
                pickup_distance = calculate_distance(
                    user_start_latitude, user_start_longitude, cab_latitude, cab_longitude
                )
                # For available cabs, the detour is just the pickup distance + user's direct trip
                # We want to find the closest available cab that can take the user.
                # This is essentially finding the nearest cab, but we're doing it within the shared cab logic
                # to allow for a single return structure.
                total_distance_for_user = pickup_distance + user_direct_distance
                if total_distance_for_user < min_detour_distance:
                    best_shared_cab = cab
                    min_detour_distance = total_distance_for_user

            # Consider busy/shared cabs for ride-sharing
            elif cab_status in ['Busy', 'Shared']:
                # Find the active ride for this cab
                current_ride = next((r for r in active_rides if r['cab_id'] == cab_id), None)
                if current_ride:
                    # Current passenger's route points
                    current_passenger_start = (current_ride['start_latitude'], current_ride['start_longitude'])
                    current_passenger_end = (current_ride['end_latitude'], current_ride['end_longitude'])

                    # Cab's current location
                    cab_current_location = (cab_latitude, cab_longitude)

                    # Possible waypoints for the combined trip:
                    # 1. Cab's current location
                    # 2. Current passenger's drop-off
                    # 3. New user's pickup
                    # 4. New user's drop-off

                    # We need to find an optimal sequence of these points.
                    # A simplified TSP approach: consider permutations of intermediate stops.

                    # Original route for current passenger (from cab's current location to drop-off)
                    # This is a simplification; ideally, we'd know the cab's exact next stop.
                    original_cab_to_current_dropoff_dist, _ = RouteOptimizer.find_shortest_path(
                        cab_current_location[0], cab_current_location[1],
                        current_passenger_end[0], current_passenger_end[1]
                    )

                    # Proposed route: Cab -> User Pickup -> Current Passenger Dropoff -> User Dropoff
                    # Or: Cab -> Current Passenger Dropoff -> User Pickup -> User Dropoff
                    # This is a heuristic, a full TSP solver would be more robust.

                    # Option 1: Cab -> User Pickup -> Current Passenger Dropoff -> User Dropoff
                    path1_dist, _ = RouteOptimizer.find_shortest_path(
                        cab_current_location[0], cab_current_location[1],
                        user_start_latitude, user_start_longitude
                    )
                    path1_dist += calculate_distance(
                        user_start_latitude, user_start_longitude,
                        current_passenger_end[0], current_passenger_end[1]
                    )
                    path1_dist += calculate_distance(
                        current_passenger_end[0], current_passenger_end[1],
                        user_end_latitude, user_end_longitude
                    )

                    # Option 2: Cab -> Current Passenger Dropoff -> User Pickup -> User Dropoff
                    path2_dist, _ = RouteOptimizer.find_shortest_path(
                        cab_current_location[0], cab_current_location[1],
                        current_passenger_end[0], current_passenger_end[1]
                    )
                    path2_dist += calculate_distance(
                        current_passenger_end[0], current_passenger_end[1],
                        user_start_latitude, user_start_longitude
                    )
                    path2_dist += calculate_distance(
                        user_start_latitude, user_start_longitude,
                        user_end_latitude, user_end_longitude
                    )

                    # Choose the shorter of the two options
                    combined_route_distance = min(path1_dist, path2_dist)

                    # Check if the combined route is within the detour factor for the current passenger
                    # And if the new user's pickup is reasonable
                    if combined_route_distance < original_cab_to_current_dropoff_dist * max_detour_factor:
                        # Also ensure the new user's trip isn't excessively long compared to their direct path
                        new_user_trip_in_shared_cab = calculate_distance(
                            user_start_latitude, user_start_longitude,
                            user_end_latitude, user_end_longitude
                        ) # This is a simplification, should be actual path in combined route

                        if new_user_trip_in_shared_cab < user_direct_distance * max_detour_factor:
                            # The 'distance' returned here is the pickup distance for the new user
                            pickup_distance_for_new_user = calculate_distance(
                                cab_current_location[0], cab_current_location[1],
                                user_start_latitude, user_start_longitude
                            )
                            if pickup_distance_for_new_user < min_detour_distance:
                                best_shared_cab = cab
                                min_detour_distance = pickup_distance_for_new_user

        if best_shared_cab:
            return best_shared_cab, min_detour_distance
        
        return None, float('inf')