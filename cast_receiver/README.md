# SpotiFLAC Google Cast receiver

This feature uses Android TV / Google TV's built-in Google Cast receiver. It does not install a TV application or mirror the phone screen.

The sender and receiver implement:

- The app’s landscape Now Playing layout, with Mornye/Material styling, its bundled fonts and sender-resolved theme colors, cover artwork, a Mornye background gradient derived from each cover that crossfades when tracks change (neutral when art is missing), player/lyrics/queue views, and a greeting from the app's local profile name. A blank name displays “Hello”.
- Playback, pause, seek, next/previous, TV volume, favorites, shuffle/repeat, queue selection and stop-casting controls. Existing mobile transport controls and the queue target the TV during a Cast session.
- Timed line highlighting and translations from the same embedded lyric metadata used by the mobile player. Plain lyrics remain scrollable. Missing lyrics show an empty state.
- Phone-to-TV delivery of local files, including SAF sources copied through the existing playback cache. HTTP byte ranges support seeking. The TV receives temporary capability URLs, not arbitrary access to the library.
- Paused playback on the phone when a Cast session ends. Music does not unexpectedly resume through the phone speaker.

## Required setup

A **custom Web Receiver application ID** is required for the custom UI. Google's Default Media Receiver cannot load this interface or our lyric protocol. Builds with no configured ID show that casting is unavailable; they do not pretend to provide the custom receiver through the default ID.

1. Host the entire `cast_receiver/` directory, including `fonts/`, on a publicly accessible HTTPS site. Serve JavaScript files with a JavaScript MIME type. The site must be accessible to the TV without sign-in. Static hosting works; the receiver has no backend.
   For GitHub Pages, enable Pages in the fork's **Settings → Pages**, choose the feature branch and root directory, then use the resulting site URL followed by `/cast_receiver/index.html`. Wait for the Pages deployment to finish and verify the URL opens. The source branch alone does not enable hosting.

2. Open the [Google Cast SDK Developer Console](https://cast.google.com/publish/). Register a **Custom Receiver** application using the full HTTPS URL to `index.html`. Record the eight-character application ID.
3. For an unpublished receiver, register the testing Cast device in the console and reboot it after registration. Check Google's current device testing requirements. The app ID alone does not authorize an unregistered test device.
4. Build the Android sender with that ID:

   ```sh
   export SPOTIFLAC_CAST_APP_ID=YOUR_APP_ID
   export SPOTIFLAC_RUST_ANDROID_ABIS=arm64-v8a
   export SPOTIFLAC_DISCORD_SDK=0 # optional development build without Discord
   flutter build apk --debug --target-platform android-arm64
   ```

   For a smaller optimized development APK, use the repository's documented development release build. It uses the normal package ID unless a separate build variant is configured; take care with the installed app's signing key.

5. Connect the phone and TV to the same Wi-Fi network, without client isolation. Set a name under Profile, start music in the internal player, open Now Playing, tap **Cast to TV**, and select the TV. On Android 17+, allow local network access when requested.

This workspace implementation has no assigned receiver application ID or hosted receiver URL. These are deployment inputs, not source-code bugs. An APK built without the ID cannot be used for a real custom-receiver session.

## Controls and lifecycle

Playback audio comes from the TV. The sender remains responsible for the existing queue, shuffle/repeat, next/previous and resolving local/SAF sources. Keep the phone connected and the app's playback service alive. The TV needs to reach the phone's ephemeral LAN HTTP port; isolated/guest Wi-Fi and VPN routing can block this.

The receiver supports keyboard/directional focus and Enter, plus standard Cast play/pause/seek media commands. Physical TV remotes vary in which key events their Cast receiver exposes; next/previous custom buttons need the mobile sender to remain connected. Real hardware remote behavior must be tested rather than inferred from a browser preview.

The LAN media server is bound to the phone's current local IPv4 address and only serves registered files under random session-scoped URLs. It stops on disconnect. It does not expose a directory browser or accept a user-supplied filesystem path. Local audio is transferred over the local network; custom receiver code and CAF load over HTTPS. Receiver firmware must support local HTTP media/artwork. A Wi-Fi address change requires reconnecting the session.

Cast playback depends on the TV's supported audio codecs. FLAC, MP3, AAC/M4A, WAV and Ogg are accepted for receiver decoding; capability varies by device and audio format. DSD is rejected. There is no transcoding, bit-perfect guarantee, AutoMix DSP on the TV, or lyric fetching from a new provider. A receiver load error is shown to the sender.

## Protocol

Custom namespace: `urn:x-cast:com.spotiflac.tv`.

LOAD `customData` includes `mediaId`, `greeting`, and the localized no-lyrics message. Messages carry `profile`, `lyricsReset`, lyric batches, and TV `command` requests for next/previous. Lyric batches are UTF-8 bounded below Cast's 64 KiB limit. Stale lyrics and media status are ignored by media ID. Receiver text uses DOM `textContent`, and artwork accepts only HTTP(S) URLs.

## Verification

```sh
node --test cast_receiver/protocol.test.js
flutter test test/cast_appearance_test.dart test/cast_service_test.dart test/cast_media_server_test.dart test/music_player_automix_test.dart test/audio_output_button_test.dart test/player_metadata_controller_test.dart
flutter analyze
```

The browser preview uses a CAF stub and invented track/lyrics to inspect layout. It does not verify Cast device discovery, receiver registration, LAN reachability, firmware codec support, sleep/background operation, or real TV remote input. These need a configured receiver and phone/TV testing.

Hardware checklist: connect/start/pause/seek, next/previous/automatic completion/repeat, profile greeting, timed and plain lyrics, missing cover/lyrics, SAF audio, TV volume, TV-side pause and remote focus, disconnect without speaker playback, phone sleep, connection loss and reconnect.
