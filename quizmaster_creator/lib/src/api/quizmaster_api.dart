import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class QuizmasterApi {
  QuizmasterApi({
    required String baseUrl,
    required this.token,
    http.Client? client,
  }) : baseUrl = baseUrl.trim().replaceFirst(RegExp(r'/+$'), ''),
       _client = client ?? http.Client();

  final String baseUrl;
  final String token;
  final http.Client _client;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (token.trim().isNotEmpty) 'Authorization': 'Bearer ${token.trim()}',
  };

  Map<String, String> get _jsonHeaders => {
    ..._headers,
    'Content-Type': 'application/json',
  };

  Future<Map<String, dynamic>> health() => _get('/api/v1/health');

  Future<Map<String, dynamic>> providers() => _get('/api/v1/providers');

  Future<Map<String, dynamic>> pipelineOptions() =>
      _get('/api/v1/pipeline/options');

  Future<Map<String, dynamic>> dashboard() => _get('/api/v1/dashboard');

  Future<Map<String, dynamic>> pipelines() => _get('/api/v1/pipelines');

  Future<Map<String, dynamic>> pipelineJob(String jobId) =>
      _get('/api/v1/pipelines/$jobId');

  Future<Map<String, dynamic>> startPipeline(Map<String, dynamic> payload) =>
      _post('/api/v1/pipelines', payload);

  Future<Map<String, dynamic>> retryPipeline(String jobId) =>
      _post('/api/v1/pipelines/$jobId/retry', const {});

  Future<Map<String, dynamic>> deploy(String slug, {int? version}) {
    final payload = <String, dynamic>{};
    if (version != null) {
      payload['version'] = version;
    }
    return _post('/api/v1/bundles/$slug/deploy', payload);
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final response = await _client.get(_uri(path), headers: _headers);
    return _decode(response);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final response = await _client.post(
      _uri(path),
      headers: _jsonHeaders,
      body: jsonEncode(payload),
    );
    return _decode(response);
  }

  Map<String, dynamic> _decode(http.Response response) {
    dynamic body;
    try {
      body = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body);
    } on FormatException {
      throw ApiException(
        'The server returned an unreadable response.',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      dynamic detail = body is Map<String, dynamic> ? body['detail'] : null;
      if (detail is Map<String, dynamic>) {
        detail = detail['message'] ?? detail.values.join(' ');
      }
      throw ApiException(
        (detail?.toString().trim().isNotEmpty ?? false)
            ? detail.toString()
            : 'Request failed with status ${response.statusCode}.',
        statusCode: response.statusCode,
      );
    }
    if (body is! Map<String, dynamic>) {
      throw const ApiException('The server response has an unexpected shape.');
    }
    return body;
  }

  void close() => _client.close();
}
