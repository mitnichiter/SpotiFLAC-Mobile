import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/theme_provider.dart';
import 'package:spotiflac_android/theme/cover_palette.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';

/// One artwork-colored canvas behind the router, including menus and sheets.
/// Only artwork changes rebuild the background; playback ticks do not repaint it.
class MornyeAppBackground extends ConsumerWidget {
  const MornyeAppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!context.isMornye) return child;
    final theme = Theme.of(context);
    final amoled =
        theme.brightness == Brightness.dark &&
        ref.watch(themeProvider.select((settings) => settings.useAmoled));
    Widget withCanvas(Widget canvas) => Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(child: canvas),
        Theme(
          data: theme.copyWith(
            scaffoldBackgroundColor: Colors.transparent,
            appBarTheme: theme.appBarTheme.copyWith(
              backgroundColor: Colors.transparent,
            ),
          ),
          child: child,
        ),
      ],
    );
    // Pure black also skips artwork decoding/palette updates while enabled.
    if (amoled) return withCanvas(const ColoredBox(color: Colors.black));
    final artUri = ref.watch(
      currentMediaItemProvider.select((item) => item.value?.artUri),
    );
    final source = artUri?.scheme == 'file'
        ? artUri!.toFilePath()
        : artUri?.toString();
    return CoverPaletteBuilder(
      imageSource: source,
      builder: (context, _) => withCanvas(
        MornyeAmbientCanvas(
          color: source == null
              ? const Color(0xff3676c8)
              : CoverPalette.sourceColor(source, theme.brightness) ??
                    const Color(0xff3676c8),
        ),
      ),
    );
  }
}

/// Soft pools of cover color make frost visible without blurring another image
/// behind every page. Fixed placement also avoids continuous background motion.
class MornyeAmbientCanvas extends StatelessWidget {
  const MornyeAmbientCanvas({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (MornyeTheme.glassBlockedByHighContrast(context)) {
      return ColoredBox(color: dark ? Colors.black : Colors.white);
    }
    final hsl = HSLColor.fromColor(color);
    final saturated = hsl.withSaturation(hsl.saturation.clamp(0.0, 0.65));
    final primaryColor = saturated.withLightness(dark ? 0.30 : 0.83).toColor();
    final secondaryColor = saturated
        .withHue((hsl.hue + 48) % 360)
        .withLightness(dark ? 0.22 : 0.89)
        .toColor();
    // Equal HSL lightness can make yellow covers much brighter than blue.
    // Bound luminance so secondary text stays readable throughout the canvas.
    Color bounded(Color value) {
      if (!dark) return value;
      while (value.computeLuminance() > 0.075) {
        value = Color.lerp(value, Colors.black, 0.12)!;
      }
      return value;
    }

    final primary = bounded(primaryColor);
    final secondary = bounded(secondaryColor);
    final base = dark ? const Color(0xff10121b) : const Color(0xfff4f5fa);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 600);
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-0.95, -0.65),
          radius: 1.45,
          colors: [primary, base],
          stops: const [0, 1],
        ),
      ),
      child: AnimatedContainer(
        duration: duration,
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(1.0, 0.8),
            radius: 1.1,
            colors: [
              secondary.withValues(alpha: 0.85),
              secondary.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}
