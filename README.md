# Multi-Shared Smart Cab Allocation System

A complete, demo-ready project that simulates a real-world shared cab booking system where multiple users can share the same cab if their routes are nearby. The application demonstrates practical use of Data Structures and Algorithms (Heap, Graph, Queue, HashMap) in an end-to-end mobile app.

## Project Overview

- Users enter pickup coordinates via the Flutter app.
- Flask backend finds the nearest cab using a **Min Heap**.
- If the new user's route overlaps with an existing one, assign the **same cab** (shared ride).
- Compute the shortest route using **Dijkstra's algorithm**.
- Track cabs as **Available**, **Busy**, or **Shared**.
- Store completed rides in **SQLite** and visualize user and cab markers on a **map** in Flutter.

## System Architecture

```
cab_system/
│
├── backend/
│   ├── app.py
│   └── dsa/
│       ├── heap_utils.py
│       ├── graph.py
│       └── db_utils.py
│   └── database.db
│
└── frontend/
    └── flutter_app/
        ├── lib/
        │   ├── main.dart
        │   ├── screens/
        │   │   ├── home_screen.dart
        │   │   ├── map_screen.dart
        │   │   └── ride_history.dart
        │   └── widgets/
        │       └── ride_card.dart
        └── pubspec.yaml
```

## Backend (Flask + Python DSA)

### Backend Features:
- **Flask** as the REST API server.
- **SQLite** (`database.db`) to store cabs and rides.
- **CORS** for Flutter integration.

### API Endpoints:
1. `POST /api/find_cab` → Input: user coordinates (x, y)  
   Output: nearest cab info (id, distance, shared status).
2. `GET /api/complete_ride/<cab_id>` → Marks a cab as available again.
3. `GET /api/ride_history` → Returns all previous rides.
4. `GET /api/cabs` → Returns all cabs.
5. `GET /api/active_rides` → Returns all active rides.

### DSA Modules:
- `heap_utils.py`  
  → Uses Min Heap to find the nearest cab.
- `graph.py`  
  → Implements a simple graph with **Dijkstra's algorithm** for shortest paths.
- `db_utils.py`  
  → Creates and manages SQLite tables for rides and cabs.

## Frontend (Flutter)

### Frontend Features:
- **Home Screen**: Enter pickup and destination coordinates, book a cab.
- **Map Screen**: Visualize cabs, pickup points, destinations, and routes.
- **Ride History**: View past rides.

### Widgets:
- **RideCard**: Displays ride information in a card format.

## How to Run

### Backend Setup:
1. Navigate to the backend directory:
   ```
   cd backend
   ```
2. Install required packages:
   ```
   pip install flask flask-cors
   ```
3. Run the Flask app:
   ```
   python app.py
   ```
   The server will start on `http://localhost:5000`.

### Frontend Setup:
1. Navigate to the frontend/flutter_app directory:
   ```
   cd frontend/flutter_app
   ```
2. Get Flutter dependencies:
   ```
   flutter pub get
   ```
3. Run the Flutter app:
   ```
   flutter run
   ```

## Data Structures and Algorithms Used

1. **Min Heap**: Used to find the nearest available cab based on distance.
2. **Graph**: Represents the road network for route planning.
3. **Dijkstra's Algorithm**: Finds the shortest path between pickup and destination.
4. **HashMap**: Used for efficient storage and retrieval of cab and ride data.

## Demo Scenario

1. Enter pickup coordinates (e.g., 2, 3) and destination coordinates (e.g., 7, 8).
2. The system will find the nearest available cab using a Min Heap.
3. If another user's route overlaps with yours, the system will assign the same cab (shared ride).
4. The map will show the cab, pickup point, destination, and route.
5. Complete the ride to make the cab available again.

## Future Enhancements

1. Real-time tracking of cabs using WebSockets.
2. User authentication and profiles.
3. Fare calculation based on distance and sharing.
4. More sophisticated route optimization algorithms.
5. Integration with real map services like Google Maps API.


