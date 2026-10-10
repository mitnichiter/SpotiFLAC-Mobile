import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/services/cast/cast_appearance.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';

void main() {
  for (final mornye in [false, true]) {
    testWidgets(
      'Cast carries the resolved ${mornye ? 'Mornye' : 'Material'} player appearance',
      (tester) async {
        final theme = mornye
            ? MornyeTheme.build(Brightness.dark)
            : ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xffff2d55),
                ),
              );
        late Map<String, Object> appearance;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                appearance = castAppearance(context, null);
                return const SizedBox();
              },
            ),
          ),
        );
        expect(appearance['style'], mornye ? 'mornye' : 'material');
        expect(
          appearance['accent'],
          '#${(theme.colorScheme.primary.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}',
        );
        expect((appearance['labels'] as Map)['queue'], 'Up next');
        if (mornye) {
          expect(appearance['font'], 'Inter');
          expect(appearance['ink'], '#ffffff');
        }
      },
    );
  }
  testWidgets(
    'TV gradients resolve from each cover and fall back without art',
    (tester) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'cast-palette-',
        );
        try {
          final gradients = <Map<String, Object>>[];
          for (final color in [Colors.blue, Colors.amber]) {
            final recorder = ui.PictureRecorder();
            Canvas(recorder).drawRect(
              const Rect.fromLTWH(0, 0, 32, 32),
              Paint()..color = color,
            );
            final picture = recorder.endRecording();
            final image = await picture.toImage(32, 32);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            picture.dispose();
            final file = File('${directory.path}/${gradients.length}.png');
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            final gradient = await resolveCastArtworkGradient(file.path);
            expect(gradient, castArtworkGradient(color));
            gradients.add(gradient);
          }
          expect(gradients[0], isNot(gradients[1]));
          expect(
            await resolveCastArtworkGradient(null),
            castArtworkGradient(null),
          );
          expect(
            await resolveCastArtworkGradient('${directory.path}/missing.png'),
            castArtworkGradient(null),
          );
        } finally {
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
          await directory.delete(recursive: true);
        }
      });
    },
  );
}
