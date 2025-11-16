import math

def calculate_distance(lat1, lon1, lat2, lon2):
    """
    Calculate the distance between two points on Earth using the Haversine formula.
    The distance is in kilometers.
    """
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

def calculate_fare(distance):
    """
    Calculate the fare based on distance.
    """
    BASE_FARE = 50  # Base fare in INR
    PER_KM_RATE = 15  # Rate per kilometer in INR
    return BASE_FARE + (PER_KM_RATE * distance)

def is_point_on_segment(px, py, ax, ay, bx, by, tolerance=0.001):
    """
    Check if point P(px, py) is on the segment AB.
    """
    # Calculate distances
    dist_ab = calculate_distance(ax, ay, bx, by)
    dist_ap = calculate_distance(ax, ay, px, py)
    dist_pb = calculate_distance(px, py, bx, by)

    # Check if the sum of distances AP and PB is approximately equal to AB
    return abs(dist_ap + dist_pb - dist_ab) < tolerance

def is_point_on_path(px, py, path, tolerance=0.001):
    """
    Check if point P(px, py) is on any segment of a given path.
    Path is a list of (latitude, longitude) tuples.
    """
    if len(path) < 2:
        return False

    for i in range(len(path) - 1):
        ax, ay = path[i]
        bx, by = path[i+1]
        if is_point_on_segment(px, py, ax, ay, bx, by, tolerance):
            return True
    return False