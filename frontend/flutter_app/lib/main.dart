import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'screens/register_screen.dart';
import 'screens/cab_registration_screen.dart';
import 'screens/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Cab Allocation',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
        ),
      ),

      initialRoute: '/login',

      routes: {
        '/register': (context) => const RegisterScreen(),
        '/cab_register': (context) => CabRegistrationScreen(),
        '/login': (context) => const LoginScreen(),
        '/': (context) => const HomeScreen(),
      },
    );
  }
}
