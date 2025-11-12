/// api_config.dart
/// Configurable backend URLs for local and production environments.
/// 
/// Local = your laptop's IP (for USB or Wi-Fi testing)
/// Production = your Render backend URL (for deployed backend)

import 'package:flutter/foundation.dart';

class ApiConfig {
  // 🔹 Local Flask URL — replace with your computer’s IPv4
  static const String localUrl = "http://192.168.1.7:5001";

  // 🔹 Render backend URL — your hosted Flask API
  static const String prodUrl = "https://smart-cab-backend.onrender.com";

  /// ✅ Force production mode (useful when debugging on phone via USB)
  /// Set to `true` to always use hosted Render backend.
  /// Set to `false` to auto-switch between local (debug) and hosted (release).
  static const bool forceProd = true; // ⚠️ Change to false for local Flask testing

  /// Automatically picks backend based on environment.
  static String get baseUrl {
    final bool isProd = bool.fromEnvironment('dart.vm.product');
    final String selectedUrl =
        forceProd ? prodUrl : (isProd ? prodUrl : localUrl);

    // 🐞 Debugging logs
    debugPrint("🔧 [ApiConfig] Running in ${isProd ? 'Release' : 'Debug'} mode");
    debugPrint("🌐 [ApiConfig] ForceProd: $forceProd");
    debugPrint("🚀 [ApiConfig] Using backend URL: $selectedUrl");

    return selectedUrl;
  }
}
