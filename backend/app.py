# /backend/app.py
import json
import random
import threading
import time
from typing import Dict, List, Any

from flask import Flask, request, jsonify
from flask_cors import CORS
from flask_sock import Sock, ConnectionClosed
from asgiref.wsgi import WsgiToAsgi
from dotenv import load_dotenv

# Your project imports (DB, helpers)
from dsa.db_utils import DatabaseUtils
from dsa.heap_utils import CabFinder
from dsa.utils import calculate_distance, calculate_fare

load_dotenv()

# -------------------------
# Flask + Sock initialization
# -------------------------
app = Flask(__name__)
CORS(app)
sock = Sock(app)

# Database helper (assumes your DatabaseUtils implementation exists)
db = DatabaseUtils(db_path="database.db")

# Thread-safe storage
_clients_lock = threading.Lock()
_ws_clients: List[Any] = []  # actual websocket objects from flask-sock

# active targets: cab_id -> { target_lat, target_lng, phase: 'to_pickup'|'to_destination' }
_active_targets_lock = threading.Lock()
active_cab_targets: Dict[int, Dict[str, Any]] = {}

# -------------------------
# Helpers
# -------------------------
def log(*args, **kwargs):
    print("[backend]", *args, **kwargs)


def broadcast_to_all(message: dict):
    """Send a JSON message to all connected WS clients (removes dead ones)."""
    text = json.dumps(message)
    dead = []
    with _clients_lock:
        for ws in list(_ws_clients):
            try:
                ws.send(text)
            except ConnectionClosed:
                dead.append(ws)
            except Exception as e:
                # if sending fails, drop client to keep things healthy
                log("⚠️ Broadcast send failed:", e)
                dead.append(ws)
        for ws in dead:
            try:
                _ws_clients.remove(ws)
            except ValueError:
                pass


# -------------------------
# HTTP API endpoints
# -------------------------
@app.route("/api/cabs", methods=["GET"])
def api_get_cabs():
    try:
        cabs = db.get_all_cabs()
        return jsonify(cabs)
    except Exception as e:
        log("Error in /api/cabs:", e)
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

        # mark busy
        db.update_cab_status(cab_id, "Busy")
        # store ride
        db.add_ride(cab_id, start_lat, start_lng, end_lat, end_lng, is_shared)

        # set active target -> pickup
        with _active_targets_lock:
            active_cab_targets[cab_id] = {
                "target_lat": start_lat,
                "target_lng": start_lng,
                "phase": "to_pickup"
            }

        log(f"Booked cab {cab_id} -> moving to pickup {start_lat},{start_lng}")
        broadcast_to_all({
            "cab_id": cab_id,
            "status": "Enroute",
            "target_lat": start_lat,
            "target_lng": start_lng
        })

        # calculate fare to return
        dist_km = calculate_distance(start_lat, start_lng, end_lat, end_lng)
        fare = calculate_fare(dist_km)

        return jsonify({
            "message": "Ride booked successfully",
            "cab": cab,
            "cab_id": cab_id,
            "status": "Enroute to Pickup",
            "fare": fare,
            "start_latitude": start_lat,
            "start_longitude": start_lng,
            "end_latitude": end_lat,
            "end_longitude": end_lng,
            "is_shared": is_shared
        }), 200

    except Exception as e:
        log("Error in /api/book_cab:", e)
        return jsonify({"error": str(e)}), 500


@app.route("/api/start_ride/<int:cab_id>", methods=["POST"])
def api_start_ride(cab_id: int):
    """
    Called by client after driver has arrived and passenger confirmed boarding.
    Switch target to destination and set status OnTrip.
    """
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
    """
    Mark the ride completed: set cab Available, update location to destination, remove active target
    """
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
                # fallback: try raw values
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


# -------------------------
# WebSocket route (flask-sock)
# -------------------------
@sock.route("/cab_location_updates")
def ws_cab_updates(ws):
    """
    Accept WebSocket connections and keep them in _ws_clients list for server-side pushes.
    We run a small receive loop to detect closed connections; sending is done by broadcast_to_all().
    """
    log("WS client connected")
    with _clients_lock:
        _ws_clients.append(ws)

    try:
        # Try to read messages (if any); this also helps detect client disconnects.
        while True:
            try:
                # some flask-sock implementations support a timeout param. We'll try it and ignore if not supported.
                msg = None
                try:
                    msg = ws.receive(timeout=5)
                except TypeError:
                    # receive() may not accept timeout; call without it (blocking) but only if client actually sends.
                    msg = ws.receive()
                if msg is None:
                    # no message received (timeout) — continue; keep connection alive
                    continue
                # Optionally handle inbound messages from client if needed
                # log("WS received:", msg)
            except ConnectionClosed:
                break
            except Exception:
                # keep loop alive; if ws becomes invalid, send on broadcast will remove it
                time.sleep(0.1)
    finally:
        with _clients_lock:
            try:
                _ws_clients.remove(ws)
            except ValueError:
                pass
        log("WS client disconnected")


# -------------------------
# Simulator thread
# -------------------------
def simulate_cab_movements_thread():
    """
    Background simulator that:
      - moves cabs toward active targets (pickup or destination)
      - updates DB location
      - broadcasts live updates to connected clients
    """
    log("Simulator started")
    SLEEP_INTERVAL = 2.0
    ARRIVE_THRESHOLD = 0.00025
    STEP = 0.00025

    while True:
        try:
            cabs = db.get_all_cabs()
            updates = []

            for c in cabs:
                try:
                    cab_id = int(c["cab_id"])
                    lat = float(c.get("latitude", 0.0))
                    lng = float(c.get("longitude", 0.0))
                    status = c.get("status", "Available")
                except Exception:
                    continue

                moved = False

                with _active_targets_lock:
                    target_info = active_cab_targets.get(cab_id)

                if target_info:
                    target_lat = float(target_info["target_lat"])
                    target_lng = float(target_info["target_lng"])
                    phase = target_info.get("phase", "to_pickup")

                    dlat = target_lat - lat
                    dlng = target_lng - lng
                    dist = (dlat * dlat + dlng * dlng) ** 0.5

                    if dist <= ARRIVE_THRESHOLD:
                        # arrived at target
                        if phase == "to_pickup":
                            log(f"Cab {cab_id} reached pickup")
                            db.update_cab_status(cab_id, "Arrived", latitude=target_lat, longitude=target_lng)
                            # keep target until client calls /start_ride (per Option A)
                            # broadcast arrival
                            broadcast_to_all({
                                "cab_id": cab_id,
                                "status": "Arrived",
                                "latitude": target_lat,
                                "longitude": target_lng
                            })
                        elif phase == "to_destination":
                            log(f"Cab {cab_id} reached destination")
                            db.update_cab_status(cab_id, "Arrived", latitude=target_lat, longitude=target_lng)
                            db.update_cab_location(cab_id, target_lat, target_lng)
                            broadcast_to_all({
                                "cab_id": cab_id,
                                "status": "ArrivedDestination",
                                "latitude": target_lat,
                                "longitude": target_lng
                            })
                        moved = False
                    else:
                        # step toward target
                        lat += STEP * (dlat / dist)
                        lng += STEP * (dlng / dist)
                        try:
                            db.update_cab_location(cab_id, lat, lng)
                        except Exception:
                            pass
                        moved = True
                        updates.append({
                            "cab_id": cab_id,
                            "latitude": lat,
                            "longitude": lng,
                            "status": "Enroute" if phase == "to_pickup" else "OnTrip"
                        })

                else:
                    # idle small drift
                    if status == "Available":
                        lat += random.uniform(-0.00015, 0.00015)
                        lng += random.uniform(-0.00015, 0.00015)
                        try:
                            db.update_cab_location(cab_id, lat, lng)
                        except Exception:
                            pass
                    updates.append({
                        "cab_id": cab_id,
                        "latitude": lat,
                        "longitude": lng,
                        "status": status
                    })

            # broadcast batched updates
            for u in updates:
                broadcast_to_all(u)

        except Exception as e:
            log("Simulator loop error:", e)

        time.sleep(SLEEP_INTERVAL)


# Start simulator thread (daemon)
_sim_thread = threading.Thread(target=simulate_cab_movements_thread, daemon=True)
_sim_thread.start()
log("Simulator thread spawned")


# -------------------------
# ASGI wrapper for uvicorn/Render
# -------------------------
asgi_app = WsgiToAsgi(app)

# if you run locally with python backend/app.py, this will not be used in deployment.
if __name__ == "__main__":
    # Local quick-run for convenience (still WSGI)
    from werkzeug.serving import run_simple
    log("Starting local development server on http://127.0.0.1:5001")
    run_simple("0.0.0.0", 5001, app, use_reloader=True, threaded=True)
