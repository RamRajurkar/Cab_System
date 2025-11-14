# app.py
import json
import random
import threading
import time
from typing import Dict, List

from flask import Flask, request, jsonify
from flask_cors import CORS
from flask_sock import Sock, ConnectionClosed

from dsa.db_utils import DatabaseUtils
from dsa.heap_utils import CabFinder
from dsa.utils import calculate_distance, calculate_fare

# ---------------------------------------------
# CONFIG / INIT
# ---------------------------------------------
app = Flask(__name__)
CORS(app)
sock = Sock(app)

db = DatabaseUtils(db_path='database.db')

# Connected websocket clients (Sock wrappers)
ws_clients: List = []  # list of ws objects from flask_sock

# Active targets:
# active_cab_targets[cab_id] = {
#    'target_lat': float,
#    'target_lng': float,
#    'phase': 'to_pickup' | 'to_destination'
# }
active_cab_targets: Dict[int, Dict] = {}

# Lock to protect shared datastructures (clients & active_cab_targets)
_lock = threading.Lock()


# ---------------------------------------------
# Helpers: Broadcast, safe remove
# ---------------------------------------------
def broadcast_to_all(message: dict):
    """Send JSON message to all connected websocket clients (sync)."""
    text = json.dumps(message)
    with _lock:
        # iterate copy to allow removal
        for ws in ws_clients[:]:
            try:
                ws.send(text)
            except ConnectionClosed:
                try:
                    ws_clients.remove(ws)
                except ValueError:
                    pass
            except Exception:
                try:
                    ws_clients.remove(ws)
                except ValueError:
                    pass


# ---------------------------------------------
# HTTP ROUTES: cabs, register, find, book
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
        cur = conn.cursor()
        cur.execute(
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
            return jsonify({'error': 'No cab available'}), 404

        available_options.sort(key=lambda x: x['pickup_distance'])
        return jsonify({'available_cabs': available_options[:3]})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/book_cab', methods=['POST'])
def book_cab():
    """Book a cab -> create ride row -> set cab Busy -> set active target to pickup"""
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

        # mark busy/shared depending on shared flag
        db.update_cab_status(cab_id, 'Busy' if not is_shared else 'Shared')

        dist = calculate_distance(start_lat, start_lng, end_lat, end_lng)
        fare = calculate_fare(dist)
        db.add_ride(cab_id, start_lat, start_lng, end_lat, end_lng, is_shared)

        # assign movement to pickup (phase: to_pickup)
        with _lock:
            active_cab_targets[cab_id] = {
                'target_lat': float(start_lat),
                'target_lng': float(start_lng),
                'phase': 'to_pickup'
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
# START RIDE (client tells server to start moving to destination)
# ---------------------------------------------
@app.route('/api/start_ride/<int:cab_id>', methods=['POST'])
def start_ride(cab_id):
    """Called when user taps 'Start Ride' in the client.
    This switches the cab's target to the ride destination and sets status OnTrip.
    """
    try:
        # Get latest ride info
        ride = db.get_ride_by_cab_id(cab_id)
        if not ride:
            return jsonify({'error': 'Ride not found for cab'}), 404

        end_lat = ride.get('end_latitude')
        end_lng = ride.get('end_longitude')
        if end_lat in (None, "") or end_lng in (None, ""):
            return jsonify({'error': 'Invalid destination coordinates'}), 400

        # Switch active target to destination
        with _lock:
            active_cab_targets[cab_id] = {
                'target_lat': float(end_lat),
                'target_lng': float(end_lng),
                'phase': 'to_destination'
            }

        # Update DB status to OnTrip (optionally set lat/lng not required)
        db.update_cab_status(cab_id, 'OnTrip')

        # Broadcast that ride started
        broadcast_to_all({
            'cab_id': cab_id,
            'latitude': float(end_lat),
            'longitude': float(end_lng),
            'status': 'OnTrip'
        })

        return jsonify({'message': 'Ride started'}), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ---------------------------------------------
# COMPLETE RIDE (finalize)
# ---------------------------------------------
@app.route('/api/complete_ride/<int:cab_id>', methods=['GET'])
def complete_ride(cab_id):
    try:
        # Set cab Available
        updated = db.update_cab_status(cab_id, 'Available')
        if not updated:
            return jsonify({'error': 'Cab update failed'}), 400

        ride = db.get_ride_by_cab_id(cab_id)
        dest_lat = None
        dest_lng = None
        if ride:
            dest_lat = ride.get('end_latitude')
            dest_lng = ride.get('end_longitude')
            if dest_lat not in (None, "") and dest_lng not in (None, ""):
                try:
                    db.update_cab_location(cab_id, float(dest_lat), float(dest_lng))
                except Exception:
                    try:
                        db.update_cab_location(cab_id, dest_lat, dest_lng)
                    except Exception:
                        pass

        # remove active target
        with _lock:
            if cab_id in active_cab_targets:
                active_cab_targets.pop(cab_id, None)

        # broadcast final available
        broadcast_to_all({
            'cab_id': cab_id,
            'latitude': float(dest_lat) if dest_lat else 0.0,
            'longitude': float(dest_lng) if dest_lng else 0.0,
            'status': 'Available'
        })

        return jsonify({'message': f'Cab {cab_id} set to Available'}), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ---------------------------------------------
# WEBSOCKET (Flask-Sock) - clients connect here
# ---------------------------------------------
@sock.route('/cab_location_updates')
def cab_location_updates(ws):
    """WebSocket endpoint - clients connect and receive periodic JSON updates."""
    with _lock:
        ws_clients.append(ws)
    print("🟢 WebSocket client connected (total: {})".format(len(ws_clients)))

    try:
        while True:
            try:
                # Receive any message (if client sends something) - not required.
                msg = ws.receive(timeout=5)
                if msg is None:
                    # keep listening; ws.receive returns None when no message
                    continue
            except TypeError:
                # Some versions of flask_sock/ws may raise TypeError for timeout param; ignore
                time.sleep(0.1)
            except ConnectionClosed:
                break
            except Exception:
                # ignore other receive issues; continue to allow push-only sockets
                time.sleep(0.1)

    finally:
        with _lock:
            try:
                ws_clients.remove(ws)
            except ValueError:
                pass
        print("🔴 WebSocket client disconnected (remaining: {})".format(len(ws_clients)))


# ---------------------------------------------
# SIMULATOR THREAD: move cab -> pickup -> wait -> destination
# ---------------------------------------------
def simulate_cab_movements():
    """Run in a daemon thread: read DB, move cabs that have active_cab_targets, broadcast updates."""
    print("🚗 Simulator thread started.")
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
                    dist = (dlat ** 2 + dlon ** 2) ** 0.5

                    ARRIVE_THRESHOLD = 0.00025

                    if dist < ARRIVE_THRESHOLD:
                        # reached target
                        if phase == 'to_pickup':
                            print(f"✅ Cab {cab_id} reached pickup.")
                            # mark status Arrived and update DB position
                            db.update_cab_status(cab_id, 'Arrived', latitude=target_lat, longitude=target_lng)
                            try:
                                db.update_cab_location(cab_id, target_lat, target_lng)
                            except Exception:
                                pass

                            # broadcast arrived at pickup
                            broadcast_to_all({
                                'cab_id': cab_id,
                                'latitude': target_lat,
                                'longitude': target_lng,
                                'status': 'Arrived'
                            })

                            # IMPORTANT: DO NOT delete target; wait for client to call /api/start_ride
                            # Optionally the client may call /api/start_ride to switch to destination.

                        elif phase == 'to_destination':
                            print(f"🏁 Cab {cab_id} reached destination.")
                            db.update_cab_status(cab_id, 'Arrived', latitude=target_lat, longitude=target_lng)
                            try:
                                db.update_cab_location(cab_id, target_lat, target_lng)
                            except Exception:
                                pass
                            broadcast_to_all({
                                'cab_id': cab_id,
                                'latitude': target_lat,
                                'longitude': target_lng,
                                'status': 'ArrivedDestination'
                            })
                            # DO NOT remove active target here - wait for /api/complete_ride
                    else:
                        # move a small step toward target
                        step = 0.00025
                        lat += step * (dlat / dist)
                        lon += step * (dlon / dist)
                        # update DB
                        try:
                            db.update_cab_location(cab_id, lat, lon, status=status if status else None)
                        except Exception:
                            try:
                                db.update_cab_location(cab_id, lat, lon)
                            except Exception:
                                pass

                        # set broadcast status string
                        broadcast_status = 'Enroute' if phase == 'to_pickup' else 'OnTrip'
                        updates.append({
                            'cab_id': cab_id,
                            'latitude': lat,
                            'longitude': lon,
                            'status': broadcast_status
                        })
                else:
                    # idle minor movement
                    if status == 'Available':
                        lat += random.uniform(-0.00015, 0.00015)
                        lon += random.uniform(-0.00015, 0.00015)
                        try:
                            db.update_cab_location(cab_id, lat, lon)
                        except Exception:
                            pass
                    updates.append({
                        'cab_id': cab_id,
                        'latitude': lat,
                        'longitude': lon,
                        'status': status
                    })

            # broadcast updates to connected websocket clients
            if updates:
                for u in updates:
                    broadcast_to_all(u)

        except Exception as e:
            print("💥 Simulator loop error:", e)

        # sleep between iterations
        time.sleep(2)


# Spawn simulator thread at import so it runs under Uvicorn/Gunicorn worker
_sim_thread = threading.Thread(target=simulate_cab_movements, daemon=True)
try:
    _sim_thread.start()
    print("🟢 Simulator thread spawned.")
except Exception as e:
    print("⚠️ Failed to spawn simulator thread:", e)


# ---------------------------------------------
# RUN (Do NOT call app.run here - use uvicorn in production)
# ---------------------------------------------
# NOTE: When deploying on Render, use Uvicorn to serve this app:
# uvicorn app:app --host 0.0.0.0 --port $PORT
