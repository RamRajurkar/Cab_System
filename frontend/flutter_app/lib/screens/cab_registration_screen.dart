import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../utils/constants.dart';

class CabRegistrationScreen extends StatefulWidget {
  @override
  _CabRegistrationScreenState createState() => _CabRegistrationScreenState();
}

class _CabRegistrationScreenState extends State<CabRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  TextEditingController _cabIdController = TextEditingController();
  TextEditingController _cabNameController = TextEditingController();
  TextEditingController _latitudeController = TextEditingController();
  TextEditingController _longitudeController = TextEditingController();
  TextEditingController _rtoNumberController = TextEditingController();
  TextEditingController _driverNameController = TextEditingController();
  String _status = 'Available';

  Future<void> _registerCab() async {
    if (_formKey.currentState!.validate()) {
      final String apiUrl = '${AppConstants.baseUrl}/api/cab_register'; // Replace with your backend URL
      try {
        final response = await http.post(
          Uri.parse(apiUrl),
          headers: <String, String>{
            'Content-Type': 'application/json; charset=UTF-8',
          },
          body: jsonEncode(<String, dynamic>{
            'cab_id': int.parse(_cabIdController.text),
            'name': _cabNameController.text,
            'rto_number': _rtoNumberController.text,
            'driver_name': _driverNameController.text,
            'latitude': double.parse(_latitudeController.text),
            'longitude': double.parse(_longitudeController.text),
            'status': _status,
          }),
        );

        if (response.statusCode == 201) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Cab registered successfully!')),
          );
          _cabIdController.clear();
          _cabNameController.clear();
          _latitudeController.clear();
          _longitudeController.clear();
          _rtoNumberController.clear();
          _driverNameController.clear();
        } else {
          final errorData = jsonDecode(response.body);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to register cab: ${errorData['message'] ?? response.statusCode}')),
          );
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Cab Registration'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: <Widget>[
              TextFormField(
                controller: _cabIdController,
                decoration: InputDecoration(labelText: 'Cab ID'),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter Cab ID';
                  }
                  if (int.tryParse(value) == null) {
                    return 'Please enter a valid number';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _cabNameController,
                decoration: InputDecoration(labelText: 'Cab Name'),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter Cab Name';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _rtoNumberController,
                decoration: InputDecoration(labelText: 'RTO Number'),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter RTO Number';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _driverNameController,
                decoration: InputDecoration(labelText: 'Driver Name'),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter Driver Name';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _latitudeController,
                decoration: InputDecoration(labelText: 'Initial Latitude'),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter Latitude';
                  }
                  if (double.tryParse(value) == null) {
                    return 'Please enter a valid number';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _longitudeController,
                decoration: InputDecoration(labelText: 'Initial Longitude'),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter Longitude';
                  }
                  if (double.tryParse(value) == null) {
                    return 'Please enter a valid number';
                  }
                  return null;
                },
              ),
              DropdownButtonFormField<String>(
                value: _status,
                decoration: InputDecoration(labelText: 'Status'),
                items: <String>['Available', 'Busy', 'Shared']
                    .map<DropdownMenuItem<String>>((String value) {
                  return DropdownMenuItem<String>(
                    value: value,
                    child: Text(value),
                  );
                }).toList(),
                onChanged: (String? newValue) {
                  setState(() {
                    _status = newValue!;
                  });
                },
              ),
              SizedBox(height: 20),
              ElevatedButton(
                onPressed: _registerCab,
                child: Text('Register Cab'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}