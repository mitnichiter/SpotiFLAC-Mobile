import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:spotiflac_android/controllers/player_metadata_controller.dart';
import 'package:spotiflac_android/services/cast/cast_media_server.dart';
import 'package:spotiflac_android/services/cast/cast_appearance.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/lyrics_parser.dart';

class CastRoute {
  const CastRoute(this.id, this.name);
  final String id, name;
}

/// Android SDK transports sessions; this class publishes UI state and supplies
/// LAN-readable media. No Google account or profile photo is sent to the TV.
class CastService extends ChangeNotifier {
  CastService({
    MethodChannel? channel,
    CastMediaServer? server,
    Future<Map<String, Object>> Function(String?)? artworkGradientResolver,
  }) : _channel = channel ?? const MethodChannel('com.zarz.spotiflac/cast'),
       _server = server ?? CastMediaServer(),
       _artworkGradientResolver =
           artworkGradientResolver ?? resolveCastArtworkGradient;

  final MethodChannel _channel;
  final CastMediaServer _server;
  final Future<Map<String, Object>> Function(String?) _artworkGradientResolver;
  Map<String, Object>? _artworkGradient;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  final _metadata = PlayerMetadataController();
  bool connected = false, connecting = false, suspended = false;
  bool? configured;
  double volume = 0.5;
  String device = '',
      username = '',
      greeting = 'Hello',
      noLyrics = 'No lyrics available';
  String? error;
  List<CastRoute> routes = const [];
  Map<String, Object> appearance = const {};
  String _appearanceJson = "";
  String? _mediaId;
  bool get hasLoadedMedia => _mediaId != null;
  bool _disposed = false;
  int _loadRevision = 0;
  final _artCopies = <String>[];
  Future<void> _loadTail = Future.value();
  Stream<Map<String, dynamic>> get events => _events.stream;

  Future<void> initialize() async {
    if (_subscription != null) return;
    _subscription = const EventChannel('com.zarz.spotiflac/cast_events')
        .receiveBroadcastStream()
        .listen(
          (value) {
            final event = Map<String, dynamic>.from(value as Map);
            switch (event['type']) {
              case 'status':
                volume =
                    (event['volume'] as num?)?.toDouble().clamp(0.0, 1.0) ??
                    volume;
              case 'routes':
                routes = (event['routes'] as List? ?? []).map((r) {
                  final row = Map<String, dynamic>.from(r as Map);
                  return CastRoute(row['id'] as String, row['name'] as String);
                }).toList();
              case 'connecting':
                connecting = true;
                error = null;
              case 'connected':
                connected = true;
                connecting = false;
                suspended = false;
                device = event['device'] as String? ?? '';
              case 'suspended':
                suspended = true;
              case 'disconnected':
                connected = false;
                connecting = false;
                suspended = false;
                _loadRevision++;
                _mediaId = null;
                _artworkGradient = null;
                unawaited(_server.close());
                unawaited(_deleteArtCopies());
              case 'error':
                error = event['message'] as String?;
            }
            _events.add(event);
            reportError();
          },
          onError: (Object e) {
            error = e.toString();
            reportError();
          },
        );
    configured = await _channel.invokeMethod<bool>('configured') ?? false;
    reportError();
  }

  void reportError() {
    if (!_disposed) notifyListeners();
  }

  void setAppearance(Map<String, Object> value) {
    value = {...value, ...?_artworkGradient};
    final encoded = jsonEncode(value);
    if (encoded == _appearanceJson) return;
    _appearanceJson = encoded;
    appearance = value;
    if (connected) {
      unawaited(
        send({'type': 'appearance', 'ui': value}).catchError((Object e) {
          error = e.toString();
          reportError();
        }),
      );
    }
  }

  void cancelPendingLoad() {
    _loadRevision++;
  }

  Future<void> discover() => _channel.invokeMethod<void>('discover');
  Future<void> stopDiscovery() => _channel.invokeMethod<void>('stopDiscovery');
  Future<void> connect(String id) =>
      _channel.invokeMethod<void>('connect', {'id': id});
  Future<void> disconnect() => _channel.invokeMethod<void>('disconnect');
  Future<void> play() => _channel.invokeMethod<void>('play');
  Future<void> pause() => _channel.invokeMethod<void>('pause');
  Future<void> stop() => _channel.invokeMethod<void>('stop');
  Future<void> seek(Duration position) => _channel.invokeMethod<void>('seek', {
    'positionMs': position.inMilliseconds,
  });
  Future<void> setVolume(double volume) =>
      _channel.invokeMethod<void>('volume', {'volume': volume.clamp(0.0, 1.0)});

  Future<void> send(Map<String, dynamic> data) =>
      _channel.invokeMethod<void>('message', {'data': jsonEncode(data)});

  Future<void> updateGreeting(
    String name,
    String hello,
    String emptyLyrics,
  ) async {
    username = name.trim();
    greeting = hello;
    noLyrics = emptyLyrics;
    if (connected) {
      await send({
        'type': 'profile',
        'greeting': greeting,
        'noLyrics': noLyrics,
        'ui': appearance,
      });
    }
  }

  Future<void> load(
    MediaItem item,
    String source,
    Duration position, {
    bool autoplay = true,
  }) {
    final revision = ++_loadRevision;
    final operation = _loadTail.then(
      (_) => _load(item, source, position, revision, autoplay),
    );
    _loadTail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _load(
    MediaItem item,
    String source,
    Duration position,
    int revision,
    bool autoplay,
  ) async {
    if (!connected || revision != _loadRevision) return;
    final mime = castAudioMime(source, item.extras?['format']?.toString());
    if (mime == null) {
      throw UnsupportedError(
        'This format is not supported by Google Cast. Use FLAC, WAV, MP3, AAC or Ogg.',
      );
    }
    await _server.start(
      await _channel.invokeMethod<String>('localAddress') ??
          (throw StateError('No Wi-Fi address')),
    );
    Uri media;
    final sourceUri = Uri.tryParse(source);
    if (sourceUri?.scheme == 'http' || sourceUri?.scheme == 'https') {
      media = {'localhost', '127.0.0.1', '::1'}.contains(sourceUri!.host)
          ? _server.registerProxy(sourceUri, mime)
          : sourceUri;
    } else {
      final file = File(
        sourceUri?.scheme == 'file' ? sourceUri!.toFilePath() : source,
      );
      if (!await file.exists()) {
        throw const FileSystemException('The audio file is unavailable');
      }
      media = _server.register(file, mime);
    }
    final urls = <Uri>{media};
    String? artwork;
    String? activeArtCopy;
    String? paletteSource;
    final art = item.artUri;
    if (art != null) {
      if (art.scheme == 'https' || art.scheme == 'http') {
        artwork = art.toString();
        paletteSource = artwork;
      } else {
        try {
          final path = art.scheme == 'content'
              ? await PlatformBridge.copyContentUriToTemp(art.toString())
              : art.scheme == 'file'
              ? art.toFilePath()
              : art.toString();
          if (path != null && await File(path).exists()) {
            if (art.scheme == 'content') {
              _artCopies.add(path);
              activeArtCopy = path;
            }
            paletteSource = path;
            final url = _server.register(
              File(path),
              path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg',
            );
            urls.add(url);
            artwork = url.toString();
          }
        } catch (_) {
          /* Artwork is optional. */
        }
      }
    }
    if (!connected || revision != _loadRevision) return;
    _mediaId = item.id;
    // Neutral until this track's extraction completes; never reuse the previous
    // cover. Resolve independently of whether the phone player is mounted.
    _artworkGradient = castArtworkGradient(null);
    setAppearance(appearance);
    await _channel.invokeMethod<void>('load', {
      'url': media.toString(),
      'mime': mime,
      'title': item.title,
      'artist': item.artist ?? '',
      'album': item.album ?? '',
      'artwork': artwork,
      'durationMs': item.duration?.inMilliseconds ?? 0,
      'positionMs': position.inMilliseconds,
      'autoplay': autoplay,
      'customData': jsonEncode({
        'mediaId': item.id,
        'greeting': greeting,
        'noLyrics': noLyrics,
        'ui': appearance,
      }),
    });
    if (connected && revision != _loadRevision) {
      // A pause/stop while LOAD was in flight must not leave the TV playing.
      try {
        await pause();
      } catch (_) {}
    }
    if (connected && revision == _loadRevision) {
      _server.retain(urls);
      final staleCopies = _artCopies
          .where((path) => path != activeArtCopy)
          .toList();
      _artCopies.removeWhere((path) => path != activeArtCopy);
      for (final path in staleCopies) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      unawaited(_sendLyrics(item, revision));
      unawaited(_updateArtworkGradient(paletteSource, revision));
    }
  }

  Future<void> _updateArtworkGradient(String? source, int revision) async {
    try {
      final gradient = await _artworkGradientResolver(source);
      if (_disposed || !connected || revision != _loadRevision) return;
      _artworkGradient = gradient;
      setAppearance(appearance);
    } catch (_) {
      // Artwork is optional; a decode failure keeps the neutral gradient.
    }
  }

  Future<void> _sendLyrics(MediaItem item, int revision) async {
    try {
      await _metadata.load(item, inspectUnresolvedContentUri: true);
      if (!connected || revision != _loadRevision || item.id != _mediaId) {
        return;
      }
      await send({
        'type': 'lyricsReset',
        'mediaId': item.id,
        'synced': _metadata.lyrics.synced,
      });
      for (final batch in castLyricsBatches(_metadata.lyrics)) {
        if (!connected || revision != _loadRevision) return;
        await send({'type': 'lyrics', 'mediaId': item.id, 'lines': batch});
      }
    } catch (e) {
      error = e.toString();
      reportError();
    }
  }

  Future<void> _deleteArtCopies() async {
    final paths = List.of(_artCopies);
    _artCopies.clear();
    for (final path in paths) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _disposed = true;
    connected = false;
    _loadRevision++;
    unawaited(_subscription?.cancel());
    unawaited(_server.close());
    unawaited(_deleteArtCopies());
    _metadata.dispose();
    unawaited(_events.close());
    super.dispose();
  }
}

String? castAudioMime(String source, String? format) {
  final ext =
      (format?.trim().isNotEmpty == true
              ? format!
              : Uri.tryParse(source)?.path.split('.').last ?? '')
          .toLowerCase();
  return switch (ext) {
    'flac' => 'audio/flac',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'm4a' || 'mp4' => 'audio/mp4',
    'aac' => 'audio/aac',
    'ogg' || 'opus' => 'audio/ogg',
    _ => null,
  };
}

/// Small UTF-8 messages stay under Cast's 64 KiB message limit, even for
/// non-Latin text. Full lyrics do not need a second mixed-content HTTP fetch.
Iterable<List<Map<String, Object?>>> castLyricsBatches(
  ParsedLyrics lyrics,
) sync* {
  final lines = lyrics.synced
      ? lyrics.lines.map(
          (line) => {
            'timeMs': line.time.inMilliseconds,
            'text': line.text,
            'translation': line.translation,
          },
        )
      : lyrics.plainText.split('\n').map((text) => {'timeMs': 0, 'text': text});
  var batch = <Map<String, Object?>>[];
  var bytes = 0;
  for (final line in lines) {
    final row = <String, Object?>{
      ...line,
      'text': String.fromCharCodes((line['text'] as String).runes.take(2000)),
    };
    if (row['translation'] is String) {
      row['translation'] = String.fromCharCodes(
        (row['translation'] as String).runes.take(2000),
      );
    }
    final count = utf8.encode(jsonEncode(row)).length + 1;
    if (batch.isNotEmpty && bytes + count > 24000) {
      yield batch;
      batch = [];
      bytes = 0;
    }
    batch.add(row);
    bytes += count;
  }
  if (batch.isNotEmpty) yield batch;
}
