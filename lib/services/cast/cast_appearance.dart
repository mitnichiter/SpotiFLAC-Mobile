import 'package:flutter/material.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/theme/cover_palette.dart';

String _hex(Color color) =>
    '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';

/// The same muted gradient math as the phone's MornyePlayerBackground.
Map<String, Object> castArtworkGradient(Color? color) {
  final dominant = HSLColor.fromColor(color ?? const Color(0xff808080));
  final muted = dominant.withSaturation(dominant.saturation.clamp(0.0, 0.34));
  return {
    'backgroundStart': _hex(
      muted.withLightness(0.28 + dominant.lightness * 0.24).toColor(),
    ),
    'backgroundEnd': _hex(
      muted.withLightness(0.14 + dominant.lightness * 0.20).toColor(),
    ),
  };
}

Future<Map<String, Object>> resolveCastArtworkGradient(String? source) async {
  if (source == null) return castArtworkGradient(null);
  await CoverPalette.resolve(source, Brightness.dark);
  return castArtworkGradient(CoverPalette.sourceColor(source, Brightness.dark));
}

/// Export the resolved Flutter theme, not a second TV palette. Match the same
/// muted cover gradient used by MornyePlayerBackground on the phone.
Map<String, Object> castAppearance(BuildContext context, Uri? artwork) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final l10n = context.l10n;
  final source = artwork?.scheme == 'file'
      ? artwork!.toFilePath()
      : artwork?.toString();
  return {
    'style': context.isMornye ? 'mornye' : 'material',
    'surface': _hex(scheme.surface),
    'ink': _hex(context.isMornye ? Colors.white : scheme.onSurface),
    'muted': _hex(
      context.isMornye ? const Color(0xffb8b8b8) : scheme.onSurfaceVariant,
    ),
    'accent': _hex(scheme.primary),
    'onAccent': _hex(scheme.onPrimary),
    'font': theme.textTheme.bodyMedium?.fontFamily ?? 'system',
    ...castArtworkGradient(
      source == null ? null : CoverPalette.sourceColor(source, Brightness.dark),
    ),
    'reduceMotion': MediaQuery.disableAnimationsOf(context),
    'labels': {
      'player': l10n.nowPlayingTabPlayer,
      'lyrics': l10n.nowPlayingTabLyrics,
      'queue': l10n.nowPlayingUpNext,
      'previous': l10n.nowPlayingPreviousTrack,
      'next': l10n.nowPlayingNextTrack,
      'play': l10n.tooltipPlay,
      'pause': l10n.actionPause,
      'stop': l10n.castDisconnect,
      'volume': l10n.castVolume,
      'more': MaterialLocalizations.of(context).moreButtonTooltip,
    },
  };
}
