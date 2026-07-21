# OpenSpeak Flutter Client Prototype

Desktop prototype for the OpenSpeak server. The first pass targets Windows and
macOS with shared Flutter code.

## Current Features

- Enter a server with a local nickname and optional server password.
- Register a temporary desktop device for WebSocket presence.
- List OS servers.
- List channels for the selected server.
- List channel members.
- Connect to `/ws` and show realtime events.
- Show server presence snapshot.
- Join/update/leave voice state for the selected channel.
- Request a LiveKit `voice-token` for the selected channel.
- Join a LiveKit room and publish microphone audio.
- Sync microphone mute and listen-off controls with OpenSpeak voice state.

## Run

```bash
cd clients/openspeak_flutter
flutter run -d macos
```

If the project is on a NAS/shared disk and macOS codesign fails with
`resource fork, Finder information, or similar detritus not allowed`, run it
through the local-copy helper instead:

```bash
cd clients/openspeak_flutter
chmod +x tool/run_macos_local.sh
./tool/run_macos_local.sh
```

On Windows:

```powershell
cd clients\openspeak_flutter
flutter run -d windows
```

Use your server URL in the login screen, for example:

```text
http://127.0.0.1:27410
http://YOUR_SERVER_IP:27410
```

## Notes

- LiveKit audio join is implemented for the desktop prototype. Media E2EE,
  microphone device selection, and output device selection are still future work.
- macOS has the client network and microphone entitlements enabled. Screen
  recording entitlements should be added when screen sharing lands.
- For production, use HTTPS/WSS or certificate pinning/custom CA support in the
  client.
