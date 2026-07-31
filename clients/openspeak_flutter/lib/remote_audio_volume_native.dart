import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

Future<void> setRemoteAudioTrackVolume(
  lk.RemoteAudioTrack track,
  double volume,
) => rtc.Helper.setVolume(volume, track.mediaStreamTrack);
