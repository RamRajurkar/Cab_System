import sqlite3
import os

class DatabaseUtils:
    def __init__(self, db_path='../database.db'):
        """
        Initialize the database utility with the path to the SQLite database.
        """
        self.db_path = db_path
        self.conn = None
        self.cursor = None
        self.initialize_db()

    def connect(self):
        """
        Connect to the SQLite database.
        """
        try:
            self.conn = sqlite3.connect(self.db_path)
            self.cursor = self.conn.cursor()
            return self.conn
        except sqlite3.Error as e:
            print(f"Database connection error: {e}")
            return None

    def disconnect(self):
        """
        Disconnect from the SQLite database.
        """
        if self.conn:
            self.conn.close()
            self.conn = None
            self.cursor = None

    def initialize_db(self):
        """
        Create the necessary tables if they don't exist.
        """
        if not self.connect():
            return False

        try:
            # Create cabs table
            self.cursor.execute('''
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

            # Create rides table
            self.cursor.execute('''
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

            # Create users table
            self.cursor.execute('''
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL,
                password TEXT NOT NULL
            )
            ''')

            # Check if cabs table is empty, if so, insert sample data
            self.cursor.execute("SELECT COUNT(*) FROM cabs")
            count = self.cursor.fetchone()[0]
            
            if count == 0:
                # Insert sample cabs
                sample_cabs = [
                    (1, "Cab A", "MH12AB1234", "Driver A", 18.5204, 73.8567, "Available"), # Pune coordinates
                    (2, "Cab B", "MH14CD5678", "Driver B", 18.5600, 73.9000, "Available"),
                    (3, "Cab C", "MH10EF9012", "Driver C", 18.4800, 73.8000, "Available"),
                    (4, "Cab D", "MH11GH3456", "Driver D", 18.6000, 73.9500, "Available"),
                    (5, "Cab E", "MH12IJ7890", "Driver E", 18.5000, 73.8800, "Available")
                ]
                
                self.cursor.executemany(
                    "INSERT INTO cabs (cab_id, name, rto_number, driver_name, latitude, longitude, status) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    sample_cabs
                )

            self.conn.commit()
            return True
        except sqlite3.Error as e:
            print(f"Database initialization error: {e}")
            return False
        finally:
            self.disconnect()

    def get_all_cabs(self):
        """
        Get all cabs from the database.
        """
        if not self.connect():
            return []

        try:
            self.cursor.execute("SELECT cab_id, name, rto_number, driver_name, latitude, longitude, status FROM cabs")
            cabs = [{
                'cab_id': row[0],
                'name': row[1],
                'rto_number': row[2],
                'driver_name': row[3],
                'latitude': row[4],
                'longitude': row[5],
                'status': row[6]
            } for row in self.cursor.fetchall()]
            return cabs
        except sqlite3.Error as e:
            print(f"Error fetching cabs: {e}")
            return []
        finally:
            self.disconnect()

    def update_cab_location(self, cab_id, latitude, longitude, status=None):
        """
        Update the location of a cab and optionally its status.
        """
        if not self.connect():
            return False

        try:
            if status:
                self.cursor.execute(
                    "UPDATE cabs SET latitude = ?, longitude = ?, status = ? WHERE cab_id = ?",
                    (latitude, longitude, status, cab_id)
                )
            else:
                self.cursor.execute(
                    "UPDATE cabs SET latitude = ?, longitude = ? WHERE cab_id = ?",
                    (latitude, longitude, cab_id)
                )
            self.conn.commit()
            return True
        except sqlite3.Error as e:
            print(f"Error updating cab location: {e}")
            return False
        finally:
            self.disconnect()

    def update_cab_status(self, cab_id, status, latitude=None, longitude=None):
        """
        Update the status of a cab and optionally its position.
        """
        if not self.connect():
            return False

        try:
            if latitude is not None and longitude is not None:
                self.cursor.execute(
                    "UPDATE cabs SET status = ?, x = ?, y = ? WHERE cab_id = ?",
                    (status, latitude, longitude, cab_id)
                )
            else:
                self.cursor.execute(
                    "UPDATE cabs SET status = ? WHERE cab_id = ?",
                    (status, cab_id)
                )
            self.conn.commit()
            return True
        except sqlite3.Error as e:
            print(f"Error updating cab status: {e}")
            return False
        finally:
            self.disconnect()

    def update_all_cabs_status(self, status):
        """
        Update the status of all cabs.
        """
        if not self.connect():
            return False

        try:
            self.cursor.execute(
                "UPDATE cabs SET status = ?",
                (status,)
            )
            self.conn.commit()
            return True
        except sqlite3.Error as e:
            print(f"Error updating all cabs status: {e}")
            return False
        finally:
            self.disconnect()

    def reset_all_cab_statuses(self):
        """
        Reset the status of all cabs to 'Available'.
        """
        if not self.connect():
            return False
        try:
            self.cursor.execute("UPDATE cabs SET status = 'Available'")
            self.conn.commit()
            return True
        except sqlite3.Error as e:
            print(f"Error resetting all cab statuses: {e}")
            return False
        finally:
            self.disconnect()

    def add_cab(self, cab_id, name, rto_number, driver_name, latitude, longitude, status):
        """
        Add a new cab to the database or update an existing one.
        """
        if not self.connect():
            return False
        try:
            self.cursor.execute(
                'INSERT OR REPLACE INTO cabs (cab_id, name, rto_number, driver_name, latitude, longitude, status) VALUES (?, ?, ?, ?, ?, ?, ?)',
                (cab_id, name, rto_number, driver_name, latitude, longitude, status)
            )
            self.conn.commit()
            return True
        except sqlite3.Error as e:
            print(f"Error adding/updating cab: {e}")
            return False

    def add_ride(self, cab_id, user_start_latitude, user_start_longitude, user_end_latitude, user_end_longitude, shared):
        """
        Add a new ride to the database.
        """
        if not self.connect():
            return False

        try:
            self.cursor.execute(
                "INSERT INTO rides (cab_id, user_start_x, user_start_y, user_end_x, user_end_y, shared) VALUES (?, ?, ?, ?, ?, ?)",
                (cab_id, user_start_latitude, user_start_longitude, user_end_latitude, user_end_longitude, shared)
            )
            self.conn.commit()
            return True
        except sqlite3.Error as e:
            print(f"Error adding ride: {e}")
            return False
        finally:
            self.disconnect()

    def get_ride_by_cab_id(self, cab_id):
        """
        Get the most recent ride for a specific cab from the database.
        """
        if not self.connect():
            return None

        try:
            self.cursor.execute("""
                SELECT id, cab_id, user_start_x, user_start_y, user_end_x, user_end_y, timestamp, shared
                FROM rides
                WHERE cab_id = ?
                ORDER BY timestamp DESC
                LIMIT 1
            """, (cab_id,))
            row = self.cursor.fetchone()
            if row:
                return {
                    'id': row[0],
                    'cab_id': row[1],
                    'start_latitude': row[2],
                    'start_longitude': row[3],
                    'end_latitude': row[4],
                    'end_longitude': row[5],
                    'timestamp': row[6],
                    'shared': bool(row[7])
                }
            return None
        except sqlite3.Error as e:
            print(f"Error fetching ride by cab ID: {e}")
            return None
        finally:
            self.disconnect()

    def get_ride_history(self):
        """
        Get all rides from the database.
        """
        if not self.connect():
            return []

        try:
            self.cursor.execute("""
                SELECT r.id, r.cab_id, c.name, r.user_start_x, r.user_start_y, 
                       r.user_end_x, r.user_end_y, r.timestamp, r.shared 
                FROM rides r 
                JOIN cabs c ON r.cab_id = c.cab_id 
                ORDER BY r.timestamp DESC
            """)
            
            rides = [{
                'id': row[0],
                'cab_id': row[1],
                'cab_name': row[2],
                'start_x': row[3],
                'start_y': row[4],
                'end_x': row[5],
                'end_y': row[6],
                'timestamp': row[7],
                'shared': bool(row[8])
            } for row in self.cursor.fetchall()]
            
            return rides
        except sqlite3.Error as e:
            print(f"Error fetching ride history: {e}")
            return []
        finally:
            self.disconnect()

    def get_active_rides(self):
        """
        Get all active rides (cabs with status 'Busy' or 'Shared').
        """
        if not self.connect():
            return []

        try:
            self.cursor.execute("""
                SELECT c.cab_id, c.name, c.latitude, c.longitude, c.status,
                       r.user_start_x, r.user_start_y, r.user_end_x, r.user_end_y, r.shared 
                FROM cabs c 
                JOIN rides r ON c.cab_id = r.cab_id 
                WHERE c.status IN ('Busy', 'Shared') 
                ORDER BY r.timestamp DESC
            """)
            
            active_rides = [{
                'cab_id': row[0],
                'cab_name': row[1],
                'cab_latitude': row[2],
                'cab_longitude': row[3],
                'status': row[4],
                'start_latitude': row[5],
                'start_longitude': row[6],
                'end_latitude': row[7],
                'end_longitude': row[8],
                'shared': bool(row[9])
            } for row in self.cursor.fetchall()]
            
            return active_rides
        except sqlite3.Error as e:
            print(f"Error fetching active rides: {e}")
            return []
        finally:
            self.disconnect()