import 'package:flutter/material.dart';
import 'package:smart_cab_allocation/screens/map_screen.dart';
import 'package:smart_cab_allocation/screens/shared_ride_screen.dart';
import 'package:smart_cab_allocation/screens/ride_history.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home Screen'),
      ),

      // FIX: Make the whole page scrollable
      body: SingleChildScrollView(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),

          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,

            children: [

              const SizedBox(height: 40),

              const Text(
                'Welcome to the Home Screen!',
                style: TextStyle(fontSize: 20),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 40),

              _buildButton(
                text: 'Go to Map',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const MapScreen()),
                  );
                },
              ),

              const SizedBox(height: 20),

              _buildButton(
                text: 'Register Cab',
                onTap: () {
                  Navigator.pushNamed(context, '/cab_register');
                },
              ),

              const SizedBox(height: 20),

              _buildButton(
                text: 'Book Shared Ride',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SharedRideScreen()),
                  );
                },
              ),

              const SizedBox(height: 20),

              // 👉 YOUR MISSING BUTTON (now visible)
              _buildButton(
                text: 'View Ride History',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const RideHistoryScreen()),
                  );
                },
              ),

              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildButton({required String text, required VoidCallback onTap}) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Text(text),
      ),
    );
  }
}
