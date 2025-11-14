from flask import Flask, request, jsonify
from flask_cors import CORS
from flask_sock import Sock
from dotenv import load_dotenv
import json
import random
import threading
import time

from dsa.db_utils import DatabaseUtils
from dsa.heap_utils import CabFinder
from dsa.utils import calculate_distance, calculate_fare

# ------------------------------------------------------------------
# INITIAL SETUP
# ------------------------------------------------------------------
load_dotenv()

app = Flask(__name__)
CORS(app)

# WebSocket (flask-sock)
sock = Sock(app)

# Database
db = DatabaseUtils(db_path='database.db')

# Connected WebSocket clients
ws_clients = []

# cab_id → {target_lat, target_lng, stage}
active_cab_targets = {}

print("[backend] Simulator loaded")


# ------------------------------------------------------------------
# WEBSOCKET ENDPOINT
# ------------------------------------------------------------------
@sock.route('/cab_location_updates')
def cab_location_updates(ws):
    print("🟢 WebSocket client connected")
    ws_clients.append(ws)

    try:
        while True:
            message = ws.receive()
            if message is None:
                break
    except Exception:
        pass
    finally:
        print("🔴 WebSocket disconnected")
        if ws in ws_clients:
            ws_clients.remove(ws)


# Broadcast utility
def ws_broadcast(message: dict):
    dead = []
    for client in ws_clients:
        try:
            client.send(json.dumps(message))
        except:
            dead.append(client)

    for d in dead:
        if d in ws_clients:
            ws_clients.remove(d)


# ------------------------------------------------------------------
# REST API: Get all cabs
# ------------------------------------------------------------------
@app.route('/api/cabs', methods=['GET'])
def get_cabs():
    return jsonify(db.get_all_cabs())


# ------------------------------------------------------------------
# REST API: Register cab
# ------------------------------------------------------------------
@app.route('/api/cab_register', methods=['POST'])
def cab_register():
    data = request.get_json()
    required = ["cab_id", "name", "rto_number", "driver_name", "latitude", "longitude"]

    if not all(k in data for k in required):
        return jsonify({"error": "Missing fields"}), 400

    ok = db.add_cab(
        data["cab_id"], data["name"], data["rto_number"], data["driver_name"],
        data["latitude"], data["longitude"], "Available"
    )

    if not ok:
        return jsonify({"error": "Failed"}), 500

    return jsonify({"message": "Cab registered"}), 201


# ------------------------------------------------------------------
# REST API: Find nearest cab
# ------------------------------------------------------------------
@app.route('/api/find_cab', methods=['POST'])
def find_cab():
    data = request.json
    keys = ["start_latitude", "start_longitude", "end_latitude", "end_longitude"]

    if not all(k in data for k in keys):
        return jsonify({"error": "Missing coordinates"}), 400

    cabs = db.get_all_cabs()

    nearest = CabFinder.find_nearest_cab(
        cabs,
        data["start_latitude"],
        data["start_longitude"],
        num_cabs=3
    )

    if not nearest:
        return jsonify({"error": "No cabs available"}), 404

    results = []
    for cab, dist in nearest:
        total_dist = calculate_distance(
            data["start_latitude"],
            data["start_longitude"],
            data["end_latitude"],
            data["end_longitude"]
        )
        fare = calculate_fare(total_dist)

        results.append({
            "cab": cab,
            "pickup_distance": dist * 1000,
            "fare": fare,
            "status": "Available"
        })

    return jsonify({"available_cabs": results})


# ------------------------------------------------------------------
# REST API: Book cab
# ------------------------------------------------------------------
@app.route('/api/book_cab', methods=['POST'])
def book_cab():
    data = request.json

    required = [
        "cab_id", "start_latitude", "start_longitude",
        "end_latitude", "end_longitude"
    ]
    if not all(k in data for k in required):
        return jsonify({"error": "Missing data"}), 400

    cab_id = data["cab_id"]

    db.update_cab_status(cab_id, "Busy")
    db.add_ride(
        cab_id,
        data["start_latitude"], data["start_longitude"],
        data["end_latitude"], data["end_longitude"],
        False
    )

    active_cab_targets[cab_id] = {
        "target_lat": data["start_latitude"],
        "target_lng": data["start_longitude"],
        "stage": "to_pickup"
    }

    return jsonify({"message": "Ride booked", "cab_id": cab_id})


# ------------------------------------------------------------------
# REST API: Complete Ride
# ------------------------------------------------------------------
@app.route('/api/complete_ride/<int:cab_id>', methods=['GET'])
def complete_ride(cab_id):
    db.update_cab_status(cab_id, "Available")

    ride = db.get_ride_by_cab_id(cab_id)
    dest_lat = ride["end_latitude"] if ride else 0
    dest_lng = ride["end_longitude"] if ride else 0

    db.update_cab_location(cab_id, dest_lat, dest_lng)

    if cab_id in active_cab_targets:
        active_cab_targets.pop(cab_id)

    ws_broadcast({
        "cab_id": cab_id,
        "latitude": dest_lat,
        "longitude": dest_lng,
        "status": "Available"
    })

    return jsonify({"message": "Ride Completed"})


# ------------------------------------------------------------------
# SIMULATOR (runs on separate thread)
# ------------------------------------------------------------------
def simulator_loop():
    print("[backend] Simulator started")

    while True:
        cabs = db.get_all_cabs()

        for cab in cabs:
            cab_id = cab["cab_id"]
            lat = float(cab["latitude"])
            lng = float(cab["longitude"])
            status = cab["status"]

            # Move to pickup
            if cab_id in active_cab_targets:
                t = active_cab_targets[cab_id]
                tlat, tlng = float(t["target_lat"]), float(t["target_lng"])

                dlat = tlat - lat
                dlng = tlng - lng
                dist = (dlat**2 + dlng**2) ** 0.5

                if dist < 0.00025:
                    db.update_cab_status(cab_id, "Arrived")
                    active_cab_targets.pop(cab_id)

                    ws_broadcast({"cab_id": cab_id, "status": "Arrived"})
                else:
                    step = 0.0002
                    lat += step * (dlat / dist)
                    lng += step * (dlng / dist)
                    db.update_cab_location(cab_id, lat, lng)

                ws_broadcast({
                    "cab_id": cab_id,
                    "latitude": lat,
                    "longitude": lng,
                    "status": status
                })

            # Idle drift
            elif status == "Available":
                lat += random.uniform(-0.00015, 0.00015)
                lng += random.uniform(-0.00015, 0.00015)
                db.update_cab_location(cab_id, lat, lng)

                ws_broadcast({
                    "cab_id": cab_id,
                    "latitude": lat,
                    "longitude": lng,
                    "status": status
                })

        time.sleep(2)


# Start simulation in background thread
threading.Thread(target=simulator_loop, daemon=True).start()
print("[backend] Simulator thread spawned")


# ------------------------------------------------------------------
# Entry for Hypercorn
# ------------------------------------------------------------------
if __name__ == "__main__":
    print("⚠️ Run using: hypercorn app:app --bind 0.0.0.0:5001")
