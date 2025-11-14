from flask import Flask, request, jsonify
from dotenv import load_dotenv
from flask_cors import CORS
from flask_sockets import Sockets
import json
import random
import gevent
from gevent import spawn
from dsa.db_utils import DatabaseUtils
from dsa.heap_utils import CabFinder
from dsa.utils import calculate_distance, calculate_fare

# --------------------------------------------------
# INITIALIZATION
# --------------------------------------------------
load_dotenv()
app = Flask(__name__)
CORS(app)

# Flask-Sockets (WebSocket support)
sockets = Sockets(app)

# DB
db = DatabaseUtils(db_path='database.db')

clients = []                   # WebSocket clients
active_cab_targets = {}        # cab_id -> target location


# --------------------------------------------------
# API: Get all cabs
# --------------------------------------------------
@app.route('/api/cabs', methods=['GET'])
def get_cabs():
    return jsonify(db.get_all_cabs())


# --------------------------------------------------
# API: Register or update cab
# --------------------------------------------------
@app.route('/api/cab_register', methods=['POST'])
def cab_register():
    data = request.get_json()

    required = ["cab_id", "name", "rto_number", "driver_name",
                "latitude", "longitude"]
    if not all(k in data for k in required):
        return jsonify({"error": "Missing cab data"}), 400

    try:
        conn = db.connect()
        cursor = conn.cursor()
        cursor.execute("""
            INSERT OR REPLACE INTO cabs
            (cab_id, name, rto_number, driver_name, latitude, longitude, status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, (
            data["cab_id"], data["name"], data["rto_number"],
            data["driver_name"], data["latitude"], data["longitude"],
            data.get("status", "Available")
        ))
        conn.commit()
        return jsonify({"message": "Cab saved"}), 201

    except Exception as e:
        conn.rollback()
        return jsonify({"error": str(e)}), 500

    finally:
        db.disconnect()


# --------------------------------------------------
# WEBSOCKET: Location updates channel
# --------------------------------------------------
@sockets.route('/cab_location_updates')
def cab_location_updates(ws):
    print("🟢 WebSocket connected")
    clients.append(ws)

    while not ws.closed:
        gevent.sleep(0.1)

    print("🔴 WebSocket disconnected")
    if ws in clients:
        clients.remove(ws)


# --------------------------------------------------
# API: Find nearest cab
# --------------------------------------------------
@app.route('/api/find_cab', methods=['POST'])
def find_cab():
    data = request.json

    keys = ["start_latitude", "start_longitude",
            "end_latitude", "end_longitude"]

    if not all(k in data for k in keys):
        return jsonify({"error": "Missing coordinates"}), 400

    start_lat = data["start_latitude"]
    start_lng = data["start_longitude"]
    end_lat = data["end_latitude"]
    end_lng = data["end_longitude"]

    cabs = db.get_all_cabs()
    nearest = CabFinder.find_nearest_cab(cabs, start_lat, start_lng, num_cabs=3)

    if not nearest:
        return jsonify({"error": "No cabs available"}), 404

    results = []
    for cab, dist_km in nearest:
        total_dist_km = calculate_distance(start_lat, start_lng, end_lat, end_lng)
        fare = calculate_fare(total_dist_km)

        results.append({
            "cab": cab,
            "pickup_distance": dist_km * 1000,
            "total_distance": total_dist_km * 1000,
            "fare": fare,
            "is_shared": False,
            "status": "Available"
        })

    results.sort(key=lambda x: x["pickup_distance"])
    return jsonify({"available_cabs": results})


# --------------------------------------------------
# API: Book cab
# --------------------------------------------------
@app.route('/api/book_cab', methods=['POST'])
def book_cab():
    data = request.json
    required = [
        "cab_id", "start_latitude", "start_longitude",
        "end_latitude", "end_longitude"
    ]

    if not all(k in data for k in required):
        return jsonify({"error": "Missing booking info"}), 400

    cab_id = data["cab_id"]
    start_lat = data["start_latitude"]
    start_lng = data["start_longitude"]
    end_lat = data["end_latitude"]
    end_lng = data["end_longitude"]
    is_shared = data.get("is_shared", False)

    cabs = db.get_all_cabs()
    cab = next((c for c in cabs if c["cab_id"] == cab_id), None)

    if not cab:
        return jsonify({"error": "Cab not found"}), 404

    db.update_cab_status(cab_id, "Busy")

    dist = calculate_distance(start_lat, start_lng, end_lat, end_lng)
    fare = calculate_fare(dist)

    db.add_ride(cab_id, start_lat, start_lng, end_lat, end_lng, is_shared)

    # assign movement target (pickup location)
    active_cab_targets[cab_id] = {
        "target_lat": start_lat,
        "target_lng": start_lng,
        "stage": "to_pickup"
    }

    return jsonify({
        "message": "Ride booked",
        "cab": cab,
        "cab_id": cab_id,
        "status": "Enroute",
        "fare": fare
    })


# --------------------------------------------------
# API: Complete ride
# --------------------------------------------------
@app.route('/api/complete_ride/<int:cab_id>', methods=['GET'])
def complete_ride(cab_id):
    try:
        updated = db.update_cab_status(cab_id, "Available")
        if not updated:
            return jsonify({"error": "Update failed"}), 400

        ride = db.get_ride_by_cab_id(cab_id)

        dest_lat = ride["end_latitude"] if ride else None
        dest_lng = ride["end_longitude"] if ride else None

        if dest_lat and dest_lng:
            db.update_cab_location(cab_id, dest_lat, dest_lng)

        active_cab_targets.pop(cab_id, None)

        broadcast_to_all({
            "cab_id": cab_id,
            "latitude": dest_lat or 0.0,
            "longitude": dest_lng or 0.0,
            "status": "Available"
        })

        return jsonify({"message": "Cab set to Available"}), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500


# --------------------------------------------------
# SIMULATION LOOP
# --------------------------------------------------
def simulate_cab_movements():
    print("🚗 Simulator thread started.")

    while True:
        try:
            cabs = db.get_all_cabs()
            updates = []

            for c in cabs:
                cab_id = c["cab_id"]
                lat = float(c["latitude"])
                lng = float(c["longitude"])
                status = c["status"]

                # movement to pickup
                if cab_id in active_cab_targets:
                    t = active_cab_targets[cab_id]
                    target_lat = float(t["target_lat"])
                    target_lng = float(t["target_lng"])

                    dlat = target_lat - lat
                    dlng = target_lng - lng
                    dist = (dlat*dlat + dlng*dlng)**0.5

                    if dist < 0.00025:
                        db.update_cab_status(cab_id, "Arrived")
                        active_cab_targets.pop(cab_id, None)

                        broadcast_to_all({
                            "cab_id": cab_id,
                            "status": "Arrived"
                        })
                    else:
                        step = 0.0002
                        lat += step * (dlat/dist)
                        lng += step * (dlng/dist)
                        db.update_cab_location(cab_id, lat, lng, status)

                else:
                    # idle drift
                    if status == "Available":
                        lat += random.uniform(-0.00015, 0.00015)
                        lng += random.uniform(-0.00015, 0.00015)
                        db.update_cab_location(cab_id, lat, lng, status)

                updates.append({
                    "cab_id": cab_id,
                    "latitude": lat,
                    "longitude": lng,
                    "status": status
                })

            # broadcast updates
            broadcast_to_all_list(updates)

        except Exception as e:
            print("💥 Simulation error:", e)

        gevent.sleep(2)


def broadcast_to_all(message):
    """Broadcast single update."""
    dead = []
    for ws in clients:
        if ws.closed:
            dead.append(ws)
        else:
            try:
                ws.send(json.dumps(message))
            except:
                dead.append(ws)

    for ws in dead:
        clients.remove(ws)


def broadcast_to_all_list(messages):
    """Broadcast list of updates."""
    for m in messages:
        broadcast_to_all(m)


# --------------------------------------------------
# START SIMULATOR THREAD
# --------------------------------------------------
spawn(simulate_cab_movements)
print("🟢 Simulator thread spawned.")


# --------------------------------------------------
# ASGI wrapper for Render
# --------------------------------------------------
from asgiref.wsgi import WsgiToAsgi
asgi_app = WsgiToAsgi(app)
