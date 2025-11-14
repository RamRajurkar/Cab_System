import sqlite3
import os

class DatabaseUtils:
    def __init__(self, db_path='../database.db'):
        self.db_path = db_path
        self.initialize_db()

    # ----------------------------------------------------
    # THREAD-SAFE CONNECTION
    # ----------------------------------------------------
    def connect(self):
        try:
            conn = sqlite3.connect(
                self.db_path,
                check_same_thread=False,   # allow usage across threads
                timeout=10                 # prevents "database is locked"
            )
            conn.execute("PRAGMA journal_mode=WAL;")
            conn.execute("PRAGMA busy_timeout=5000;")
            return conn
        except sqlite3.Error as e:
            print("Database connection error:", e)
            return None

    # ----------------------------------------------------
    # CREATE TABLES
    # ----------------------------------------------------
    def initialize_db(self):
        conn = self.connect()
        if not conn:
            return False

        cursor = conn.cursor()

        try:
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS cabs (
                    cab_id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    rto_number TEXT NOT NULL,
                    driver_name TEXT NOT NULL,
                    latitude REAL NOT NULL,
                    longitude REAL NOT NULL,
                    status TEXT NOT NULL
                )
            ''')

            cursor.execute('''
                CREATE TABLE IF NOT EXISTS rides (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    cab_id INTEGER NOT NULL,
                    user_start_x REAL NOT NULL,
                    user_start_y REAL NOT NULL,
                    user_end_x REAL NOT NULL,
                    user_end_y REAL NOT NULL,
                    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
                    shared BOOLEAN DEFAULT 0,
                    FOREIGN KEY (cab_id) REFERENCES cabs (cab_id)
                )
            ''')

            cursor.execute('''
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    username TEXT UNIQUE NOT NULL,
                    password TEXT NOT NULL
                )
            ''')

            conn.commit()
            return True

        except sqlite3.Error as e:
            print("Database initialization error:", e)
        finally:
            conn.close()

    # ----------------------------------------------------
    # GET ALL CABS
    # ----------------------------------------------------
    def get_all_cabs(self):
        conn = self.connect()
        if not conn:
            return []

        cursor = conn.cursor()
        try:
            cursor.execute(
                "SELECT cab_id, name, rto_number, driver_name, latitude, longitude, status FROM cabs"
            )
            result = cursor.fetchall()

            return [{
                "cab_id": r[0],
                "name": r[1],
                "rto_number": r[2],
                "driver_name": r[3],
                "latitude": r[4],
                "longitude": r[5],
                "status": r[6]
            } for r in result]

        except sqlite3.Error as e:
            print("Error fetching cabs:", e)
            return []
        finally:
            conn.close()

    # ----------------------------------------------------
    # UPDATE CAB LOCATION
    # ----------------------------------------------------
    def update_cab_location(self, cab_id, latitude, longitude, status=None):
        conn = self.connect()
        if not conn:
            return False

        cursor = conn.cursor()

        try:
            if status:
                cursor.execute(
                    "UPDATE cabs SET latitude=?, longitude=?, status=? WHERE cab_id=?",
                    (latitude, longitude, status, cab_id)
                )
            else:
                cursor.execute(
                    "UPDATE cabs SET latitude=?, longitude=? WHERE cab_id=?",
                    (latitude, longitude, cab_id)
                )

            conn.commit()
            return True

        except sqlite3.Error as e:
            print("Error updating cab location:", e)
            return False
        finally:
            conn.close()

    # ----------------------------------------------------
    # UPDATE CAB STATUS
    # ----------------------------------------------------
    def update_cab_status(self, cab_id, status, latitude=None, longitude=None):
        conn = self.connect()
        if not conn:
            return False

        cursor = conn.cursor()

        try:
            if latitude is not None and longitude is not None:
                cursor.execute(
                    "UPDATE cabs SET status=?, latitude=?, longitude=? WHERE cab_id=?",
                    (status, latitude, longitude, cab_id)
                )
            else:
                cursor.execute(
                    "UPDATE cabs SET status=? WHERE cab_id=?",
                    (status, cab_id)
                )

            conn.commit()
            return True

        except sqlite3.Error as e:
            print("Error updating cab status:", e)
            return False
        finally:
            conn.close()

    # ----------------------------------------------------
    # ADD RIDE
    # ----------------------------------------------------
    def add_ride(self, cab_id, start_lat, start_lng, end_lat, end_lng, shared):
        conn = self.connect()
        if not conn:
            return False

        cursor = conn.cursor()

        try:
            cursor.execute('''
                INSERT INTO rides (cab_id, user_start_x, user_start_y,
                                   user_end_x, user_end_y, shared)
                VALUES (?, ?, ?, ?, ?, ?)
            ''', (cab_id, start_lat, start_lng, end_lat, end_lng, shared))

            conn.commit()
            return True

        except sqlite3.Error as e:
            print("Error adding ride:", e)
            return False
        finally:
            conn.close()

    # ----------------------------------------------------
    # GET LAST RIDE OF CAB
    # ----------------------------------------------------
    def get_ride_by_cab_id(self, cab_id):
        conn = self.connect()
        if not conn:
            return None

        cursor = conn.cursor()

        try:
            cursor.execute("""
                SELECT id, cab_id, user_start_x, user_start_y,
                       user_end_x, user_end_y, timestamp, shared
                FROM rides
                WHERE cab_id=?
                ORDER BY timestamp DESC
                LIMIT 1
            """, (cab_id,))

            row = cursor.fetchone()
            if row:
                return {
                    "id": row[0],
                    "cab_id": row[1],
                    "start_latitude": row[2],
                    "start_longitude": row[3],
                    "end_latitude": row[4],
                    "end_longitude": row[5],
                    "timestamp": row[6],
                    "shared": bool(row[7])
                }

            return None

        except sqlite3.Error as e:
            print("Error fetching ride:", e)
            return None
        finally:
            conn.close()
