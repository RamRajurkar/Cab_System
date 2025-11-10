import heapq
import math
from dsa.utils import calculate_distance

class Graph:
    """
    Graph implementation for route optimization using Dijkstra's algorithm.
    """
    def __init__(self):
        """
        Initialize an empty graph represented as an adjacency list.
        """
        self.vertices = {}
        self.edges = {}
    
    def add_vertex(self, vertex):
        """
        Add a vertex to the graph.
        
        Args:
            vertex: A tuple (x, y) representing the coordinates of the vertex.
        """
        if vertex not in self.vertices:
            self.vertices[vertex] = []
            self.edges[vertex] = {}
    
    def add_edge(self, vertex1, vertex2, weight=None):
        """
        Add an edge between two vertices with an optional weight.
        If weight is not provided, it will be calculated as the Euclidean distance.
        
        Args:
            vertex1: First vertex (x1, y1).
            vertex2: Second vertex (x2, y2).
            weight: Optional weight of the edge.
        """
        if vertex1 not in self.vertices:
            self.add_vertex(vertex1)
        if vertex2 not in self.vertices:
            self.add_vertex(vertex2)
        
        # Calculate weight as Euclidean distance if not provided
        if weight is None:
            lat1, lon1 = vertex1
            lat2, lon2 = vertex2
            weight = calculate_distance(lat1, lon1, lat2, lon2)
        
        # Add the edge in both directions (undirected graph)
        self.vertices[vertex1].append(vertex2)
        self.edges[vertex1][vertex2] = weight
        
        self.vertices[vertex2].append(vertex1)
        self.edges[vertex2][vertex1] = weight
    
    def dijkstra(self, start_vertex, end_vertex):
        """
        Find the shortest path between start_vertex and end_vertex using Dijkstra's algorithm.
        
        Args:
            start_vertex: Starting vertex (x1, y1).
            end_vertex: Ending vertex (x2, y2).
            
        Returns:
            A tuple (distance, path) where distance is the total distance of the shortest path
            and path is a list of vertices representing the shortest path.
        """
        if start_vertex not in self.vertices or end_vertex not in self.vertices:
            return float('inf'), []
        
        # Initialize distances with infinity for all vertices except the start vertex
        distances = {vertex: float('inf') for vertex in self.vertices}
        distances[start_vertex] = 0
        
        # Initialize previous vertex dictionary for path reconstruction
        previous = {vertex: None for vertex in self.vertices}
        
        # Priority queue for Dijkstra's algorithm
        priority_queue = [(0, start_vertex)]
        
        while priority_queue:
            current_distance, current_vertex = heapq.heappop(priority_queue)
            
            # If we've reached the end vertex, we can stop
            if current_vertex == end_vertex:
                break
            
            # If we've already found a better path, skip
            if current_distance > distances[current_vertex]:
                continue
            
            # Check all neighbors of the current vertex
            for neighbor in self.vertices[current_vertex]:
                weight = self.edges[current_vertex][neighbor]
                distance = current_distance + weight
                
                # If we found a better path to the neighbor
                if distance < distances[neighbor]:
                    distances[neighbor] = distance
                    previous[neighbor] = current_vertex
                    heapq.heappush(priority_queue, (distance, neighbor))
        
        # Reconstruct the path
        path = []
        current = end_vertex
        
        while current is not None:
            path.append(current)
            current = previous[current]
        
        # Reverse the path to get it from start to end
        path.reverse()
        
        return distances[end_vertex], path


class RouteOptimizer:
    """
    Utility class for optimizing routes using a graph and Dijkstra's algorithm.
    """
    @staticmethod
    def create_grid_graph(min_lat, max_lat, min_lon, max_lon, lat_step, lon_step):
        """
        Create a grid graph for a geographical area.
        
        Args:
            min_lat, max_lat: Latitude range.
            min_lon, max_lon: Longitude range.
            lat_step, lon_step: Step sizes for latitude and longitude.
            
        Returns:
            A Graph object representing the grid.
        """
        graph = Graph()
        
        # Create vertices
        latitudes = [min_lat + i * lat_step for i in range(int((max_lat - min_lat) / lat_step) + 1)]
        longitudes = [min_lon + i * lon_step for i in range(int((max_lon - min_lon) / lon_step) + 1)]

        for lat in latitudes:
            for lon in longitudes:
                graph.add_vertex((lat, lon))
        
        # Create edges (connecting each vertex to its neighbors)
        for i in range(len(latitudes)):
            for j in range(len(longitudes)):
                current_lat = latitudes[i]
                current_lon = longitudes[j]
                current_vertex = (current_lat, current_lon)

                # Connect to right neighbor (increasing longitude)
                if j + 1 < len(longitudes):
                    right_vertex = (current_lat, longitudes[j+1])
                    graph.add_edge(current_vertex, right_vertex)
                
                # Connect to top neighbor (increasing latitude)
                if i + 1 < len(latitudes):
                    top_vertex = (latitudes[i+1], current_lon)
                    graph.add_edge(current_vertex, top_vertex)
                
                # Connect to diagonal neighbor (optional)
                if i + 1 < len(latitudes) and j + 1 < len(longitudes):
                    diagonal_vertex = (latitudes[i+1], longitudes[j+1])
                    graph.add_edge(current_vertex, diagonal_vertex)
        
        return graph
    
    @staticmethod
    def find_shortest_path(start_latitude, start_longitude, end_latitude, end_longitude, 
                             lat_step=0.01, lon_step=0.01, buffer=0.05):
        """
        Find the shortest path between two geographical points using Dijkstra's algorithm.
        
        Args:
            start_latitude, start_longitude: Starting coordinates.
            end_latitude, end_longitude: Ending coordinates.
            lat_step, lon_step: Step sizes for creating the grid.
            buffer: A buffer to extend the grid boundaries beyond the start/end points.
            
        Returns:
            A tuple (distance, path) where distance is the total distance of the shortest path
            and path is a list of (latitude, longitude) tuples representing the shortest path.
        """
        # Determine the bounding box for the grid
        min_lat = min(start_latitude, end_latitude) - buffer
        max_lat = max(start_latitude, end_latitude) + buffer
        min_lon = min(start_longitude, end_longitude) - buffer
        max_lon = max(start_longitude, end_longitude) + buffer

        # Create a grid graph for the relevant geographical area
        graph = RouteOptimizer.create_grid_graph(min_lat, max_lat, min_lon, max_lon, lat_step, lon_step)
        
        start_vertex = (start_latitude, start_longitude)
        end_vertex = (end_latitude, end_longitude)

        # Add the exact start and end points to the graph if they are not already grid points
        graph.add_vertex(start_vertex)
        graph.add_vertex(end_vertex)

        # Connect the start and end vertices to their nearest grid points
        # This is a simplified approach; a more robust solution would connect to multiple nearby points
        # or use a more sophisticated snapping mechanism.
        latitudes = [min_lat + i * lat_step for i in range(int((max_lat - min_lat) / lat_step) + 1)]
        longitudes = [min_lon + i * lon_step for i in range(int((max_lon - min_lon) / lon_step) + 1)]

        # Connect start_vertex to nearest grid points
        for lat in latitudes:
            for lon in longitudes:
                grid_point = (lat, lon)
                if calculate_distance(start_latitude, start_longitude, lat, lon) < lat_step * 2: # Heuristic for proximity
                    graph.add_edge(start_vertex, grid_point)
                if calculate_distance(end_latitude, end_longitude, lat, lon) < lat_step * 2: # Heuristic for proximity
                    graph.add_edge(end_vertex, grid_point)
        
        # Find the shortest path using Dijkstra's algorithm
        distance, path = graph.dijkstra(start_vertex, end_vertex)
        
        return distance, path
    
    @staticmethod
    def calculate_route_overlap(path1, path2):
        """
        Calculate the overlap between two paths.
        
        Args:
            path1: First path as a list of coordinates.
            path2: Second path as a list of coordinates.
            
        Returns:
            A float representing the percentage of overlap between the two paths.
        """
        # Convert paths to sets of coordinates for easier comparison
        path1_set = set(path1)
        path2_set = set(path2)
        
        # Calculate the intersection (common coordinates)
        intersection = path1_set.intersection(path2_set)
        
        # Calculate the percentage of overlap
        if not path1 or not path2:
            return 0.0
        
        overlap_percentage = len(intersection) / min(len(path1), len(path2))
        return overlap_percentage
    
    @staticmethod
    def is_route_shareable(path1, path2, threshold=0.5):
        """
        Determine if two routes can be shared based on their overlap.
        
        Args:
            path1: First path as a list of coordinates.
            path2: Second path as a list of coordinates.
            threshold: Minimum overlap percentage required for sharing.
            
        Returns:
            True if the routes can be shared, False otherwise.
        """
        overlap = RouteOptimizer.calculate_route_overlap(path1, path2)
        return overlap >= threshold