import 'package:flutter/material.dart';
import 'package:smart_cab_allocation/screens/map_screen.dart';
import 'package:smart_cab_allocation/screens/shared_ride_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home Screen'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Welcome to the Home Screen!'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Navigator.push(context, MaterialPageRoute(builder: (context) => MapScreen()));
              },
              child: const Text('Go to Map'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Navigator.pushNamed(context, '/cab_register');
              },
              child: const Text('Register Cab'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Navigator.push(context, MaterialPageRoute(builder: (context) => SharedRideScreen()));
              },
              child: const Text('Book Shared Ride'),
            ),
          ],
        ),
      ),
    );
  }
}