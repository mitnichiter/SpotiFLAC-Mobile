import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Only explicitly registered files can be read. URLs are unguessable and expire
/// when the session ends; filenames and library paths never enter the URL.
class CastMediaServer {
  HttpServer? _server;
  final _files = <String, (Object, String)>{};
  HttpClient? _proxyClient;
  final _random = Random.secure();

  Future<void> start(String address) async {
    if (_server != null) return;
    _server = await HttpServer.bind(address, 0);
    _proxyClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _server!.listen((request) => unawaited(_serve(request)));
  }

  Uri register(File file, String mime) => _register(file, mime);

  /// Relay loopback playback tunnels through the LAN address. The receiver
  /// cannot reach the phone's 127.0.0.1 URL itself.
  Uri registerProxy(Uri source, String mime) {
    if (!{'http', 'https'}.contains(source.scheme)) {
      throw ArgumentError('Only HTTP media can be relayed');
    }
    return _register(source, mime);
  }

  Uri _register(Object file, String mime) {
    final server = _server;
    if (server == null) throw StateError('Cast media server is not running');
    final token = List.generate(
      32,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _files[token] = (file, mime);
    return Uri(
      scheme: 'http',
      host: server.address.address,
      port: server.port,
      path: '/media/$token',
    );
  }

  void retain(Set<Uri> urls) {
    final tokens = urls.map((url) => url.pathSegments.last).toSet();
    _files.removeWhere((token, _) => !tokens.contains(token));
  }

  Future<void> close() async {
    _files.clear();
    _proxyClient?.close(force: true);
    _proxyClient = null;
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      response.headers.set('Access-Control-Allow-Origin', '*');
      response.headers.set(
        'Access-Control-Allow-Headers',
        'Range, Content-Type',
      );
      response.headers.set(
        'Access-Control-Allow-Methods',
        'GET, HEAD, OPTIONS',
      );
      response.headers.set(
        'Access-Control-Expose-Headers',
        'Content-Range, Accept-Ranges, Content-Length',
      );
      response.headers.set('Access-Control-Allow-Private-Network', 'true');
      response.headers.set('Cache-Control', 'no-store');
      final parts = request.uri.pathSegments;
      final entry = parts.length == 2 && parts.first == 'media'
          ? _files[parts.last]
          : null;
      if (entry == null) {
        response.statusCode = 404;
        return;
      }
      if (request.method == 'OPTIONS') {
        response.statusCode = 204;
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = 405;
        return;
      }
      final (resource, mime) = entry;
      if (resource is Uri) {
        final client = _proxyClient;
        if (client == null) {
          response.statusCode = 503;
          return;
        }
        final upstream = await client.openUrl(request.method, resource);
        final range = request.headers.value('range');
        if (range != null) upstream.headers.set('Range', range);
        final content = await upstream.close();
        response.statusCode = content.statusCode;
        for (final header in [
          'Content-Type',
          'Content-Length',
          'Content-Range',
          'Accept-Ranges',
        ]) {
          final value = content.headers.value(header);
          if (value != null) response.headers.set(header, value);
        }
        if (content.headers.value('Content-Type') == null) {
          response.headers.set('Content-Type', mime);
        }
        await response.addStream(content);
        return;
      }
      final file = resource as File;
      final length = await file.length();
      final range = parseCastByteRange(request.headers.value('range'), length);
      if (range == null) {
        response.statusCode = 416;
        response.headers.set('Content-Range', 'bytes */$length');
        return;
      }
      final (start, end) = range;
      response.headers.set('Content-Type', mime);
      response.headers.set('Accept-Ranges', 'bytes');
      response.contentLength = length == 0 ? 0 : end - start + 1;
      if (request.headers.value('range') != null) {
        response.statusCode = 206;
        response.headers.set('Content-Range', 'bytes $start-$end/$length');
      }
      if (request.method == 'GET' && length > 0) {
        await response.addStream(file.openRead(start, end + 1));
      }
    } on FileSystemException {
      response.statusCode = 404;
    } on HttpException {
      // Receiver cancelled a request while seeking/disconnecting.
    } catch (_) {
      // Socket cancellation must not become an unhandled asynchronous error.
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  }
}

/// Inclusive endpoints. Reject multiple ranges, negatives and unsatisfiable
/// ranges rather than silently sending the wrong part of a track.
(int, int)? parseCastByteRange(String? header, int length) {
  if (header == null) return (0, length - 1);
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null || length <= 0) return null;
  final left = match[1]!;
  final right = match[2]!;
  if (left.isEmpty) {
    final suffix = int.tryParse(right);
    if (suffix == null || suffix <= 0) return null;
    return (max(0, length - suffix), length - 1);
  }
  final start = int.tryParse(left);
  final end = right.isEmpty ? length - 1 : int.tryParse(right);
  if (start == null || end == null || start >= length || end < start) {
    return null;
  }
  return (start, min(end, length - 1));
}
