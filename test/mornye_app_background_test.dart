import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/theme_provider.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/models/theme_settings.dart';
import 'package:spotiflac_android/widgets/mornye_app_background.dart';
import 'package:spotiflac_android/widgets/mornye_chrome.dart';
import 'package:spotiflac_android/widgets/mornye_player_background.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('AMOLED player keeps artwork above a pure black background', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({kUseAmoledKey: true});
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final capture = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: RepaintBoundary(
            key: capture,
            child: const MornyePlayerBackground(
              artUri: null,
              artwork: ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final bottom = (700 * image.width + 40) * 4;
      expect(
        [
          pixels.getUint8(bottom),
          pixels.getUint8(bottom + 1),
          pixels.getUint8(bottom + 2),
        ],
        [0, 0, 0],
      );
      final top = (40 * image.width + 40) * 4;
      expect(pixels.getUint8(top + 2), greaterThan(pixels.getUint8(top)));
      image.dispose();
    });
    expect(tester.takeException(), isNull);
  });
  testWidgets('secondary labels stay readable on artwork-colored glass', (
    tester,
  ) async {
    final capture = GlobalKey();
    for (final brightness in Brightness.values) {
      for (final color in [Colors.blue, Colors.amber, Colors.grey]) {
        final theme = MornyeTheme.build(brightness);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: theme,
              home: RepaintBoundary(
                key: capture,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MornyeAmbientCanvas(color: color),
                    const Center(
                      child: MornyeGlassPanel(
                        child: SizedBox(width: 240, height: 160),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          for (final point in [const Offset(40, 40), const Offset(400, 300)]) {
            final offset =
                (point.dy.toInt() * image.width + point.dx.toInt()) * 4;
            final background = Color.fromARGB(
              255,
              pixels.getUint8(offset),
              pixels.getUint8(offset + 1),
              pixels.getUint8(offset + 2),
            );
            final label = theme.colorScheme.onSurfaceVariant.computeLuminance();
            final backdrop = background.computeLuminance();
            final contrast = label > backdrop
                ? (label + 0.05) / (backdrop + 0.05)
                : (backdrop + 0.05) / (label + 0.05);
            expect(
              contrast,
              greaterThanOrEqualTo(4.5),
              reason: '$brightness, $color, $point',
            );
          }
          image.dispose();
        });
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets(
    'ambient canvas remains visible behind settings and pushed pages',
    (tester) async {
      final capture = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentMediaItemProvider.overrideWith((ref) => Stream.value(null)),
          ],
          child: RepaintBoundary(
            key: capture,
            child: MaterialApp(
              theme: MornyeTheme.build(Brightness.dark),
              builder: (context, child) => MornyeAppBackground(child: child!),
              home: MornyeSettingsTheme(
                child: Scaffold(
                  body: Builder(
                    builder: (context) => Center(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const MornyeSettingsTheme(
                              child: Scaffold(
                                body: Center(child: Text('Details')),
                              ),
                            ),
                          ),
                        ),
                        child: const Text('Open'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> expectColoredBackground() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await tester.runAsync(() => boundary.toImage());
        final pixels = await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        final width = image!.width;
        image.dispose();
        // A flat black scaffold must not obscure the shared blue backdrop.
        final offset = (40 * width + 40) * 4;
        expect(pixels!.getUint8(offset + 2), greaterThan(20));
        expect(
          pixels.getUint8(offset + 2),
          greaterThan(pixels.getUint8(offset)),
        );
      }

      await expectColoredBackground();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Details'), findsOneWidget);
      await expectColoredBackground();
      Navigator.of(tester.element(find.text('Details'))).pop();
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      await expectColoredBackground();
      final container = ProviderScope.containerOf(
        tester.element(find.text('Open')),
      );
      await container.read(themeProvider.notifier).setUseAmoled(true);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final offset = (40 * image.width + 40) * 4;
        expect(
          [
            pixels.getUint8(offset),
            pixels.getUint8(offset + 1),
            pixels.getUint8(offset + 2),
          ],
          [0, 0, 0],
        );
        image.dispose();
      });
      await container.read(themeProvider.notifier).setUseAmoled(false);
      await tester.pumpAndSettle();
      await expectColoredBackground();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'contrast and reduced motion preferences also apply to the canvas',
    (tester) async {
      for (final forced in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: MornyeTheme.build(
              Brightness.dark,
              forceGlassEffects: forced,
            ),
            home: MediaQuery(
              data: const MediaQueryData(
                highContrast: true,
                disableAnimations: true,
              ),
              child: const MornyeAmbientCanvas(color: Colors.blue),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (forced) {
          for (final container in tester.widgetList<AnimatedContainer>(
            find.byType(AnimatedContainer),
          )) {
            expect(container.duration, Duration.zero);
          }
        } else {
          expect(
            tester
                .widget<ColoredBox>(
                  find.descendant(
                    of: find.byType(MornyeAmbientCanvas),
                    matching: find.byType(ColoredBox),
                  ),
                )
                .color,
            Colors.black,
          );
        }
        expect(
          MediaQuery.highContrastOf(
            tester.element(find.byType(MornyeAmbientCanvas)),
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );
}
