import 'package:flutter/material.dart';

class SharedRideScreen extends StatefulWidget {
  const SharedRideScreen({Key? key}) : super(key: key);

  @override
  _SharedRideScreenState createState() => _SharedRideScreenState();
}

class _SharedRideScreenState extends State<SharedRideScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Book Shared Ride'),
      ),
      body: const Center(
        child: Text('Shared Ride Booking Screen'),
      ),
    );
  }
}