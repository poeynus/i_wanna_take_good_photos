import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'preset.dart';

class RemotePreset {
  RemotePreset.fromJson(Map<String, dynamic> data)
    : id = data['id'] as String,
      isPublic = data['public'] as bool,
      preset = Preset.fromJson(data['preset']);

  final String id;
  final bool isPublic;
  final Preset preset;
}

class PresetApi {
  PresetApi._(this.base, this.timeout);
  final Uri base;
  final Duration timeout;
  final _storage = const FlutterSecureStorage();
  late final _storageKey = 'camera-api-token:${base.origin}';
  Future<String>? _token;

  static PresetApi? fromEnvironment() {
    if (!const bool.fromEnvironment('CAM_ENABLE_PRESET_SHARING') &&
        !const bool.fromEnvironment('CAM_ENABLE_SHARING')) {
      return null;
    }
    final base = Uri.tryParse(const String.fromEnvironment('CAM_API_BASE_URL'));
    const milliseconds = int.fromEnvironment(
      'CAM_CONNECT_TIMEOUT_MS',
      defaultValue: 5000,
    );
    const development = String.fromEnvironment('CAM_APP_ENV') == 'development';
    final validScheme =
        base?.scheme == 'https' ||
        (kDebugMode && development && base?.scheme == 'http');
    if (base == null ||
        !validScheme ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        (base.path.isNotEmpty && base.path != '/') ||
        milliseconds <= 0) {
      return null;
    }
    return PresetApi._(base, const Duration(milliseconds: milliseconds));
  }

  Future<List<RemotePreset>> list(String query, bool mine, int offset) async {
    final value = await _authenticated(
      'GET',
      '/v1/presets',
      query: {'q': query, 'mine': '$mine', 'limit': '30', 'offset': '$offset'},
    ) as List<dynamic>;
    return value
        .map((item) => RemotePreset.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> save(Preset preset, bool isPublic, {String? id}) async {
    await _authenticated(
      id == null ? 'POST' : 'PUT',
      id == null ? '/v1/presets' : '/v1/presets/$id',
      body: {'preset': preset.toJson(), 'public': isPublic},
    );
  }

  Future<void> delete(String id) => _authenticated('DELETE', '/v1/presets/$id');

  Future<Map<String, dynamic>> sessionRequest(
    String method,
    String suffix, {
    Object? body,
  }) async {
    final value = await _authenticated(
      method,
      '/v1/sessions$suffix',
      body: body,
    );
    return value as Map<String, dynamic>? ?? {};
  }

  Future<Map<String, dynamic>> discoveryRequest(String method) async {
    final value = await _authenticated(method, '/v1/discovery');
    return value as Map<String, dynamic>? ?? {};
  }

  Future<WebSocket> openSignaling(String id) async {
    final token = await (_token ??= _readToken());
    final origin = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/v1/signaling/$id',
    );
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await WebSocket.connect(
        origin.toString(),
        headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
        customClient: client,
      ).timeout(timeout);
    } finally {
      client.close(force: false);
    }
  }

  Future<String> _readToken() async {
    final existing = await _storage.read(key: _storageKey);
    if (existing != null) return existing;
    final value = await _request('POST', '/v1/devices') as Map<String, dynamic>;
    final token = value['token'] as String;
    await _storage.write(key: _storageKey, value: token);
    return token;
  }

  Future<dynamic> _authenticated(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    try {
      final token = await (_token ??= _readToken());
      return await _request(
        method,
        path,
        query: query,
        body: body,
        token: token,
      );
    } on Exception {
      _token = null;
      rethrow;
    }
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? token,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    Future<dynamic> exchange() async {
      final request = await client.openUrl(
        method,
        base.replace(path: path, queryParameters: query),
      );
      request.followRedirects = false;
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Preset API returned ${response.statusCode}');
      }
      if (response.statusCode == HttpStatus.noContent) return null;
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 262144) {
          throw const FormatException('Preset API response too large');
        }
        bytes.addAll(chunk);
      }
      return jsonDecode(utf8.decode(bytes));
    }

    try {
      return await exchange().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }
}
