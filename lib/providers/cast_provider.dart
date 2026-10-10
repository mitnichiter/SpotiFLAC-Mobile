import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/user_profile_provider.dart';
import 'package:spotiflac_android/services/cast/cast_service.dart';

final castServiceProvider = Provider<CastService>((ref) {
  final service = CastService();
  final subscription = service.events.listen((event) async {
    if (event['type'] != 'connected') return;
    try {
      final profile = await ref.read(userProfileProvider.future);
      service.username = profile.name;
      final handler = await ref.read(musicPlayerRuntimeProvider).initialize();
      await handler.useCast(service);
    } catch (e) {
      service.error = e.toString();
      service.reportError();
    }
  });
  ref.onDispose(() {
    unawaited(subscription.cancel());
    service.dispose();
  });
  return service;
});
