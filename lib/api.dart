import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

/// Holds the login token used by the phone app (the web version uses a cookie).
class Api {
  static String? token;

  /// Extra headers for Image.network and the video player.
  static Map<String, String>? get imageHeaders =>
      (!kIsWeb && token != null) ? {'Authorization': 'Bearer $token'} : null;
}

http.Client? _shared;

/// Call once in main(), BEFORE runWithClient.
void initApi() {
  _shared ??= http.Client();
}

/// Adds the login token to every request the app makes.
class TokenClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final t = Api.token;
    if (t != null && !kIsWeb) {
      request.headers['Authorization'] = 'Bearer $t';
    }
    return _shared!.send(request);
  }

  @override
  void close() {} // the shared connection stays open
}