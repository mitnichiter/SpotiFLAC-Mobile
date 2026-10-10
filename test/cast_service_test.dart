import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/cast/cast_appearance.dart';
import 'package:spotiflac_android/services/cast/cast_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a late cover cannot recolor a newer track or a disconnected session',
    () async {
      const channel = MethodChannel('test/cast');
      final pending = <String?, Completer<Map<String, Object>>>{};
      final messages = <Map<String, dynamic>>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'localAddress') return '127.0.0.1';
        if (call.method == 'message') {
          messages.add(
            jsonDecode((call.arguments as Map)['data'] as String)
                as Map<String, dynamic>,
          );
        }
        return null;
      });
      final service = CastService(
        channel: channel,
        artworkGradientResolver: (source) =>
            (pending[source] = Completer<Map<String, Object>>()).future,
      )..connected = true;
      addTearDown(() {
        service.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      service.setAppearance({'style': 'mornye', 'font': 'Inter'});
      Future<void> load(String id) => service.load(
        MediaItem(
          id: id,
          title: id,
          artUri: Uri.parse('https://example.com/$id.png'),
        ),
        'https://example.com/$id.mp3',
        Duration.zero,
      );
      await load('blue');
      await load('amber');
      pending['https://example.com/amber.png']!.complete(
        castArtworkGradient(Colors.amber),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        service.appearance['backgroundStart'],
        castArtworkGradient(Colors.amber)['backgroundStart'],
      );
      final count = messages.length;
      pending['https://example.com/blue.png']!.complete(
        castArtworkGradient(Colors.blue),
      );
      await Future<void>.delayed(Duration.zero);
      expect(messages.length, count);
      expect(
        service.appearance['backgroundStart'],
        castArtworkGradient(Colors.amber)['backgroundStart'],
      );
      // A phone-theme update must preserve the current track's resolved palette.
      service.setAppearance({
        'style': 'mornye',
        'font': 'Inter',
        'accent': '#ff2d55',
      });
      expect(
        service.appearance['backgroundStart'],
        castArtworkGradient(Colors.amber)['backgroundStart'],
      );
      await load('last');
      service.connected = false;
      final beforeDisconnect = messages.length;
      pending['https://example.com/last.png']!.complete(
        castArtworkGradient(Colors.red),
      );
      await Future<void>.delayed(Duration.zero);
      expect(messages.length, beforeDisconnect);
    },
  );
}
