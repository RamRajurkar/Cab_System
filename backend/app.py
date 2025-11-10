from flask import Flask, request, jsonify
from dotenv import load_dotenv
from flask_sockets import Sockets
from flask_cors import CORS
import json
import time
import gevent
import os
from dsa.db_utils import DatabaseUtils
from dsa.heap_utils import CabFinder
from dsa.graph import RouteOptimizer
from dsa.utils import calculate_distance, calculate_fare

# Load environment variables
load_dotenv()

# Initialize Flask app
app = Flask(__name__)
CORS(app)  # Enable CORS for all routes
sockets = Sockets(app)

# Initialize database
db = DatabaseUtils(db_path='database.db')

# -----------------------------
# CAB MANAGEMENT ROUTES
# -----------------------------

@app.route('/api/cabs', methods=['GET'])
def get_cabs():
    """Get all cabs from the database."""
    cabs = db.get_all_cabs()
    return jsonify(cabs)


@app.route('/api/cab_register', methods=['POST'])
def cab_register():
    """Register or update a cab."""
    data = request.get_json()
    cab_id = data.get('cab_id')
    name = data.get('name')
    rto_number = data.get('rto_number')
    driver_name = data.get('driver_name')
    latitude = data.get('latitude')
    longitude = data.get('longitude')
    status = data.get('status', 'Available')

    if not all([cab_id, name, rto_number, driver_name, latitude, longitude]):
        return jsonify({'message': 'Missing cab data'}), 400

    conn = db.connect()
    if not conn:
        return jsonify({'message': 'Database connection failed'}), 500
    cursor = conn.cursor()

    try:
        cursor.execute(
            'INSERT OR REPLACE INTO cabs (cab_id, name, rto_number, driver_name, latitude, longitude, status) VALUES (?, ?, ?, ?, ?, ?, ?)',
            (cab_id, name, rto_number, driver_name, latitude, longitude, status)
        )
        conn.commit()
        return jsonify({'message': 'Cab registered/updated successfully'}), 201
    except Exception as e:
        conn.rollback()
        return jsonify({'message': 'Cab registration/update failed', 'error': str(e)}), 500
    finally:
        db.disconnect()


# -----------------------------
# CAB LOCATION UPDATES VIA SOCKET
# -----------------------------
@sockets.route('/cab_location_updates')
def cab_location_updates(ws):
    """Handle real-time cab location updates."""
    while not ws.closed:
        message = ws.receive()
        if message:
            try:
                data = json.loads(message)
                cab_id = data.get('cab_id')
                latitude = data.get('latitude')
                longitude = data.get('longitude')
                status = data.get('status')

                if cab_id is not None and latitude is not None and longitude is not None:
                    db.update_cab_location(cab_id, latitude, longitude, status)
                else:
                    print(f"Invalid location update received: {data}")
            except json.JSONDecodeError:
                print(f"Received non-JSON message: {message}")
        gevent.sleep(0.1)  # Yield to other greenlets


# -----------------------------
# CAB ALLOCATION / FINDING
# -----------------------------
@app.route('/api/find_cab', methods=['POST'])
def find_cab():
    """Find the nearest available cab or a cab that can be shared."""
    data = request.json

    user_start_latitude = data.get('start_latitude')
    user_start_longitude = data.get('start_longitude')
    user_end_latitude = data.get('end_latitude')
    user_end_longitude = data.get('end_longitude')

    if user_start_latitude is None or user_start_longitude is None or user_end_latitude is None or user_end_longitude is None:
        return jsonify({'error': 'Missing coordinates'}), 400

    cabs = db.get_all_cabs()

    # Get multiple nearest available cabs
    nearest_cabs_info = CabFinder.find_nearest_cab(
        cabs, user_start_latitude, user_start_longitude, num_cabs=3
    )

    # Get potential shared cabs (currently returns one best shared cab, need to adapt if multiple are desired)
    # For now, we'll treat find_shared_cab as returning the single best shared option
    shared_cab_info, shared_pickup_distance = CabFinder.find_shared_cab(
        cabs, user_start_latitude, user_start_longitude, user_end_latitude, user_end_longitude
    )

    available_options = []

    # Add nearest available cabs to options
    for cab, distance in nearest_cabs_info:
        total_distance_km = calculate_distance(user_start_latitude, user_start_longitude, user_end_latitude, user_end_longitude)
        fare = calculate_fare(total_distance_km)
        available_options.append({
            'cab': cab,
            'pickup_distance': distance * 1000, # Convert to meters
            'is_shared': False,
            'status': 'Available',
            'total_distance': total_distance_km * 1000, # Convert to meters
            'fare': fare
        })

    # Add the best shared cab to options, if found and viable
    if shared_cab_info and shared_pickup_distance != float('inf'):
        total_distance_km = calculate_distance(user_start_latitude, user_start_longitude, user_end_latitude, user_end_longitude)
        fare = calculate_fare(total_distance_km)
        available_options.append({
            'cab': shared_cab_info,
            'pickup_distance': shared_pickup_distance * 1000, # Convert to meters
            'is_shared': True,
            'status': 'Shared',
            'total_distance': total_distance_km * 1000, # Convert to meters
            'fare': fare
        })

    if not available_options:
        return jsonify({'error': 'No cab available'}), 404

    # Sort options by pickup distance to present the best ones first
    available_options.sort(key=lambda x: x['pickup_distance'])

    # Return the top 3 options to the user
    return jsonify({
        'available_cabs': available_options[:3]
    })

@app.route('/api/book_cab', methods=['POST'])
def book_cab():
    data = request.json
    cab_id = data.get('cab_id')
    user_start_latitude = data.get('start_latitude')
    user_start_longitude = data.get('start_longitude')
    user_end_latitude = data.get('end_latitude')
    user_end_longitude = data.get('end_longitude')
    is_shared = data.get('is_shared')

    print(f"Received booking data: {data}")
    if not all([cab_id, user_start_latitude, user_start_longitude, user_end_latitude, user_end_longitude]) or not isinstance(is_shared, bool):
        print(f"Missing or invalid booking information: cab_id={cab_id}, start_lat={user_start_latitude}, start_lon={user_start_longitude}, end_lat={user_end_latitude}, end_lon={user_end_longitude}, is_shared={is_shared} (type: {type(is_shared)})")
        return jsonify({'error': 'Missing booking information'}), 400

    cabs = db.get_all_cabs()
    cab = next((c for c in cabs if c['cab_id'] == cab_id), None)

    if not cab:
        return jsonify({'error': f'Cab {cab_id} not found'}), 404

    # Update cab status
    new_status = 'Shared' if is_shared else 'Busy'
    db.update_cab_status(cab_id, new_status)

    # Find route path
    _, path = RouteOptimizer.find_shortest_path(
        user_start_latitude, user_start_longitude, user_end_latitude, user_end_longitude
    )

    # Calculate distance and fare
    distance = calculate_distance(user_start_latitude, user_start_longitude, user_end_latitude, user_end_longitude)
    fare = calculate_fare(distance)

    # Save ride in DB
    db.add_ride(
        cab_id, user_start_latitude, user_start_longitude, user_end_latitude, user_end_longitude, is_shared
    )

    return jsonify({
        'message': 'Ride booked successfully!',
        'cab': cab, # Include full cab details
        'cab_id': cab_id,
        'status': new_status,
        'distance': 0.0, # Distance to cab is 0 once booked
        'source_destination_distance': distance, # This is the total ride distance
        'total_distance': distance, # Total distance for the ride
        'fare': fare,
        'start_latitude': user_start_latitude,
        'start_longitude': user_start_longitude,
        'end_latitude': user_end_latitude,
        'end_longitude': user_end_longitude,
        'is_shared': is_shared
    })


# -----------------------------
# CAB STATUS & RIDE HANDLING
# -----------------------------
@app.route('/api/complete_ride/<int:cab_id>', methods=['GET'])
def complete_ride(cab_id):
    if db.update_cab_status(cab_id, 'Available'):
        return jsonify({'message': f'Cab {cab_id} status set to Available'}), 200
    return jsonify({'message': 'Failed to complete ride'}), 500

@app.route('/api/reset_cabs_status', methods=['POST'])
def reset_cabs_status():
    if db.update_all_cabs_status('Available'):
        return jsonify({'message': 'All cabs status reset to Available'}), 200
    return jsonify({'message': 'Failed to reset cabs status'}), 500


@app.route('/api/ride_history', methods=['GET'])
def ride_history():
    """Get all previous rides."""
    rides = db.get_ride_history()
    return jsonify(rides)


@app.route('/api/active_rides', methods=['GET'])
def active_rides():
    """Get all active rides."""
    active_rides = db.get_active_rides()
    return jsonify(active_rides)


@app.route('/api/update_cab_location', methods=['POST'])
def update_cab_location():
    """Update cab location."""
    data = request.json
    cab_id = data.get('cab_id')
    latitude = data.get('latitude')
    longitude = data.get('longitude')

    if cab_id is None or latitude is None or longitude is None:
        return jsonify({'error': 'Missing cab information'}), 400

    cabs = db.get_all_cabs()
    cab = next((c for c in cabs if c['id'] == cab_id), None)

    if not cab:
        return jsonify({'error': f'Cab {cab_id} not found'}), 404

    success = db.update_cab_status(cab_id, cab['status'], latitude, longitude)

    if success:
        return jsonify({'message': f'Cab {cab_id} location updated'})
    else:
        return jsonify({'error': f'Failed to update cab {cab_id} location'}), 500


# -----------------------------
# REAL-TIME DATA BROADCAST
# -----------------------------
clients = []

@sockets.route('/ws')
def socket(ws):
    clients.append(ws)
    while not ws.closed:
        gevent.sleep(0.1)

def broadcast_data():
    with app.app_context():
        while True:
            data = {
                'cabs': db.get_all_cabs(),
                'active_rides': db.get_active_rides()
            }
            for client in clients:
                if not client.closed:
                    try:
                        client.send(json.dumps(data, default=str))
                    except Exception as e:
                        print(f"Error sending to client: {e}")
                        clients.remove(client)
            gevent.sleep(5)


# -----------------------------
# START SERVER
# -----------------------------
if __name__ == '__main__':
    from gevent.pywsgi import WSGIServer
    from geventwebsocket.handler import WebSocketHandler

    print('🚕 Server running on http://127.0.0.1:5001')
    http_server = WSGIServer(('', 5001), app, handler_class=WebSocketHandler)
    http_server.serve_forever()
