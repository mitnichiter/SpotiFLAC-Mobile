import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/cast/cast_media_server.dart';
import 'package:spotiflac_android/services/cast/cast_service.dart';
import 'package:spotiflac_android/utils/lyrics_parser.dart';

void main() {
  test(
    'range parser handles suffixes and rejects malformed/unsatisfiable ranges',
    () {
      expect(parseCastByteRange(null, 10), (0, 9));
      expect(parseCastByteRange('bytes=3-', 10), (3, 9));
      expect(parseCastByteRange('bytes=-4', 10), (6, 9));
      expect(parseCastByteRange('bytes=2-99', 10), (2, 9));
      for (final value in [
        'bytes=10-',
        'bytes=5-2',
        'bytes=-0',
        'bytes=0-1,3-4',
        'nonsense',
      ]) {
        expect(parseCastByteRange(value, 10), isNull);
      }
    },
  );
  test(
    'Cast URLs serve only registered files, support seeks and expire',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cast-media-test',
      );
      final file = File('${directory.path}/song.flac');
      await file.writeAsBytes(List.generate(100, (i) => i));
      final server = CastMediaServer();
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await server.close();
        await directory.delete(recursive: true);
      });
      await server.start('127.0.0.1');
      final url = server.register(file, 'audio/flac');
      final request = await client.getUrl(url);
      request.headers.set('Range', 'bytes=20-29');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(response.headers.value('Content-Range'), 'bytes 20-29/100');
      expect(
        await response.fold<List<int>>(
          [],
          (bytes, chunk) => bytes..addAll(chunk),
        ),
        List.generate(10, (i) => i + 20),
      );
      final head = await (await client.openUrl('HEAD', url)).close();
      expect(head.contentLength, 100);
      expect(await head.toList(), isEmpty);
      final unknown = await (await client.getUrl(
        url.replace(path: '/media/not-a-token'),
      )).close();
      expect(unknown.statusCode, 404);
      await unknown.drain<void>();
      final range = await client.getUrl(url);
      range.headers.set('Range', 'bytes=100-');
      final invalid = await range.close();
      expect(invalid.statusCode, 416);
      await invalid.drain<void>();
      server.retain({});
      final retired = await (await client.getUrl(url)).close();
      expect(retired.statusCode, 404);
      await retired.drain<void>();
    },
  );
  test(
    'phone loopback playback tunnels relay byte ranges to the receiver',
    () async {
      final origin = await HttpServer.bind('127.0.0.1', 0);
      origin.listen((request) async {
        expect(request.headers.value('range'), 'bytes=2-4');
        request.response.statusCode = 206;
        request.response.headers.set('Content-Range', 'bytes 2-4/10');
        request.response.contentLength = 3;
        request.response.add([2, 3, 4]);
        await request.response.close();
      });
      final relay = CastMediaServer();
      await relay.start('127.0.0.1');
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await relay.close();
        await origin.close(force: true);
      });
      final url = relay.registerProxy(
        Uri.parse('http://127.0.0.1:${origin.port}/track'),
        'audio/flac',
      );
      final request = await client.getUrl(url);
      request.headers.set('Range', 'bytes=2-4');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(response.headers.value('Content-Range'), 'bytes 2-4/10');
      expect(
        await response.fold<List<int>>(
          [],
          (bytes, chunk) => bytes..addAll(chunk),
        ),
        [2, 3, 4],
      );
    },
  );

  test('non-Latin lyrics are chunked within Cast message limits', () {
    final lyrics = ParsedLyrics(
      synced: true,
      wordSynced: false,
      lines: List.generate(
        300,
        (i) => LyricLine(
          time: Duration(seconds: i),
          text: '你好🎵' * 400,
          translation: 'Translation ' * 400,
        ),
      ),
      plainText: '',
    );
    final batches = castLyricsBatches(lyrics).toList();
    expect(batches.length, greaterThan(1));
    expect(batches.expand((b) => b).length, 300);
    for (final batch in batches) {
      expect(
        utf8
            .encode(
              jsonEncode({
                'type': 'lyrics',
                'mediaId': 'track',
                'lines': batch,
              }),
            )
            .length,
        lessThan(60000),
      );
    }
  });
  test('mime detection accepts supported formats and rejects DSD', () {
    expect(castAudioMime('/cache/audio', 'flac'), 'audio/flac');
    expect(
      castAudioMime('https://example.com/song.mp3?token=abc', null),
      'audio/mpeg',
    );
    expect(castAudioMime('/song.aac', null), 'audio/aac');
    expect(castAudioMime('/song.dsf', null), isNull);
  });
}
