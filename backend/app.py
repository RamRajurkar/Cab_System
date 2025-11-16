# app.py
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
from dsa.utils import calculate_distance, calculate_fare
from dsa.ride_sharing import RideSharing

# ---------------------------------------------
# INITIALIZATION
# ---------------------------------------------
load_dotenv()
app = Flask(__name__)
CORS(app)
sockets = Sockets(app)
db = DatabaseUtils(db_path='database.db')
ride_sharing = RideSharing(db_path='database.db')

clients = []  # connected websocket clients
active_cab_targets = {}  # { cab_id: { target_lat, target_lng, phase } }

# ---------------------------------------------
# ROUTES: CABS, REGISTER
# ---------------------------------------------
@app.route('/api/cabs', methods=['GET'])
def get_cabs():
    try:
        cabs = db.get_all_cabs()
        return jsonify(cabs)
    except Exception as e:
        return jsonify({'error': str(e)}), 500


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
        try:
            conn.rollback()
        except Exception:
            pass
        return jsonify({'message': 'Cab registration/update failed', 'error': str(e)}), 500
    finally:
        db.disconnect()


# ---------------------------------------------
# WEBSOCKET ENDPOINT
# ---------------------------------------------
@sockets.route('/cab_location_updates')
def cab_location_updates(ws):
    """WebSocket endpoint clients connect to for live cab updates."""
    clients.append(ws)
    print("🟢 Client connected to /cab_location_updates (total clients: {})".format(len(clients)))
    try:
        # Keep connection alive
        while not ws.closed:
            gevent.sleep(0.1)
    finally:
        try:
            clients.remove(ws)
        except Exception:
            pass
        print("🔴 Client disconnected (remaining: {})".format(len(clients)))


# ---------------------------------------------
# FIND & BOOK
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

    try:
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
                'status': cab.get('status', 'Available'),
                'total_distance': total_distance_km * 1000,
                'fare': fare
            })

        if not available_options:
            # Add ride request to the database
        user_id = 1 # Placeholder for actual user ID
        new_request_id = db.add_ride_request(user_id, user_start_latitude, user_start_longitude, user_end_latitude, user_end_longitude, is_shared=False)

        if new_request_id:
            potential_shared_rides = ride_sharing.find_shared_ride(new_request_id)
            for shared_ride_request in potential_shared_rides:
                # For simplicity, let's assume the fare for shared ride is half of the individual fare
                # A more complex fare division logic is in ride_sharing.py
                total_distance_km = calculate_distance(
                    user_start_latitude, user_start_longitude,
                    user_end_latitude, user_end_longitude
                )
                fare = calculate_fare(total_distance_km) / 2 # Example fare division
                available_options.append({
                    'cab': {'cab_id': f'shared_{shared_ride_request[0]}', 'name': 'Shared Ride'},
                    'pickup_distance': 0, # This needs to be calculated based on the shared ride's current position
                    'is_shared': True,
                    'status': 'Available',
                    'total_distance': total_distance_km * 1000,
                    'fare': fare,
                    'primary_request_id': shared_ride_request[0]
                })

        if not available_options:
            return jsonify({'error': 'No cab available'}), 404

        available_options.sort(key=lambda x: x['pickup_distance'])
        return jsonify({'available_cabs': available_options[:3], 'new_request_id': new_request_id})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


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

    try:
        cabs = db.get_all_cabs()
        cab = next((c for c in cabs if c['cab_id'] == cab_id), None)
        if not cab:
            return jsonify({'error': f'Cab {cab_id} not found'}), 404

        # Mark cab Busy / Shared
        db.update_cab_status(cab_id, 'Busy' if not is_shared else 'Shared')

        distance = calculate_distance(start_lat, start_lng, end_lat, end_lng)
        fare = calculate_fare(distance)
        if is_shared:
            primary_request_id = data.get('primary_request_id')
            if not primary_request_id:
                return jsonify({'error': 'Missing primary_request_id for shared ride'}), 400
            # Assuming new_request_id is the ID of the current user's ride request
            # This needs to be passed from the frontend or retrieved from the db
            # For now, let's assume the new_request_id is available in the data
            new_request_id = data.get('new_request_id') # This needs to be handled properly
            if not new_request_id:
                return jsonify({'error': 'Missing new_request_id for shared ride'}), 400

            # Calculate fare division (this is a simplified example)
            primary_ride_distance = calculate_distance(start_lat, start_lng, end_lat, end_lng) # This should be the primary ride's actual distance
            secondary_ride_distance = calculate_distance(start_lat, start_lng, end_lat, end_lng) # This should be the secondary ride's actual distance
            total_fare = fare # Total fare for the combined ride

            primary_fare, secondary_fare = ride_sharing.calculate_fare_division(
                primary_ride_distance, secondary_ride_distance, total_fare
            )

            shared_ride_id = ride_sharing.confirm_shared_ride(primary_request_id, new_request_id, {'primary_fare': primary_fare, 'secondary_fare': secondary_fare})
            if not shared_ride_id:
                return jsonify({'error': 'Failed to confirm shared ride'}), 500
            db.add_ride(cab_id, start_lat, start_lng, end_lat, end_lng, is_shared, shared_ride_id=shared_ride_id)
        else:
            db.add_ride(cab_id, start_lat, start_lng, end_lat, end_lng, is_shared)

        # assign movement target to pickup (phase: to_pickup)
        active_cab_targets[cab_id] = {
            "target_lat": float(start_lat),
            "target_lng": float(start_lng),
            "phase": "to_pickup"
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

    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ---------------------------------------------
# RESET & COMPLETE
# ---------------------------------------------
@app.route('/api/reset_cab_status', methods=['POST'])
def reset_cab_status():
    data = request.get_json()
    cab_id = data.get('cab_id')
    try:
        if cab_id:
            updated = db.update_cab_status(cab_id, 'Available')
            if not updated:
                return jsonify({'error': f'Cab {cab_id} not found or update failed'}), 404
            message = f'Cab {cab_id} status reset to Available'
        else:
            db.reset_all_cab_statuses()
            message = 'All cab statuses reset to Available'
        return jsonify({'message': message}), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/complete_ride/<int:cab_id>', methods=['GET'])
def complete_ride(cab_id):
    try:
        # Update status to Available
        updated = db.update_cab_status(cab_id, 'Available')
        if not updated:
            return jsonify({'error': 'Cab update failed'}), 400

        # Fetch last ride and set final position if available
        ride_details = db.get_ride_by_cab_id(cab_id)
        if ride_details:
            destination_lat = ride_details.get('end_latitude')
            destination_lng = ride_details.get('end_longitude')
            if destination_lat not in (None, "") and destination_lng not in (None, ""):
                try:
                    db.update_cab_location(cab_id, float(destination_lat), float(destination_lng))
                except Exception:
                    try:
                        db.update_cab_location(cab_id, destination_lat, destination_lng)
                    except Exception:
                        pass

        # Remove active target (finalize)
        if cab_id in active_cab_targets:
            active_cab_targets.pop(cab_id, None)

        broadcast_to_all({
            "cab_id": cab_id,
            "latitude": float(ride_details.get('end_latitude')) if ride_details and ride_details.get('end_latitude') else 0.0,
            "longitude": float(ride_details.get('end_longitude')) if ride_details and ride_details.get('end_longitude') else 0.0,
            "status": "Available"
        })

        return jsonify({'message': f'Cab {cab_id} set to Available'}), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ---------------------------------------------
# SIMULATION: move cab -> pickup -> destination
# ---------------------------------------------
def simulate_cab_movements():
    """
    Loop: read DB cabs -> move those in active_cab_targets toward their target.
    When pickup reached -> switch to destination (if ride exists).
    When destination reached -> mark Arrived (do not remove active target; await /complete_ride).
    Broadcast updates to connected websocket clients.
    """
    print("🚗 Starting cab movement simulation (spawned in gunicorn worker)...")
    while True:
        try:
            cabs = db.get_all_cabs()
            updates = []

            for cab in cabs:
                try:
                    cab_id = cab['cab_id']
                    lat = float(cab.get('latitude', 0.0))
                    lon = float(cab.get('longitude', 0.0))
                    status = cab.get('status', 'Available')
                except Exception as e:
                    print("⚠️ Skipping malformed cab record:", e)
                    continue

                if cab_id in active_cab_targets:
                    target = active_cab_targets[cab_id]
                    target_lat = float(target.get('target_lat', lat))
                    target_lng = float(target.get('target_lng', lon))
                    phase = target.get('phase', 'to_pickup')

                    dlat = target_lat - lat
                    dlon = target_lng - lon
                    dist = (dlat**2 + dlon**2) ** 0.5

                    ARRIVE_THRESHOLD = 0.00025

                    if dist < ARRIVE_THRESHOLD:
                        # Arrived at target
                        if phase == 'to_pickup':
                            print(f"✅ Cab {cab_id} reached pickup.")
                            db.update_cab_status(cab_id, "Arrived", latitude=target_lat, longitude=target_lng)
                            broadcast_to_all({
                                "cab_id": cab_id,
                                "latitude": target_lat,
                                "longitude": target_lng,
                                "status": "Arrived"
                            })

                            # switch to destination (if ride exists)
                            ride = db.get_ride_by_cab_id(cab_id)
                            if ride and ride.get('end_latitude') and ride.get('end_longitude'):
                                try:
                                    end_lat = float(ride.get('end_latitude'))
                                    end_lng = float(ride.get('end_longitude'))
                                    active_cab_targets[cab_id] = {
                                        "target_lat": end_lat,
                                        "target_lng": end_lng,
                                        "phase": "to_destination"
                                    }
                                    db.update_cab_status(cab_id, "OnTrip", latitude=target_lat, longitude=target_lng)
                                    print(f"➡️ Cab {cab_id} now heading to destination {end_lat},{end_lng}")
                                except Exception as e:
                                    print("⚠️ invalid destination; freeing cab", e)
                                    db.update_cab_status(cab_id, "Available")
                                    active_cab_targets.pop(cab_id, None)
                                    broadcast_to_all({
                                        "cab_id": cab_id,
                                        "latitude": lat,
                                        "longitude": lon,
                                        "status": "Available"
                                    })
                            else:
                                # no ride, free cab
                                db.update_cab_status(cab_id, "Available")
                                active_cab_targets.pop(cab_id, None)
                                broadcast_to_all({
                                    "cab_id": cab_id,
                                    "latitude": lat,
                                    "longitude": lon,
                                    "status": "Available"
                                })

                        elif phase == 'to_destination':
                            print(f"🏁 Cab {cab_id} reached destination.")
                            db.update_cab_status(cab_id, "Arrived", latitude=target_lat, longitude=target_lng)
                            try:
                                db.update_cab_location(cab_id, target_lat, target_lng)
                            except Exception:
                                pass
                            broadcast_to_all({
                                "cab_id": cab_id,
                                "latitude": target_lat,
                                "longitude": target_lng,
                                "status": "ArrivedDestination"
                            })
                            # DO NOT remove active target; wait for /complete_ride

                    else:
                        # Move step toward target
                        step = 0.00025
                        lat += step * (dlat / dist)
                        lon += step * (dlon / dist)

                        # Update DB location
                        try:
                            db.update_cab_location(cab_id, lat, lon, status=status if status else None)
                        except Exception:
                            try:
                                db.update_cab_location(cab_id, lat, lon)
                            except Exception:
                                pass

                        # add to updates for broadcast
                        broadcast_status = 'Enroute' if phase == 'to_pickup' else 'OnTrip'
                        updates.append({
                            "cab_id": cab_id,
                            "latitude": lat,
                            "longitude": lon,
                            "status": broadcast_status
                        })

                else:
                    # idle wandering for available cabs
                    if status == "Available":
                        lat += random.uniform(-0.00015, 0.00015)
                        lon += random.uniform(-0.00015, 0.00015)
                        try:
                            db.update_cab_location(cab_id, lat, lon)
                        except Exception:
                            pass
                    updates.append({
                        "cab_id": cab_id,
                        "latitude": lat,
                        "longitude": lon,
                        "status": status
                    })

            # send updates to websocket clients
            for client in clients[:]:
                if client.closed:
                    try:
                        clients.remove(client)
                    except Exception:
                        pass
                    continue
                for u in updates:
                    try:
                        client.send(json.dumps(u))
                    except Exception:
                        try:
                            clients.remove(client)
                        except Exception:
                            pass

        except Exception as e:
            print("💥 Simulation loop error:", e)

        gevent.sleep(2)


def broadcast_to_all(message: dict):
    for client in clients[:]:
        if client.closed:
            try:
                clients.remove(client)
            except Exception:
                pass
            continue
        try:
            client.send(json.dumps(message))
        except Exception:
            try:
                clients.remove(client)
            except Exception:
                pass


# ---------------------------------------------
# START SIMULATION (spawn under Gunicorn worker)
# ---------------------------------------------
# Important: spawn() runs the simulation in the worker process context.
# This line ensures the simulation loop runs when Gunicorn imports app.py.
try:
    spawn(simulate_cab_movements)
    print("🟢 Cab simulation spawned.")
except Exception as e:
    print("⚠️ Failed to spawn simulation:", e)
