import json
import random
import gevent
from gevent import spawn
from flask import Flask, request, jsonify
from flask_cors import CORS
from flask_sockets import Sockets
from dotenv import load_dotenv

from dsa.db_utils import DatabaseUtils
from dsa.heap_utils import CabFinder
from dsa.utils import calculate_distance, calculate_fare

# -----------------------------------------------------------------------------
# INIT
# -----------------------------------------------------------------------------
load_dotenv()

app = Flask(__name__)
CORS(app)

sockets = Sockets(app)        # WebSocket handler
db = DatabaseUtils("database.db")

clients = []                  # connected WS clients
active_cab_targets = {}       # cab_id → movement target


# -----------------------------------------------------------------------------
# WS BROADCAST HELPERS
# -----------------------------------------------------------------------------
def ws_broadcast(message: dict):
    dead = []
    for ws in clients:
        if ws.closed:
            dead.append(ws)
            continue
        try:
            ws.send(json.dumps(message))
        except:
            dead.append(ws)

    for ws in dead:
        clients.remove(ws)


def ws_broadcast_list(messages: list):
    for msg in messages:
        ws_broadcast(msg)


# -----------------------------------------------------------------------------
# WEBSOCKET ENDPOINT
# -----------------------------------------------------------------------------
@sockets.route("/cab_location_updates")
def cab_location_updates(ws):
    print("🟢 WS Connected")
    clients.append(ws)

    while not ws.closed:
        gevent.sleep(0.1)

    print("🔴 WS Disconnected")
    if ws in clients:
        clients.remove(ws)


# -----------------------------------------------------------------------------
# GET ALL CABS
# -----------------------------------------------------------------------------
@app.route("/api/cabs", methods=["GET"])
def get_cabs():
    return jsonify(db.get_all_cabs())


# -----------------------------------------------------------------------------
# CAB REGISTER / UPDATE
# -----------------------------------------------------------------------------
@app.route("/api/cab_register", methods=["POST"])
def cab_register():
    data = request.json
    required = ["cab_id", "name", "rto_number", "driver_name", "latitude", "longitude"]

    if not all(k in data for k in required):
        return jsonify({"error": "Missing cab data"}), 400

    try:
        db.add_cab(
            data["cab_id"],
            data["name"],
            data["rto_number"],
            data["driver_name"],
            data["latitude"],
            data["longitude"],
            data.get("status", "Available"),
        )
        return jsonify({"message": "Cab saved"}), 201
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# -----------------------------------------------------------------------------
# FIND CAB
# -----------------------------------------------------------------------------
@app.route("/api/find_cab", methods=["POST"])
def find_cab():
    data = request.json
    required = ["start_latitude", "start_longitude", "end_latitude", "end_longitude"]

    if not all(k in data for k in required):
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
    for cab, pickup_dist in nearest:
        total_dist = calculate_distance(start_lat, start_lng, end_lat, end_lng)
        fare = calculate_fare(total_dist)

        results.append({
            "cab": cab,
            "pickup_distance": pickup_dist * 1000,
            "total_distance": total_dist * 1000,
            "fare": fare,
            "status": cab["status"],
            "is_shared": False
        })

    results.sort(key=lambda x: x["pickup_distance"])
    return jsonify({"available_cabs": results})


# -----------------------------------------------------------------------------
# BOOK CAB
# -----------------------------------------------------------------------------
@app.route("/api/book_cab", methods=["POST"])
def book_cab():
    data = request.json
    required = ["cab_id", "start_latitude", "start_longitude", "end_latitude", "end_longitude"]

    if not all(k in data for k in required):
        return jsonify({"error": "Missing booking data"}), 400

    cab_id = data["cab_id"]
    s_lat = data["start_latitude"]
    s_lng = data["start_longitude"]
    e_lat = data["end_latitude"]
    e_lng = data["end_longitude"]
    is_shared = data.get("is_shared", False)

    cab = next((c for c in db.get_all_cabs() if c["cab_id"] == cab_id), None)
    if not cab:
        return jsonify({"error": "Cab not found"}), 404

    db.update_cab_status(cab_id, "Busy")
    db.add_ride(cab_id, s_lat, s_lng, e_lat, e_lng, is_shared)

    active_cab_targets[cab_id] = {
        "target_lat": s_lat,
        "target_lng": s_lng,
        "stage": "pickup"
    }

    return jsonify({"message": "Ride booked", "cab_id": cab_id, "status": "Enroute"})


# -----------------------------------------------------------------------------
# COMPLETE RIDE
# -----------------------------------------------------------------------------
@app.route("/api/complete_ride/<int:cab_id>", methods=["GET"])
def complete_ride(cab_id):
    db.update_cab_status(cab_id, "Available")
    ride = db.get_ride_by_cab_id(cab_id)

    if ride:
        db.update_cab_location(cab_id, ride["end_latitude"], ride["end_longitude"])

    active_cab_targets.pop(cab_id, None)

    ws_broadcast({
        "cab_id": cab_id,
        "status": "Available"
    })

    return jsonify({"message": f"Cab {cab_id} set to Available"})


# -----------------------------------------------------------------------------
# CAB SIMULATION LOOP
# -----------------------------------------------------------------------------
def simulate_cabs():
    print("🚗 Simulator running...")

    while True:
        try:
            cabs = db.get_all_cabs()
            updates = []

            for cab in cabs:
                cid = cab["cab_id"]
                lat = float(cab["latitude"])
                lng = float(cab["longitude"])
                status = cab["status"]

                # Moving to pickup destination
                if cid in active_cab_targets:
                    t = active_cab_targets[cid]
                    tlat = float(t["target_lat"])
                    tlng = float(t["target_lng"])

                    dx = tlat - lat
                    dy = tlng - lng
                    dist = (dx * dx + dy * dy) ** 0.5

                    if dist < 0.00025:
                        db.update_cab_status(cid, "Arrived")
                        active_cab_targets.pop(cid, None)

                        ws_broadcast({"cab_id": cid, "status": "Arrived"})
                    else:
                        step = 0.0002
                        lat += step * (dx / dist)
                        lng += step * (dy / dist)
                        db.update_cab_location(cid, lat, lng, status)

                updates.append({
                    "cab_id": cid,
                    "latitude": lat,
                    "longitude": lng,
                    "status": status
                })

            ws_broadcast_list(updates)

        except Exception as e:
            print("Simulation error:", e)

        gevent.sleep(2)


# Start simulator
spawn(simulate_cabs)
print("🟢 Simulator thread started")
