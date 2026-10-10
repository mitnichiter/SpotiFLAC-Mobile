import 'dart:async';
import 'package:spotiflac_android/services/cast/cast_appearance.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/providers/cast_provider.dart';
import 'package:spotiflac_android/providers/user_profile_provider.dart';
import 'package:spotiflac_android/services/cast/cast_service.dart';

class CastButton extends ConsumerWidget {
  const CastButton({super.key, this.color, this.onPickerChanged});
  final Color? color;
  final ValueChanged<bool>? onPickerChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    final service = ref.watch(castServiceProvider);
    final art = ref.watch(
      currentMediaItemProvider.select((item) => item.value?.artUri),
    );
    service.setAppearance(castAppearance(context, art));
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => IconButton(
        tooltip: context.l10n.castTitle,
        color: service.connected
            ? Theme.of(context).colorScheme.primary
            : color,
        icon: Icon(service.connected ? Icons.cast_connected : Icons.cast),
        onPressed: () async {
          onPickerChanged?.call(true);
          try {
            await service.initialize();
            final profile = await ref.read(userProfileProvider.future);
            if (!context.mounted) return;
            await service.updateGreeting(
              profile.name,
              profile.name.trim().isEmpty
                  ? context.l10n.castHello
                  : context.l10n.castHelloName(profile.name.trim()),
              context.l10n.nowPlayingNoLyrics,
            );
            if (!context.mounted) return;
            await showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              isScrollControlled: true,
              builder: (_) => _CastPicker(service: service),
            );
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(context.l10n.castError(e.toString()))),
              );
            }
          } finally {
            onPickerChanged?.call(false);
          }
        },
      ),
    );
  }
}

class _CastPicker extends StatefulWidget {
  const _CastPicker({required this.service});
  final CastService service;
  @override
  State<_CastPicker> createState() => _CastPickerState();
}

class _CastPickerState extends State<_CastPicker> {
  double volume = 0.5;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    volume = widget.service.volume;
    if (widget.service.configured == true) {
      unawaited(_run(widget.service.discover));
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      widget.service.error = e.toString();
      widget.service.reportError();
    }
  }

  @override
  void dispose() {
    if (widget.service.configured == true) {
      unawaited(_run(widget.service.stopDiscovery));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.castTitle,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              if (service.configured != true)
                Text(l10n.castNotConfigured)
              else ...[
                Text(l10n.castSameWifi),
                const SizedBox(height: 16),
                if (service.connected) ...[
                  ListTile(
                    leading: const Icon(Icons.cast_connected),
                    title: Text(service.device),
                    subtitle: Text(service.greeting),
                  ),
                  Text(l10n.castVolume),
                  Slider(
                    value: volume,
                    onChanged: (v) => setState(() => volume = v),
                    onChangeEnd: (v) =>
                        unawaited(_run(() => service.setVolume(v))),
                  ),
                  FilledButton.tonal(
                    onPressed: () => _run(service.disconnect),
                    child: Text(l10n.castDisconnect),
                  ),
                ] else if (service.connecting) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(l10n.castConnecting),
                ] else if (service.routes.isEmpty) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(l10n.castSearching),
                ] else
                  ...service.routes.map(
                    (route) => ListTile(
                      leading: const Icon(Icons.tv),
                      title: Text(route.name),
                      onTap: busy
                          ? null
                          : () async {
                              setState(() => busy = true);
                              await _run(() => service.connect(route.id));
                              if (mounted) setState(() => busy = false);
                            },
                    ),
                  ),
                if (service.suspended) Text(l10n.castReconnecting),
                if (service.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      l10n.castError(service.error!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
