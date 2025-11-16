// lib/screens/booking_status_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class BookingStatusScreen extends StatefulWidget {
  final int cabId;
  final double fare;
  final String cabName;
  final VoidCallback onCabsRefresh;
  final VoidCallback onRideCompleted;

  const BookingStatusScreen({
    Key? key,
    required this.cabId,
    required this.fare,
    required this.cabName,
    required this.onCabsRefresh,
    required this.onRideCompleted,
  }) : super(key: key);

  @override
  State<BookingStatusScreen> createState() => _BookingStatusScreenState();
}

class _BookingStatusScreenState extends State<BookingStatusScreen> {
  // Ride stages
  RideStage _stage = RideStage.findingDriver;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();

    // Auto transition after delay (fake simulation)
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _stage == RideStage.findingDriver) {
        setState(() => _stage = RideStage.driverArriving);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Ride Status"),
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(child: Center(child: _buildAnimation())),
          const SizedBox(height: 10),
          Text(
            _statusText(),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),

          const SizedBox(height: 20),
          Text("Cab: ${widget.cabName}", style: const TextStyle(fontSize: 15)),
          Text("Fare: ₹${widget.fare.toStringAsFixed(2)}",
              style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 30),

          _buildActionButton(),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  // Load correct animation based on stage
  Widget _buildAnimation() {
    switch (_stage) {
      case RideStage.findingDriver:
        return Lottie.asset('assets/animations/finding_driver.json');
      case RideStage.driverArriving:
        return Lottie.asset('assets/animations/driver_arriving.json');
      case RideStage.rideStarted:
        return Lottie.asset('assets/animations/ride_starting.json');
      case RideStage.completed:
        return Lottie.asset('assets/animations/success.json');
    }
  }

  // Stage text
  String _statusText() {
    switch (_stage) {
      case RideStage.findingDriver:
        return "Finding a driver for you...";
      case RideStage.driverArriving:
        return "Driver is arriving soon...";
      case RideStage.rideStarted:
        return "Enjoy your ride!";
      case RideStage.completed:
        return "Ride Completed Successfully 🎉";
    }
  }

  // Buttons change depending on stage
  Widget _buildActionButton() {
    if (_isLoading) {
      return const CircularProgressIndicator();
    }

    switch (_stage) {
      case RideStage.findingDriver:
        return _button("Cancel Ride", Colors.red, () {
          Navigator.pop(context);
        });

      case RideStage.driverArriving:
        return _button("Start Ride", Colors.blue, () {
          setState(() => _stage = RideStage.rideStarted);
        });

      case RideStage.rideStarted:
        return _button("Complete Ride", Colors.green, () async {
          setState(() => _stage = RideStage.completed);
          await Future.delayed(const Duration(seconds: 2));
          widget.onRideCompleted();
          widget.onCabsRefresh();
        });

      case RideStage.completed:
        return _button("Done", Colors.black, () {
          Navigator.pop(context);
        });
    }
  }

  Widget _button(String text, Color color, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 26.0),
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: onTap,
        child: Text(text, style: const TextStyle(fontSize: 17, color: Colors.white)),
      ),
    );
  }
}

enum RideStage { findingDriver, driverArriving, rideStarted, completed }
