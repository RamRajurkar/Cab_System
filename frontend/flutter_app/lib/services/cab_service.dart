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


  Future<Map<String, dynamic>> findCab(double startLatitude, double startLongitude, double endLatitude, double endLongitude) async {
    final url = Uri.parse("${ApiConfig.baseUrl}/api/find_cab");
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'start_latitude': startLatitude,
          'start_longitude': startLongitude,
          'end_latitude': endLatitude,
          'end_longitude': endLongitude,
        }),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception("Server error: ${response.statusCode}");
      }
    } catch (e) {
      throw Exception("Error finding cab: $e");
    }
  }

  Future<Map<String, dynamic>> bookCab(String cabId, double startLatitude, double startLongitude, double endLatitude, double endLongitude, bool isShared, {int? primaryRequestId, int? newRequestId}) async {
    final url = Uri.parse("${ApiConfig.baseUrl}/api/book_cab");
    try {
      final body = {
        'cab_id': cabId,
        'start_latitude': startLatitude,
        'start_longitude': startLongitude,
        'end_latitude': endLongitude,
        'end_longitude': endLongitude,
        'is_shared': isShared,
      };
      if (isShared) {
        body['primary_request_id'] = primaryRequestId;
        body['new_request_id'] = newRequestId;
      }

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception("Server error: ${response.statusCode}");
      }
    } catch (e) {
      throw Exception("Error booking cab: $e");
    }
  }


}

