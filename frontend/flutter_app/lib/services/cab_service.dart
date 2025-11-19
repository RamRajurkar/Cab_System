import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

class CabService {
  Future<Map<String, dynamic>?> findCab(
    double startLatitude,
    double startLongitude,
    double endLatitude,
    double endLongitude,
  ) async {
    final url = Uri.parse('${ApiConfig.baseUrl}/api/find_cab');
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'start_latitude': startLatitude,
          'start_longitude': startLongitude,
          'end_latitude': endLatitude,
          'end_longitude': endLongitude,
        }),
      );

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        print('Failed to find cab: ${response.statusCode}');
        print('Response body: ${response.body}');
        return null;
      }
    } catch (e) {
      print('Error finding cab: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> bookCab(
    double startLatitude,
    double startLongitude,
    double endLatitude,
    double endLongitude,
    String cabId,
    {bool isShared = false,
    String? primaryRequestId,
    String? newRequestId,
    }
  ) async {
    final url = Uri.parse('${ApiConfig.baseUrl}/api/book_cab');
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'start_latitude': startLatitude,
          'start_longitude': startLongitude,
          'end_latitude': endLongitude,
          'end_longitude': endLongitude,
          'cab_id': cabId,
          'is_shared': isShared,
          'primary_request_id': primaryRequestId,
          'new_request_id': newRequestId,
        }),
      );

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        print('Failed to book cab: ${response.statusCode}');
        print('Response body: ${response.body}');
        return null;
      }
    } catch (e) {
      print('Error booking cab: $e');
      return null;
    }
  }


}

