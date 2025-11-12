import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

class CabService {
  Future<List<dynamic>> getCabs() async {
    final url = Uri.parse("${ApiConfig.baseUrl}/api/cabs");

    try {
      final response = await http.get(url);

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception("Server error: ${response.statusCode}");
      }
    } catch (e) {
      throw Exception("Error fetching cab locations: $e");
    }
  }
}

