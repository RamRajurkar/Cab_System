import 'package:flutter/material.dart';
import 'services/websocket_service.dart';
import 'screens/home_screen.dart';
import 'screens/register_screen.dart';
import 'screens/cab_registration_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await WebSocketService().connect();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowBanner: false,
      title: "Smart Cab Allocation",
      initialRoute: "/home",
      routes: {
        "/home": (_) => HomeScreen(),
        "/register": (_) => RegisterScreen(),
        "/cab_register": (_) => CabRegistrationScreen(),
      },
    );
  }
}
