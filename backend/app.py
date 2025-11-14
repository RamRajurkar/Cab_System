from flask import Flask, request, jsonify
from dotenv import load_dotenv
from flask_sockets import Sockets
from flask_cors import CORS
import json
import random
import gevent
from gevent import spawn
from dsa.db_utils import DatabaseUtils
from dsa.heap_utils import CabFinder
from dsa.graph import RouteOptimizer
from dsa.utils import calculate_distance, calculate_fare

# ---------------------------------------------
# INITIALIZATION
# ---------------------------------------------
load_dotenv()
app = Flask(__name__)
CORS(app)
sockets = Sockets(app)
db = DatabaseUtils(db_path='database.db')

clients = []  # connected websocket clients
active_cab_targets = {}  # store pickup targets for booked cabs


# ---------------------------------------------
# CAB MANAGEMENT ROUTES
# ---------------------------------------------
@app.route('/api/cabs', methods=['GET'])
def get_cabs():
    cabs = db.get_all_cabs()
    return jsonify(cabs)


@app.route('/api/cab_register', methods=['POST'])
def cab_register():
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

    try:
        conn = db.connect()
        cursor = conn.cursor()
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


# ---------------------------------------------
# CAB LOCATION UPDATES VIA SOCKET
# ---------------------------------------------
@sockets.route('/cab_location_updates')
def cab_location_updates(ws):
    clients.append(ws)
    print("🟢 Client connected to /cab_location_updates")
    while not ws.closed:
        gevent.sleep(0.1)


# ---------------------------------------------
# CAB FINDING / BOOKING
# ---------------------------------------------
@app.route('/api/find_cab', methods=['POST'])
def find_cab():
    data = request.json
    user_start_latitude = data.get('start_latitude')
    user_start_longitude = data.get('start_longitude')
    user_end_latitude = data.get('end_latitude')
    user_end_longitude = data.get('end_longitude')

    if not all([user_start_latitude, user_start_longitude, user_end_latitude, user_end_longitude]):
        return jsonify({'error': 'Missing coordinates'}), 400

    cabs = db.get_all_cabs()
    nearest_cabs_info = CabFinder.find_nearest_cab(
        cabs, user_start_latitude, user_start_longitude, num_cabs=3
    )

    available_options = []
    for cab, distance in nearest_cabs_info:
        total_distance_km = calculate_distance(
            user_start_latitude, user_start_longitude,
            user_end_latitude, user_end_longitude
        )
        fare = calculate_fare(total_distance_km)
        available_options.append({
            'cab': cab,
            'pickup_distance': distance * 1000,
            'is_shared': False,
            'status': 'Available',
            'total_distance': total_distance_km * 1000,
            'fare': fare
        })

    if not available_options:
        return jsonify({'error': 'No cab available'}), 404

    available_options.sort(key=lambda x: x['pickup_distance'])
    return jsonify({'available_cabs': available_options[:3]})


@app.route('/api/book_cab', methods=['POST'])
def book_cab():
    data = request.json
    cab_id = data.get('cab_id')
    start_lat = data.get('start_latitude')
    start_lng = data.get('start_longitude')
    end_lat = data.get('end_latitude')
    end_lng = data.get('end_longitude')
    is_shared = data.get('is_shared', False)

    if not all([cab_id, start_lat, start_lng, end_lat, end_lng]):
        return jsonify({'error': 'Missing booking information'}), 400

    cabs = db.get_all_cabs()
    cab = next((c for c in cabs if c['cab_id'] == cab_id), None)
    if not cab:
        return jsonify({'error': f'Cab {cab_id} not found'}), 404

    db.update_cab_status(cab_id, 'Busy' if not is_shared else 'Shared')

    distance = calculate_distance(start_lat, start_lng, end_lat, end_lng)
    fare = calculate_fare(distance)
    db.add_ride(cab_id, start_lat, start_lng, end_lat, end_lng, is_shared)

    # 🎯 assign movement target
    active_cab_targets[cab_id] = {
        "target_lat": start_lat,
        "target_lng": start_lng,
        "status": "enroute"
    }

    return jsonify({
        'message': 'Ride booked successfully!',
        'cab': cab,
        'cab_id': cab_id,
        'status': 'Enroute to Pickup',
        'fare': fare,
        'start_latitude': start_lat,
        'start_longitude': start_lng,
        'end_latitude': end_lat,
        'end_longitude': end_lng,
        'is_shared': is_shared
    })


# ---------------------------------------------
# COMPLETE RIDE
# ---------------------------------------------
@app.route('/api/complete_ride/<int:cab_id>', methods=['GET'])
def complete_ride(cab_id):
    if db.update_cab_status(cab_id, 'Available'):
        destination_lat = None
        destination_lng = None
        ride_details = db.get_ride_by_cab_id(cab_id)
        if ride_details:
            destination_lat = ride_details['end_latitude']
            destination_lng = ride_details['end_longitude']
            db.update_cab_location(cab_id, destination_lat, destination_lng)

        if cab_id in active_cab_targets:
            del active_cab_targets[cab_id]
        broadcast_to_all({
            "cab_id": cab_id,
            "latitude": destination_lat,
            "longitude": destination_lng,
            "status": "Available"
        })
        return jsonify({'message': f'Cab {cab_id} set to Available'}), 200
    return jsonify({'message': 'Failed to complete ride'}), 500


# ---------------------------------------------
# SIMULATION LOOP
# ---------------------------------------------
def simulate_cab_movements():
    """Simulate live cab movement toward pickup points."""
    print("🚗 Starting live cab movement simulation...")

    while True:
        try:
            cabs = db.get_all_cabs()
            updates = []

            for cab in cabs:
                cab_id = cab['cab_id']
                lat = float(cab['latitude'])
                lon = float(cab['longitude'])
                status = cab.get('status', 'Available')

                # 🚕 Move cab toward pickup if assigned
                if cab_id in active_cab_targets:
                    target = active_cab_targets[cab_id]
                    target_lat = float(target['target_lat'])
                    target_lng = float(target['target_lng'])

                    dlat = target_lat - lat
                    dlon = target_lng - lon
                    dist = (dlat**2 + dlon**2) ** 0.5

                    if dist < 0.00025:
                        print(f"✅ Cab {cab_id} reached pickup!")
                        db.update_cab_status(cab_id, "Arrived")
                        target['status'] = 'arrived'
                        # Optional: notify clients
                        broadcast_to_all({
                            "cab_id": cab_id,
                            "status": "Arrived"
                        })
                        del active_cab_targets[cab_id]
                    else:
                        step = 0.0002
                        lat += step * (dlat / dist)
                        lon += step * (dlon / dist)
                        db.update_cab_location(cab_id, lat, lon, status)

                # 💤 Slight movement for idle cabs
                elif status == "Available":
                    lat += random.uniform(-0.0002, 0.0002)
                    lon += random.uniform(-0.0002, 0.0002)
                    db.update_cab_location(cab_id, lat, lon, status)

                updates.append({
                    "cab_id": cab_id,
                    "latitude": lat,
                    "longitude": lon,
                    "status": status
                })

            # Broadcast to WebSocket clients
            for client in clients[:]:
                if not client.closed:
                    for u in updates:
                        try:
                            client.send(json.dumps(u))
                        except Exception:
                            clients.remove(client)

        except Exception as e:
            print(f"💥 Simulation error: {e}")

        gevent.sleep(2)  # update frequency


def broadcast_to_all(message: dict):
    """Helper to broadcast a single message to all clients."""
    for client in clients[:]:
        if not client.closed:
            try:
                client.send(json.dumps(message))
            except Exception:
                clients.remove(client)


# ---------------------------------------------
# SERVER STARTUP
# ---------------------------------------------
if __name__ == '__main__':
    from gevent.pywsgi import WSGIServer
    from geventwebsocket.handler import WebSocketHandler

    print('🚀 Smart Cab Backend Live at http://127.0.0.1:5001')
    print('📡 WebSocket running at ws://127.0.0.1:5001/cab_location_updates')

    # Start cab simulation in background
    spawn(simulate_cab_movements)

    # Run server
    http_server = WSGIServer(('', 5001), app, handler_class=WebSocketHandler)
    http_server.serve_forever()
