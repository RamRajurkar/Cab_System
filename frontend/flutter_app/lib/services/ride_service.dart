import 'dart:convert';
import 'package:http/http.dart' as http;
import '../utils/constants.dart';

class RideService {
  static Future<List<dynamic>> fetchRideHistory() async {
    final response = await http.get(
      Uri.parse('${AppConstants.baseUrl}/api/ride_history'),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load ride history: ${response.statusCode}');
    }
  }
}