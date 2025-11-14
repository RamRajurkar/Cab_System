# /backend/app.py
import json
import random
import threading
import time
from typing import Any, Dict, List

from flask import Flask, request, jsonify
from flask_cors import CORS
from flask_sock import Sock, ConnectionClosed
from asgiref.wsgi import WsgiToAsgi
from dotenv import load_dotenv

from dsa.db_utils import DatabaseUtils
from dsa.heap_utils import CabFinder
from dsa.utils import calculate_distance, calculate_fare

load_dotenv()

# -------------------------------------
# Flask + Sock setup
# -------------------------------------
app = Flask(__name__)
CORS(app)
sock = Sock(app)

# Database helper (uses per-call connections; thread-safe)
db = DatabaseUtils(db_path="database.db")

# Thread-safe websocket client list
_ws_clients_lock = threading.Lock()
_ws_clients: List[Any] = []

# Active targets: cab_id -> { target_lat, target_lng, phase }
_active_targets_lock = threading.Lock()
active_cab_targets: Dict[int, Dict[str, Any]] = {}

# Simulator control
_SIM_SLEEP = 2.0
_ARRIVE_THRESHOLD = 0.00025
_STEP = 0.00025


def log(*args, **kwargs):
    print("[backend]", *args, **kwargs)


# -------------------------------------
# Broadcast utilities
# -------------------------------------
def broadcast_to_all(message: dict):
    text = json.dumps(message)
    dead: List[Any] = []
    with _ws_clients_lock:
        for ws in list(_ws_clients):
            try:
                ws.send(text)
            except ConnectionClosed:
                dead.append(ws)
            except Exception as e:
                log("⚠ broadcast send failed:", e)
                dead.append(ws)
        for ws in dead:
            try:
                _ws_clients.remove(ws)
            except ValueError:
                pass


# -------------------------------------
# HTTP API endpoints
# -------------------------------------
@app.route("/api/cabs", methods=["GET"])
def api_get_cabs():
    try:
        cabs = db.get_all_cabs()
        return jsonify(cabs)
    except Exception as e:
        log("Error in /api/cabs:", e)
        return jsonify({"error": str(e)}), 500


@app.route("/api/cab_register", methods=["POST"])
def api_cab_register():
    data = request.get_json() or {}
    required = ["cab_id", "name", "rto_number", "driver_name", "latitude", "longitude"]
    if not all(k in data for k in required):
        return jsonify({"error": "Missing cab data"}), 400

    try:
        cab_id = int(data["cab_id"])
        name = data["name"]
        rto = data["rto_number"]
        driver = data["driver_name"]
        lat = float(data["latitude"])
        lng = float(data["longitude"])
        status = data.get("status", "Available")

        ok = db.add_cab(cab_id, name, rto, driver, lat, lng, status)
        if ok:
            return jsonify({"message": "Cab registered/updated"}), 201
        return jsonify({"error": "DB insert failed"}), 500
    except Exception as e:
        log("Error in /api/cab_register:", e)
        return jsonify({"error": str(e)}), 500


@app.route("/api/find_cab", methods=["POST"])
def api_find_cab():
    data = request.json or {}
    required = ["start_latitude", "start_longitude", "end_latitude", "end_longitude"]
    if not all(k in data for k in required):
        return jsonify({"error": "Missing coordinates"}), 400

    try:
        start_lat = float(data["start_latitude"])
        start_lng = float(data["start_longitude"])
        end_lat = float(data["end_latitude"])
        end_lng = float(data["end_longitude"])

        cabs = db.get_all_cabs()
        nearest = CabFinder.find_nearest_cab(cabs, start_lat, start_lng, num_cabs=3)
        if not nearest:
            return jsonify({"error": "No cabs available"}), 404

        options = []
        for cab, dist_km in nearest:
            total_km = calculate_distance(start_lat, start_lng, end_lat, end_lng)
            fare = calculate_fare(total_km)
            options.append({
                "cab": cab,
                "pickup_distance": dist_km * 1000,
                "total_distance": total_km * 1000,
                "fare": fare,
                "is_shared": False,
                "status": cab.get("status", "Available"),
            })

        options.sort(key=lambda x: x["pickup_distance"])
        return jsonify({"available_cabs": options[:3]})

    except Exception as e:
        log("Error in /api/find_cab:", e)
        return jsonify({"error": str(e)}), 500


@app.route("/api/book_cab", methods=["POST"])
def api_book_cab():
    data = request.json or {}
    required = ["cab_id", "start_latitude", "start_longitude", "end_latitude", "end_longitude"]
    if not all(k in data for k in required):
        return jsonify({"error": "Missing booking info"}), 400

    try:
        cab_id = int(data["cab_id"])
        start_lat = float(data["start_latitude"])
        start_lng = float(data["start_longitude"])
        end_lat = float(data["end_latitude"])
        end_lng = float(data["end_longitude"])
        is_shared = bool(data.get("is_shared", False))

        cabs = db.get_all_cabs()
        cab = next((c for c in cabs if int(c["cab_id"]) == cab_id), None)
        if not cab:
            return jsonify({"error": f"Cab {cab_id} not found"}), 404

        db.update_cab_status(cab_id, "Busy")
        db.add_ride(cab_id, start_lat, start_lng, end_lat, end_lng, is_shared)

        with _active_targets_lock:
            active_cab_targets[cab_id] = {
                "target_lat": start_lat,
                "target_lng": start_lng,
                "phase": "to_pickup"
            }

        broadcast_to_all({
            "cab_id": cab_id,
            "status": "Enroute",
            "target_lat": start_lat,
            "target_lng": start_lng
        })

        dist_km = calculate_distance(start_lat, start_lng, end_lat, end_lng)
        fare = calculate_fare(dist_km)

        return jsonify({
            "message": "Ride booked successfully",
            "cab": cab,
            "cab_id": cab_id,
            "status": "Enroute to Pickup",
            "fare": fare
        }), 200

    except Exception as e:
        log("Error in /api/book_cab:", e)
        return jsonify({"error": str(e)}), 500


@app.route("/api/start_ride/<int:cab_id>", methods=["POST"])
def api_start_ride(cab_id: int):
    try:
        ride = db.get_ride_by_cab_id(cab_id)
        if not ride:
            return jsonify({"error": "No ride found for cab"}), 404

        end_lat = ride.get("end_latitude")
        end_lng = ride.get("end_longitude")
        if end_lat is None or end_lng is None:
            return jsonify({"error": "Invalid ride destination"}), 400

        with _active_targets_lock:
            active_cab_targets[cab_id] = {
                "target_lat": float(end_lat),
                "target_lng": float(end_lng),
                "phase": "to_destination"
            }

        db.update_cab_status(cab_id, "OnTrip")
        broadcast_to_all({
            "cab_id": cab_id,
            "status": "OnTrip",
            "target_lat": float(end_lat),
            "target_lng": float(end_lng)
        })
        return jsonify({"message": "Ride started"}), 200

    except Exception as e:
        log("Error in /api/start_ride:", e)
        return jsonify({"error": str(e)}), 500


@app.route("/api/complete_ride/<int:cab_id>", methods=["GET"])
def api_complete_ride(cab_id: int):
    try:
        updated = db.update_cab_status(cab_id, "Available")
        if not updated:
            return jsonify({"error": "Failed to update cab status"}), 400

        ride = db.get_ride_by_cab_id(cab_id)
        dest_lat = ride.get("end_latitude") if ride else None
        dest_lng = ride.get("end_longitude") if ride else None

        if dest_lat is not None and dest_lng is not None:
            try:
                db.update_cab_location(cab_id, float(dest_lat), float(dest_lng))
            except Exception:
                try:
                    db.update_cab_location(cab_id, dest_lat, dest_lng)
                except Exception:
                    pass

        with _active_targets_lock:
            active_cab_targets.pop(cab_id, None)

        broadcast_to_all({
            "cab_id": cab_id,
            "status": "Available",
            "latitude": float(dest_lat) if dest_lat else 0.0,
            "longitude": float(dest_lng) if dest_lng else 0.0
        })

        return jsonify({"message": f"Cab {cab_id} set to Available"}), 200

    except Exception as e:
        log("Error in /api/complete_ride:", e)
        return jsonify({"error": str(e)}), 500


# -------------------------------------
# WebSocket route (flask-sock)
# -------------------------------------
@sock.route("/cab_location_updates")
def ws_cab_updates(ws):
    log("WS client connected")
    with _ws_clients_lock:
        _ws_clients.append(ws)

    try:
        while True:
            try:
                # Non-blocking receive pattern if supported; otherwise block until message
                try:
                    msg = ws.receive(timeout=5)
                except TypeError:
                    msg = ws.receive()
                if msg is None:
                    continue
                # optional: process inbound messages if needed
            except ConnectionClosed:
                break
            except Exception:
                time.sleep(0.1)
    finally:
        with _ws_clients_lock:
            try:
                _ws_clients.remove(ws)
            except ValueError:
                pass
        log("WS client disconnected")


# -------------------------------------
# Background simulator (thread)
# -------------------------------------
def simulate_cab_movements_thread():
    log("Simulator started")
    while True:
        try:
            cabs = db.get_all_cabs()
            updates: List[Dict[str, Any]] = []

            for c in cabs:
                try:
                    cab_id = int(c["cab_id"])
                    lat = float(c.get("latitude", 0.0))
                    lng = float(c.get("longitude", 0.0))
                    status = c.get("status", "Available")
                except Exception:
                    continue

                with _active_targets_lock:
                    target_info = active_cab_targets.get(cab_id)

                if target_info:
                    tlat = float(target_info["target_lat"])
                    tlng = float(target_info["target_lng"])
                    phase = target_info.get("phase", "to_pickup")

                    dlat = tlat - lat
                    dlng = tlng - lng
                    dist = (dlat * dlat + dlng * dlng) ** 0.5

                    if dist <= _ARRIVE_THRESHOLD:
                        if phase == "to_pickup":
                            log(f"Cab {cab_id} reached pickup")
                            db.update_cab_status(cab_id, "Arrived", latitude=tlat, longitude=tlng)
                            # keep target until client calls start_ride
                            broadcast_to_all({"cab_id": cab_id, "status": "Arrived", "latitude": tlat, "longitude": tlng})
                        else:
                            log(f"Cab {cab_id} reached destination")
                            db.update_cab_status(cab_id, "Arrived", latitude=tlat, longitude=tlng)
                            db.update_cab_location(cab_id, tlat, tlng)
                            broadcast_to_all({"cab_id": cab_id, "status": "ArrivedDestination", "latitude": tlat, "longitude": tlng})
                    else:
                        # move step
                        lat += _STEP * (dlat / dist)
                        lng += _STEP * (dlng / dist)
                        try:
                            db.update_cab_location(cab_id, lat, lng)
                        except Exception:
                            pass
                        updates.append({"cab_id": cab_id, "latitude": lat, "longitude": lng, "status": "Enroute" if phase == "to_pickup" else "OnTrip"})
                else:
                    # idle drift
                    if status == "Available":
                        lat += random.uniform(-0.00015, 0.00015)
                        lng += random.uniform(-0.00015, 0.00015)
                        try:
                            db.update_cab_location(cab_id, lat, lng)
                        except Exception:
                            pass
                    updates.append({"cab_id": cab_id, "latitude": lat, "longitude": lng, "status": status})

            # broadcast
            for u in updates:
                broadcast_to_all(u)

        except Exception as e:
            log("Simulator error:", e)

        time.sleep(_SIM_SLEEP)


# Start simulator thread
_sim_thread = threading.Thread(target=simulate_cab_movements_thread, daemon=True)
_sim_thread.start()
log("Simulator thread spawned")


# ASGI wrapper for uvicorn/render
asgi_app = WsgiToAsgi(app)


# Local running convenience
if __name__ == "__main__":
    log("Starting local dev server at http://127.0.0.1:5001 (WSGI)")
    app.run(host="0.0.0.0", port=5001, debug=True)
