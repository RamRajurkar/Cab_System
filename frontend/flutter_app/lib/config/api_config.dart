/// api_config.dart
/// Backend API + WebSocket configuration

import 'package:flutter/foundation.dart';

class ApiConfig {
  // WebSocket URL (Render supports WSS)
  static const wsUrl = 'wss://cab-system-backend-31nf.onrender.com/cab_location_updates';

  // Local backend during development
  static const String localUrl = "http://192.168.1.7:5001";

  // Production backend (NO trailing slash)
  static const String prodUrl = "https://cab-system-backend-31nf.onrender.com";

  // Force production (useful when testing on real phone)
  static const bool forceProd = true;

  /// Auto-select URL based on environment or override
  static String get baseUrl {
    final bool isProdRuntime = bool.fromEnvironment('dart.vm.product');

    final selected = forceProd
        ? prodUrl
        : (isProdRuntime ? prodUrl : localUrl);

    debugPrint("🔧 [ApiConfig] Running in ${isProdRuntime ? 'Release' : 'Debug'}");
    debugPrint("🌐 [ApiConfig] forceProd = $forceProd");
    debugPrint("🚀 [ApiConfig] baseUrl = $selected");

    return selected;
  }
}
