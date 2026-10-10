import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/theme_settings.dart';
import 'package:spotiflac_android/providers/runtime_profile_provider.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/app_switch.dart';
import 'package:spotiflac_android/widgets/extension_repo_card.dart';
import 'package:spotiflac_android/widgets/mornye_chrome.dart';
import 'package:spotiflac_android/widgets/mornye_selection_pill.dart';

MornyeGlassLevel _levelFor({
  required bool lowEnd,
  required bool blur,
  required bool liquidCapable,
}) {
  final container = ProviderContainer(
    overrides: [
      lowEndDeviceProvider.overrideWithValue(lowEnd),
      // Device default or the user's "always use blur effects" override.
      backdropBlurEnabledProvider.overrideWithValue(blur),
      deviceSupportsLiquidGlassProvider.overrideWithValue(liquidCapable),
    ],
  );
  addTearDown(container.dispose);
  return container.read(mornyeGlassLevelProvider);
}

void main() {
  for (final level in [MornyeGlassLevel.liquid, MornyeGlassLevel.frosted]) {
    for (final clarity in [0.75, 1.0]) {
      testWidgets(
        'glass blurs sharp backdrop pixels ($level, clarity $clarity)',
        (tester) async {
          Future<int> backdropContrast(bool samplesBackdrop) async {
            final capture = GlobalKey();
            await tester.pumpWidget(
              ProviderScope(
                key: UniqueKey(),
                overrides: [mornyeGlassLevelProvider.overrideWithValue(level)],
                child: MaterialApp(
                  theme: MornyeTheme.build(
                    Brightness.dark,
                    glassClarity: clarity,
                    forceGlassEffects: true,
                  ),
                  home: MediaQuery(
                    data: const MediaQueryData(highContrast: true),
                    child: Center(
                      child: RepaintBoundary(
                        key: capture,
                        child: SizedBox(
                          width: 160,
                          height: 80,
                          child: Stack(
                            children: [
                              const Positioned.fill(
                                child: CustomPaint(painter: _StripeBackdrop()),
                              ),
                              Positioned(
                                left: 20,
                                top: 12,
                                width: 120,
                                height: 56,
                                child: MornyeGlass.navigation(
                                  blurEnabled: true,
                                  samplesBackdrop: samplesBackdrop,
                                  child: const SizedBox.expand(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            return (await tester.runAsync(() async {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(capture),
              );
              final image = await boundary.toImage();
              try {
                final bytes = (await image.toByteData())!;
                var darkest = 255;
                var lightest = 0;
                // Stay away from the curved rim; measure detail in the glass.
                for (var x = 44; x < 116; x++) {
                  final red = bytes.getUint8((40 * image.width + x) * 4);
                  if (red < darkest) darkest = red;
                  if (red > lightest) lightest = red;
                }
                return lightest - darkest;
              } finally {
                image.dispose();
              }
            }))!;
          }

          final transparentOnly = await backdropContrast(false);
          final blurred = await backdropContrast(true);
          expect(transparentOnly, greaterThan(20));
          expect(blurred, lessThan(transparentOnly / 2));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  test('runtime tiers map to Mornye glass levels', () {
    // Low tier: arm32-only or low-RAM Android.
    expect(
      _levelFor(lowEnd: true, blur: false, liquidCapable: false),
      MornyeGlassLevel.flat,
    );
    // Standard Android: frosted blur without shader passes.
    expect(
      _levelFor(lowEnd: false, blur: false, liquidCapable: false),
      MornyeGlassLevel.frosted,
    );
    // iOS runs the standard tier but keeps the full material.
    expect(
      _levelFor(lowEnd: false, blur: false, liquidCapable: true),
      MornyeGlassLevel.liquid,
    );
    // High-tier Android.
    expect(
      _levelFor(lowEnd: false, blur: true, liquidCapable: true),
      MornyeGlassLevel.liquid,
    );
    // "Always use blur effects" restores the full material on any tier.
    for (final lowEnd in [true, false]) {
      expect(
        _levelFor(lowEnd: lowEnd, blur: true, liquidCapable: false),
        MornyeGlassLevel.liquid,
      );
    }
  });

  for (final (forceGlass, reducedMotion) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    testWidgets('contrast override restores sheets and navigation '
        '(forced: $forceGlass, reduced motion: $reducedMotion)', (
      tester,
    ) async {
      bool? floatingNavigation;
      const sheetKey = ValueKey('contrast-sheet');
      const navigationKey = ValueKey('contrast-navigation');
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: MornyeTheme.build(
              Brightness.dark,
              forceGlassEffects: forceGlass,
            ),
            home: MediaQuery(
              data: MediaQueryData(
                highContrast: true,
                disableAnimations: reducedMotion,
              ),
              child: Builder(
                builder: (context) {
                  floatingNavigation = MornyeTabBar.usesLiquidGlass(
                    context,
                    blurEnabled: true,
                    liquidGlass: true,
                  );
                  return Scaffold(
                    body: Column(
                      children: [
                        const MornyeGlassPanel.overlay(
                          key: sheetKey,
                          child: SizedBox(width: 300, height: 100),
                        ),
                        MornyeTabBar(
                          key: navigationKey,
                          destinations: const [
                            NavigationDestination(
                              icon: Icon(Icons.home),
                              label: 'Home',
                            ),
                          ],
                          selectedIndex: 0,
                          onSelected: (_) {},
                          blurEnabled: true,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final key in [sheetKey, navigationKey]) {
        expect(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(BackdropFilter),
          ),
          forceGlass ? findsOneWidget : findsNothing,
        );
        expect(
          MediaQuery.highContrastOf(tester.element(find.byKey(key))),
          isTrue,
        );
      }
      expect(floatingNavigation, forceGlass && !reducedMotion);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('frosted level keeps blur but drops every shader surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceSupportsLiquidGlassProvider.overrideWithValue(false),
          backdropBlurEnabledProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                const MornyeGlass(
                  blurEnabled: true,
                  child: SizedBox(width: 200, height: 50),
                ),
                MornyeSegmentedControl(
                  labels: const ['One', 'Two'],
                  selectedIndex: 0,
                  onChanged: (_) {},
                ),
                AppSwitch(value: true, onChanged: (_) {}),
                Consumer(
                  builder: (context, ref, _) => MornyeTabBar(
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.home),
                        label: 'Home',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.music_note),
                        label: 'Library',
                      ),
                    ],
                    selectedIndex: 0,
                    onSelected: (_) {},
                    blurEnabled: ref.watch(mornyeBlurEnabledProvider),
                    liquidGlass: ref.watch(mornyeLiquidGlassProvider),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(MornyeSelectionPill), findsNWidgets(2));
    expect(find.byType(ImageFiltered), findsNothing);
    // The frosted material still samples the page behind it.
    expect(find.byType(BackdropFilter), findsWidgets);
    expect(find.text('Library'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear glass reduces blur and mid-range glass caps its radius', (
    tester,
  ) async {
    Future<ui.ImageFilter?> filterFor(double clarity, bool liquid) async {
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            mornyeGlassLevelProvider.overrideWithValue(
              liquid ? MornyeGlassLevel.liquid : MornyeGlassLevel.frosted,
            ),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.light, glassClarity: clarity),
            home: const MornyeGlass.navigation(
              blurEnabled: true,
              child: SizedBox(width: 200, height: 50),
            ),
          ),
        ),
      );
      final filters = tester.widgetList<BackdropFilter>(
        find.byType(BackdropFilter),
      );
      return filters.isEmpty ? null : filters.single.filter;
    }

    expect(await filterFor(0, false), isNull);
    expect(await filterFor(0.1, false), isNull);
    expect(await filterFor(0.25, false), isNull);
    expect(await filterFor(0.5, false), isNull);
    expect(await filterFor(0.1, true), isNull);
    expect(await filterFor(0.2, true), isNull);
    expect(
      await filterFor(0.25, true),
      ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
    );
    expect(
      await filterFor(kDefaultMornyeGlassClarity, true),
      ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
    );
    expect(
      await filterFor(1, false),
      ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
    );
    expect(await filterFor(1, true), ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8));
  });

  for (final clarity in [0.0, 0.5]) {
    testWidgets('liquid tab and segment pills follow clarity ($clarity)', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark, glassClarity: clarity),
            home: Scaffold(
              body: Builder(
                builder: (builderContext) {
                  context = builderContext;
                  return Column(
                    children: [
                      MornyeSegmentedControl(
                        labels: const ['One', 'Two'],
                        selectedIndex: 0,
                        onChanged: (_) {},
                      ),
                      MornyeTabBar(
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.home),
                            label: 'Home',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.music_note),
                            label: 'Library',
                          ),
                        ],
                        selectedIndex: 0,
                        onSelected: (_) {},
                        blurEnabled: true,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final liquid = clarity > 0;
      // Overlays aligned with the bar share this decision.
      expect(
        MornyeTabBar.usesLiquidGlass(
          context,
          blurEnabled: true,
          liquidGlass: true,
        ),
        liquid,
      );
      // Every tier draws just one copy of each label and a painted pill.
      expect(find.byType(MornyeSelectionPill), findsNWidgets(2));
      expect(find.byType(BackdropFilter), findsNWidgets(liquid ? 2 : 0));
      expect(find.text('Two'), findsOneWidget);
      expect(find.text('Library'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('plain-page panels keep the glass tint without a backdrop pass', (
    tester,
  ) async {
    Color? tintOf(Finder panel) {
      final decorated = tester
          .widgetList<DecoratedBox>(
            find.descendant(of: panel, matching: find.byType(DecoratedBox)),
          )
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((decoration) => decoration.color != null);
      return decorated.color;
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: const Scaffold(
            body: Column(
              children: [
                MornyeGlass.navigation(
                  key: ValueKey('sampled'),
                  blurEnabled: true,
                  child: SizedBox(width: 200, height: 40),
                ),
                MornyeGlass.navigation(
                  key: ValueKey('plain-page'),
                  blurEnabled: true,
                  samplesBackdrop: false,
                  child: SizedBox(width: 200, height: 40),
                ),
                ExtensionRepoCard(child: SizedBox(width: 200, height: 40)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final sampled = find.byKey(const ValueKey('sampled'));
    final plain = find.byKey(const ValueKey('plain-page'));
    expect(
      find.descendant(of: sampled, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: plain, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(ExtensionRepoCard),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
    // Same translucent material, so the page looks identical behind it.
    expect(tintOf(plain), tintOf(sampled));
    expect(tintOf(plain)!.a, lessThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('full-quality glass has one blur; switches have none', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                const MornyeGlass(
                  blurEnabled: true,
                  child: SizedBox(width: 200, height: 50),
                ),
                AppSwitch(value: true, onChanged: (_) {}),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AppSwitch),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

class _StripeBackdrop extends CustomPainter {
  const _StripeBackdrop();

  @override
  void paint(Canvas canvas, Size size) {
    for (var x = 0.0; x < size.width; x += 4) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 4, size.height),
        Paint()..color = (x / 4).toInt().isEven ? Colors.black : Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(_StripeBackdrop oldDelegate) => false;
}
