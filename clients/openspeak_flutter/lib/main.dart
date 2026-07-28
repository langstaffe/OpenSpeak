import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, ValueListenable, defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart'
    show
        BrowserContextMenu,
        Clipboard,
        ClipboardData,
        FilteringTextInputFormatter,
        KeyDownEvent,
        KeyEvent,
        LengthLimitingTextInputFormatter,
        PhysicalKeyboardKey;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:path_provider/path_provider.dart';
import 'attachment_cache_service.dart';
import 'attachment_transfer_controller.dart';
import 'audio_attachment_metadata.dart';
import 'audio_device_monitor.dart';
import 'audio_playback_controller.dart';
import 'browser_actions.dart';
import 'channel_message_store.dart';
import 'client_audio_preferences.dart';
import 'client_link_preview.dart';
import 'client_log.dart';
import 'client_session_store.dart';
import 'device_identity_service.dart';
import 'direct_message.dart';
import 'local_profile_service.dart';
import 'microphone_activation.dart';
import 'openspeak_api.dart';
import 'os_context_menu.dart';
import 'os_theme.dart';
import 'owner_identity_service.dart';
import 'platform_open.dart';
import 'realtime_connection_controller.dart';
import 'saved_server_connection.dart';
import 'sound_effects.dart';
import 'unread_state_controller.dart';
import 'voice_session_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) await BrowserContextMenu.disableContextMenu();
  await ClientLog.initialize();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    ClientLog.error(
      'flutter',
      details.exception,
      details.stack ?? StackTrace.current,
    );
  };
  ui.PlatformDispatcher.instance.onError = (error, stackTrace) {
    ClientLog.error('platform', error, stackTrace);
    return false;
  };
  runZonedGuarded(
    () => runApp(const OpenSpeakApp()),
    (error, stackTrace) => ClientLog.error('zone', error, stackTrace),
  );
}

const defaultServerUrl = String.fromEnvironment(
  'OPENSPEAK_DEFAULT_SERVER_URL',
  defaultValue: 'http://127.0.0.1:27410',
);
const mobileWebBreakpoint = 720.0;
const unsupportedBrowserScreenShareMessage = '当前手机浏览器不支持屏幕共享';

bool useMobileWebLayout({required bool isWeb, required double width}) =>
    isWeb && width < mobileWebBreakpoint;

double? messageListCacheExtent({required bool isWeb, required double width}) =>
    useMobileWebLayout(isWeb: isWeb, width: width) ? null : 900;

int? imagePreviewCacheWidth({
  required bool isWeb,
  required double viewportWidth,
  required double sourceWidth,
  required double displayWidth,
  required double devicePixelRatio,
}) {
  if (!useMobileWebLayout(isWeb: isWeb, width: viewportWidth)) return null;
  return math.max(
    1,
    math.min(sourceWidth, displayWidth * devicePixelRatio).round(),
  );
}

String initialServerUrl() {
  if (!kIsWeb) return defaultServerUrl;
  final base = Uri.base;
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
  ).toString().replaceFirst(RegExp(r'/$'), '');
}

bool webLoginNeedsPasswordPrompt(Object error, {required bool isWeb}) =>
    isWeb &&
    error is OpenSpeakException &&
    error.code == 'invalid_server_password';

class LatestChannelJoinQueue {
  var _generation = 0;
  Future<void> _tail = Future<void>.value();

  int begin() => ++_generation;
  bool isCurrent(int generation) => generation == _generation;
  void invalidate() => _generation += 1;

  Future<bool> run(int generation, Future<void> Function() action) {
    var current = false;
    final queued = _tail.then((_) async {
      if (!isCurrent(generation)) return;
      await action();
      current = isCurrent(generation);
    });
    _tail = queued.catchError((_) {});
    return queued.then((_) => current);
  }
}

bool shouldFollowAuthoritativeVoiceChannel({
  required bool joined,
  required String? authoritativeChannelId,
  required String? localChannelId,
  required String? switchingTargetId,
}) =>
    joined &&
    authoritativeChannelId != null &&
    authoritativeChannelId != localChannelId &&
    authoritativeChannelId != switchingTargetId;

enum ChatScope { channel, direct }

bool channelChatIsVisible({
  required ChatScope chatScope,
  required String? selectedChannelId,
  required String channelId,
  required bool mobileWeb,
  required bool mobileChatOpen,
}) =>
    chatScope == ChatScope.channel &&
    selectedChannelId == channelId &&
    (!mobileWeb || mobileChatOpen);

bool channelMessageNeedsUnread({
  required String channelId,
  required String? currentChannelId,
  required bool chatVisible,
  required bool atBottom,
}) => channelId == currentChannelId && (!chatVisible || !atBottom);

List<String> encryptedChannelMessageEpochIds(
  Iterable<ChannelMessage> messages,
) => messages
    .where(
      (message) => message.encryptionMode == 'e2ee' && message.kind == 'text',
    )
    .map((message) => message.epochId)
    .toSet()
    .toList(growable: false);

enum TlsCertificateHealth { unknown, valid, expiring, expired }

TlsCertificateHealth tlsCertificateHealth(
  DateTime? expiresAt, {
  DateTime? now,
}) {
  if (expiresAt == null) return TlsCertificateHealth.unknown;
  final remaining = expiresAt.difference(now ?? DateTime.now());
  if (remaining <= Duration.zero) return TlsCertificateHealth.expired;
  if (remaining < const Duration(hours: 24)) {
    return TlsCertificateHealth.expiring;
  }
  return TlsCertificateHealth.valid;
}

enum SavedServerMenuAction { edit, delete }

enum ServerMenuAction { settings, members, claim, pair }

enum MemberContextAction {
  adjustVolume,
  makeAdmin,
  makeUser,
  kick,
  ban,
  forceMute,
  forceDeafen,
}

enum ChannelContextAction { create, edit, delete }

enum ChannelMessageContextAction { retract, delete }

ChannelMessageContextAction? channelMessageContextAction({
  required bool mine,
  required bool canManageOthers,
  required bool pending,
  bool canRetractOwn = true,
}) {
  if (pending) return null;
  if (mine && canRetractOwn) return ChannelMessageContextAction.retract;
  if (mine && canManageOthers) return ChannelMessageContextAction.delete;
  return canManageOthers ? ChannelMessageContextAction.delete : null;
}

ChannelMessageContextAction? directMessageContextAction({
  required bool mine,
  required bool pending,
}) => mine && !pending ? ChannelMessageContextAction.retract : null;

List<ServerMenuAction> serverMenuActions({
  required bool claimed,
  required bool isOwner,
  required Set<String> permissions,
  bool allowPairing = true,
}) => [
  if (!claimed) ServerMenuAction.claim,
  if (claimed && (isOwner || serverSettingsPages(permissions).isNotEmpty))
    ServerMenuAction.settings,
  if (claimed && (isOwner || permissions.contains('member.view')))
    ServerMenuAction.members,
  if (claimed && !isOwner && allowPairing) ServerMenuAction.pair,
];

List<String> serverSettingsPages(Set<String> permissions) => [
  if (permissions.contains('server.profile.update')) 'overview',
  if (permissions.contains('server.settings.update')) 'general',
  if (permissions.contains('server.transport.update')) 'transport',
  if (permissions.contains('audit.view')) 'audit',
];

List<MemberContextAction> memberContextActions({
  required bool currentUser,
  required bool canChangeRole,
  required String targetRole,
  bool inVoice = false,
  Set<String> permissions = const {},
}) {
  if (currentUser) return const [];
  return [
    MemberContextAction.adjustVolume,
    if (canChangeRole && targetRole == 'admin') MemberContextAction.makeUser,
    if (canChangeRole && targetRole == 'user') MemberContextAction.makeAdmin,
    if (inVoice && targetRole != 'owner' && permissions.contains('member.mute'))
      MemberContextAction.forceMute,
    if (inVoice &&
        targetRole != 'owner' &&
        permissions.contains('member.deafen'))
      MemberContextAction.forceDeafen,
    if (targetRole != 'owner' && permissions.contains('member.kick'))
      MemberContextAction.kick,
    if (targetRole != 'owner' && permissions.contains('member.ban'))
      MemberContextAction.ban,
  ];
}

String directEncryptionScope(
  String serverId,
  String firstUserId,
  String secondUserId,
) {
  final users = [firstUserId, secondUserId]..sort();
  return 'direct:$serverId:${users[0]}:${users[1]}';
}

String mediaEncryptionScope(String channelId) => 'media:$channelId';

class OpenSpeakApp extends StatelessWidget {
  const OpenSpeakApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'OpenSpeak',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF202225),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF5865F2),
          secondary: Color(0xFF3BA55D),
          surface: Color(0xFF2F3136),
        ),
        iconButtonTheme: IconButtonThemeData(style: osClickableButtonStyle()),
        textButtonTheme: TextButtonThemeData(style: osClickableButtonStyle()),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: osClickableButtonStyle(),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: osClickableButtonStyle(),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: osClickableButtonStyle(),
        ),
        menuButtonTheme: MenuButtonThemeData(style: osClickableButtonStyle()),
        dialogTheme: DialogThemeData(
          backgroundColor: OsColors.panel,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: OsColors.panelBorder),
          ),
          titleTextStyle: const TextStyle(
            color: OsColors.text,
            fontSize: 22,
            fontWeight: FontWeight.w900,
          ),
          contentTextStyle: const TextStyle(
            color: OsColors.muted,
            fontSize: 14,
            height: 1.45,
          ),
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: OsColors.panel,
          surfaceTintColor: Colors.transparent,
          elevation: 14,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: OsColors.panelBorder),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: OsColors.field,
          labelStyle: const TextStyle(color: OsColors.dim),
          hintStyle: const TextStyle(color: OsColors.icon),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 15,
            vertical: 15,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: OsColors.panelBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: OsColors.panelBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: OsColors.blurple, width: 1.5),
          ),
        ),
        useMaterial3: true,
      ),
      home: const OpenSpeakHome(),
    );
  }
}

class OpenSpeakHome extends StatefulWidget {
  const OpenSpeakHome({super.key});

  @override
  State<OpenSpeakHome> createState() => _OpenSpeakHomeState();
}

class _OpenSpeakHomeState extends State<OpenSpeakHome> {
  final serverUrlController = TextEditingController(text: initialServerUrl());
  final passwordController = TextEditingController();
  final activityScrollController = ScrollController();
  final channelScrollController = ScrollController();
  final messageController = TextEditingController();
  final messageScrollController = ScrollController();
  final attachmentCache = AttachmentCacheService();
  final soundEffects = SoundEffectPlayer();
  final ownerIdentity = OwnerIdentityService();
  final deviceIdentity = DeviceIdentityService();
  final localProfileService = LocalProfileService();
  final audioPreferences = ClientAudioPreferences();
  final pushToTalkHotkey = GlobalPushToTalkHotkey();

  OpenSpeakApi? api;
  Timer? realtimeStateRefreshTimer;
  Timer? channelEnvelopeRefreshTimer;
  int channelSelectionGeneration = 0;
  final channelJoinQueue = LatestChannelJoinQueue();
  String? voiceChannelSwitchTargetId;
  AuthSession? session;
  Device? device;
  List<OsServer> servers = [];
  List<Channel> channels = [];
  PresenceSnapshot presence = PresenceSnapshot.empty();
  late final VoiceSessionController voiceSession;
  late final RealtimeConnectionController realtimeConnection;
  OsServer? selectedServer;
  Channel? selectedChannel;
  ChatScope chatScope = ChatScope.channel;
  String? selectedDirectUserId;
  VoiceState? myVoiceState;
  bool loading = false;
  String? error;
  bool attachmentDragActive = false;
  bool channelReorderSaving = false;
  bool serverMenuOpen = false;
  bool screenShareActionInFlight = false;
  bool screenShareCollapsed = false;
  bool screenShareWindowOpen = false;
  int mobileTabIndex = 0;
  bool mobileChatOpen = false;
  bool mobileVoiceSheetOpen = false;
  lk.VideoTrack? activeScreenShareTrack;
  OwnerStatus? selectedServerOwnerStatus;
  String currentServerRole = 'user';
  Set<String> currentServerPermissions = <String>{};
  int messageRetractWindowMinutes = 30;
  final activity = <RealtimeEvent>[];
  final channelMessageStore = ChannelMessageStore();
  final channelKeys = <String, SecretKeyData>{};
  final channelKeyLoads = <String, Future<SecretKeyData>>{};
  final channelKeyEnvelopeArrivals = <String, Completer<void>>{};
  int channelKeyCoordinationGeneration = 0;
  final directMessageKeys = <String, SecretKeyData>{};
  E2EEDeviceIdentity? e2eeDeviceIdentity;
  String? mediaKeyReadyTransition;
  final directMessageStore = DirectMessageStore();
  final unreadState = UnreadStateController();
  final attachmentTransfers = AttachmentTransferController();
  final imagePreviewFutures = <String, Future<CachedImagePreview>>{};
  final linkPreviewFutures = <String, Future<LinkPreview?>>{};
  final audioMetadataFutures = <String, Future<AudioAttachmentMetadata>>{};
  List<SavedServerConnection> savedConnections = [];
  SavedServerConnection? selectedConnection;
  String localDisplayName = 'user';
  File? localAvatarFile;
  int localAvatarRevision = 0;
  String? selectedAudioInputDeviceId;
  String? selectedAudioOutputDeviceId;
  double audioInputVolume = 1.0;
  double audioOutputVolume = 1.0;
  double soundEffectVolume = 1.0;
  bool noiseSuppressionEnabled = true;
  MicrophoneActivationMode microphoneActivationMode =
      MicrophoneActivationMode.continuous;
  double microphoneThreshold = 0.4;
  MicrophoneHotkeyBinding? microphonePushToTalkHotkey;
  final Map<String, double> memberOutputVolumes = {};
  late final AudioPlaybackController audioPlayback;
  int currentChatNewMessages = 0;
  int connectionGeneration = 0;
  late final AudioDeviceMonitor audioDeviceMonitor;
  late final MutedSpeechReminder mutedSpeechReminder;
  VoiceSessionSnapshot previousVoiceSoundSnapshot =
      VoiceSessionSnapshot.initial();
  Timer? voiceDisconnectSoundTimer;
  bool voiceReconnectPending = false;
  bool voiceDisconnectSoundPlayed = false;
  bool audioDeviceErrorActive = false;
  bool webRtcWarningShown = false;

  @override
  void initState() {
    super.initState();
    realtimeConnection = RealtimeConnectionController()
      ..addListener(onRealtimeConnectionChanged);
    audioPlayback = AudioPlaybackController(
      isWeb: kIsWeb,
      connection: () => (api: api, session: session),
      localSourceFile: localAudioSourceFile,
      readRange: readAttachmentRange,
      downloadBytes: (attachment) => downloadAttachmentBytes(attachment),
    )..addListener(onAudioPlaybackChanged);
    mutedSpeechReminder = MutedSpeechReminder(onMutedSpeechWarning);
    audioDeviceMonitor = AudioDeviceMonitor(
      enumerateDevices: rtc.navigator.mediaDevices.enumerateDevices,
      registerDeviceChangeListener: registerAudioDeviceChangeListener,
      pollInterval: audioDevicePollInterval(defaultTargetPlatform),
    )..addListener(onAudioDevicesChanged);
    voiceSession = VoiceSessionController()..addListener(onVoiceSessionChanged);
    voiceSession.microphoneInputActive.addListener(onMicrophoneActivityChanged);
    pushToTalkHotkey.addListener(onPushToTalkHotkeyChanged);
    messageScrollController.addListener(onMessageScroll);
    if (kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(() async {
          try {
            await loadLocalProfile();
          } catch (exception) {
            ClientLog.write('profile', 'Web profile load failed: $exception');
          }
          if (mounted) await login();
        }());
      });
    } else {
      unawaited(loadSavedConnections());
      unawaited(loadLocalProfile());
    }
    unawaited(loadAudioDevicePreferences());
    unawaited(loadMemberOutputVolumes());
    unawaited(audioDeviceMonitor.start());
  }

  @override
  void dispose() {
    attachmentTransfers.cancelAndClear();
    realtimeConnection.removeListener(onRealtimeConnectionChanged);
    realtimeConnection.dispose();
    realtimeStateRefreshTimer?.cancel();
    resetChannelKeyCoordination();
    voiceDisconnectSoundTimer?.cancel();
    mutedSpeechReminder.dispose();
    audioDeviceMonitor.removeListener(onAudioDevicesChanged);
    audioDeviceMonitor.dispose();
    voiceSession.removeListener(onVoiceSessionChanged);
    voiceSession.microphoneInputActive.removeListener(
      onMicrophoneActivityChanged,
    );
    voiceSession.dispose();
    audioPlayback.removeListener(onAudioPlaybackChanged);
    audioPlayback.dispose();
    pushToTalkHotkey.removeListener(onPushToTalkHotkeyChanged);
    pushToTalkHotkey.dispose();
    unawaited(soundEffects.dispose());
    serverUrlController.dispose();
    passwordController.dispose();
    activityScrollController.dispose();
    channelScrollController.dispose();
    messageScrollController.removeListener(onMessageScroll);
    messageController.dispose();
    messageScrollController.dispose();
    super.dispose();
  }

  void onRealtimeConnectionChanged() {
    if (mounted) setState(() {});
  }

  void onAudioPlaybackChanged() {
    if (mounted) setState(() {});
  }

  void onVoiceSessionChanged() {
    if (!mounted) return;
    final previous = previousVoiceSoundSnapshot;
    final current = voiceSession.snapshot;
    previousVoiceSoundSnapshot = current;
    if (previous.listenOff != current.listenOff) {
      unawaited(
        soundEffects.play(
          current.listenOff ? SoundEffect.listenOff : SoundEffect.listenOn,
        ),
      );
    } else if (previous.muted != current.muted) {
      unawaited(
        soundEffects.play(
          current.muted ? SoundEffect.micMute : SoundEffect.micUnmute,
        ),
      );
    }
    if (!previous.reconnecting &&
        current.reconnecting &&
        !voiceReconnectPending) {
      voiceReconnectPending = true;
      voiceDisconnectSoundTimer?.cancel();
      voiceDisconnectSoundTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted ||
            !voiceReconnectPending ||
            voiceSession.snapshot.connected) {
          return;
        }
        voiceDisconnectSoundPlayed = true;
        unawaited(soundEffects.play(SoundEffect.voiceDisconnect));
      });
    } else if (current.connected && voiceReconnectPending) {
      voiceDisconnectSoundTimer?.cancel();
      if (voiceDisconnectSoundPlayed) {
        unawaited(soundEffects.play(SoundEffect.voiceReconnect));
      }
      voiceReconnectPending = false;
      voiceDisconnectSoundPlayed = false;
    }
    updateMutedSpeechReminder();
    final screenShareTrack = voiceSession.activeScreenShare?.track;
    setState(() {
      if (!identical(activeScreenShareTrack, screenShareTrack)) {
        activeScreenShareTrack = screenShareTrack;
        screenShareCollapsed = false;
      }
    });
  }

  void onMicrophoneActivityChanged() => updateMutedSpeechReminder();

  void updateMutedSpeechReminder() {
    final snapshot = voiceSession.snapshot;
    mutedSpeechReminder.update(
      muted: snapshot.muted,
      listenOff: snapshot.listenOff,
      active: voiceSession.microphoneInputActive.value,
    );
  }

  void onMutedSpeechWarning() {
    if (!mounted) return;
    unawaited(soundEffects.play(SoundEffect.mutedSpeaking));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('你已静音'), duration: Duration(seconds: 2)),
    );
  }

  void clearVoiceReconnectSound() {
    voiceDisconnectSoundTimer?.cancel();
    voiceDisconnectSoundTimer = null;
    voiceReconnectPending = false;
    voiceDisconnectSoundPlayed = false;
  }

  Future<void> showScreenShareWindow() async {
    if (screenShareWindowOpen || voiceSession.activeScreenShare == null) return;
    setState(() => screenShareWindowOpen = true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierColor: const Color(0xB8000000),
        builder: (_) => ScreenShareWindow(controller: voiceSession),
      );
    } finally {
      if (mounted) setState(() => screenShareWindowOpen = false);
    }
  }

  void onPushToTalkHotkeyChanged() {
    unawaited(voiceSession.setPushToTalkPressed(pushToTalkHotkey.pressed));
    if (mounted) setState(() {});
  }

  void onAudioDevicesChanged() {
    if (!mounted) return;
    if (!audioDeviceMonitor.lastRefreshSucceeded) {
      if (voiceSession.isJoined && !audioDeviceErrorActive) {
        audioDeviceErrorActive = true;
        unawaited(soundEffects.play(SoundEffect.error));
        setState(() => error = '无法读取音频设备，请检查麦克风权限');
      }
      return;
    }
    final next = audioDeviceSelectionAfterRefresh(
      inputDeviceId: selectedAudioInputDeviceId,
      outputDeviceId: selectedAudioOutputDeviceId,
      devices: audioDeviceMonitor.devices,
    );
    final restartDefaultInput =
        selectedAudioInputDeviceId == null &&
        audioDeviceMonitor.audioInputDevicesChanged &&
        audioDeviceMonitor.devices.any((device) => device.kind == 'audioinput');
    final inputAvailable = audioDeviceMonitor.devices.any(
      (device) => device.kind == 'audioinput',
    );
    if (voiceSession.isJoined && !inputAvailable && !audioDeviceErrorActive) {
      audioDeviceErrorActive = true;
      unawaited(soundEffects.play(SoundEffect.error));
      setState(() => error = '未发现可用麦克风');
    } else if (inputAvailable) {
      audioDeviceErrorActive = false;
    }
    ClientLog.write(
      'audio.devices',
      'selection input=${next.inputDeviceId ?? 'system'} '
          'remote=${voiceSession.snapshot.remoteParticipants} '
          'restart=$restartDefaultInput',
    );
    if (next.inputDeviceId == selectedAudioInputDeviceId &&
        next.outputDeviceId == selectedAudioOutputDeviceId) {
      setState(() {});
      if (restartDefaultInput || (kIsWeb && !inputAvailable)) {
        unawaited(
          setAudioDevices(
            next.inputDeviceId,
            next.outputDeviceId,
            restartInput: true,
            inputAvailable: inputAvailable,
          ),
        );
      }
      return;
    }
    // flutter_webrtc's native audio module returns to the operating-system
    // route when an active device disappears. Clearing the explicit IDs keeps
    // OpenSpeak on that default route instead of retrying a stale device.
    unawaited(
      setAudioDevices(
        next.inputDeviceId,
        next.outputDeviceId,
        restartInput: restartDefaultInput,
        inputAvailable: inputAvailable,
      ),
    );
  }

  Future<AuthSession> loginSession(
    OpenSpeakApi client,
    String displayName,
    String installationId,
  ) async {
    try {
      return await client.login(
        displayName,
        passwordController.text,
        clientInstallationId: installationId,
      );
    } catch (exception) {
      if (!webLoginNeedsPasswordPrompt(exception, isWeb: kIsWeb)) rethrow;
      return showWebPasswordDialog(client, displayName, installationId);
    }
  }

  Future<({AuthSession session, List<OsServer> servers})> loginAndLoadServers(
    OpenSpeakApi client,
    String displayName,
    String installationId,
  ) async {
    if (kIsWeb) {
      final cached = loadWebAuthSession();
      if (cached != null) {
        try {
          return (
            session: cached,
            servers: await client.listServers(cached.token),
          );
        } on OpenSpeakException catch (exception) {
          if (exception.statusCode != HttpStatus.unauthorized) rethrow;
        }
      }
      clearWebAuthSession();
    }
    final session = await loginSession(client, displayName, installationId);
    final servers = await client.listServers(session.token);
    if (kIsWeb) cacheWebAuthSession(session);
    return (session: session, servers: servers);
  }

  Future<AuthSession> showWebPasswordDialog(
    OpenSpeakApi client,
    String displayName,
    String installationId,
  ) async {
    final controller = TextEditingController();
    try {
      final result = await showDialog<AuthSession>(
        context: context,
        barrierDismissible: false,
        barrierColor: OsColors.rail,
        builder: (dialogContext) {
          var submitting = false;
          String? passwordError;
          return StatefulBuilder(
            builder: (context, setDialogState) {
              Future<void> submit() async {
                if (submitting) return;
                if (controller.text.isEmpty) {
                  setDialogState(() => passwordError = '请输入服务器密码');
                  return;
                }
                setDialogState(() {
                  submitting = true;
                  passwordError = null;
                });
                try {
                  final session = await client.login(
                    displayName,
                    controller.text,
                    clientInstallationId: installationId,
                  );
                  passwordController.text = controller.text;
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop(session);
                  }
                } catch (exception) {
                  if (!dialogContext.mounted) return;
                  setDialogState(() {
                    submitting = false;
                    passwordError =
                        webLoginNeedsPasswordPrompt(exception, isWeb: true)
                        ? '服务器密码错误'
                        : exception.toString();
                  });
                }
              }

              return PopScope(
                canPop: false,
                child: AlertDialog(
                  backgroundColor: OsColors.content,
                  title: const Text('连接 OpenSpeak'),
                  content: SizedBox(
                    width: 390,
                    child: TextField(
                      controller: controller,
                      autofocus: true,
                      obscureText: true,
                      enabled: !submitting,
                      decoration: InputDecoration(
                        labelText: '服务器密码',
                        errorText: passwordError,
                      ),
                      onSubmitted: (_) => unawaited(submit()),
                    ),
                  ),
                  actions: [
                    FilledButton(
                      onPressed: submitting ? null : () => unawaited(submit()),
                      child: submitting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('连接'),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
      if (result == null) throw OpenSpeakException('连接已取消');
      return result;
    } finally {
      controller.dispose();
    }
  }

  Future<void> showWebRtcWarningIfNeeded() async {
    if (!kIsWeb || webRtcWarningShown || browserSupportsWebRtc()) return;
    webRtcWarningShown = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: OsColors.content,
        title: const Text('浏览器不支持 WebRTC'),
        content: const Text(
          '当前浏览器未启用或不支持 WebRTC，语音和屏幕共享将无法使用。'
          '请启用 WebRTC，或更换支持 WebRTC 的浏览器后刷新页面。',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> login() async {
    final generation = ++connectionGeneration;
    channelJoinQueue.invalidate();
    await runGuarded(() async {
      var nextApi = OpenSpeakApi(
        kIsWeb ? initialServerUrl() : serverUrlController.text.trim(),
      );
      final discoveredSecureUrl = await nextApi.discoverSecureUrl();
      if (discoveredSecureUrl.isNotEmpty) {
        if (!isActiveConnectionGeneration(generation)) return;
        await persistSelectedConnectionUrl(discoveredSecureUrl);
        if (!isActiveConnectionGeneration(generation)) return;
        nextApi = OpenSpeakApi(discoveredSecureUrl);
      }
      final installationId = await loadOrCreateClientInstallationId();
      final displayName = localDisplayName.trim().isEmpty
          ? 'OpenSpeak User'
          : localDisplayName.trim();
      late AuthSession nextSession;
      late List<OsServer> nextServers;
      try {
        final result = await loginAndLoadServers(
          nextApi,
          displayName,
          installationId,
        );
        nextSession = result.session;
        nextServers = result.servers;
      } on OpenSpeakException catch (exception) {
        final canonicalBase = canonicalServerBaseUri(nextApi.baseUri, {
          'error': exception.code,
          'secure_url': exception.secureUrl,
          'plain_url': exception.plainUrl,
        });
        if (canonicalBase == null) rethrow;
        final canonicalUrl = canonicalBase.toString();
        if (!isActiveConnectionGeneration(generation)) return;
        await persistSelectedConnectionUrl(canonicalUrl);
        if (!isActiveConnectionGeneration(generation)) return;
        nextApi = OpenSpeakApi(canonicalUrl);
        final result = await loginAndLoadServers(
          nextApi,
          displayName,
          installationId,
        );
        nextSession = result.session;
        nextServers = result.servers;
      }
      final loginUserId = nextSession.user.id;
      if (!kIsWeb && nextServers.isNotEmpty) {
        final hasOwnerCredentialHint = await ownerIdentity.hasCredentialHint(
          nextServers.first.id,
        );
        final ownerCredential = hasOwnerCredentialHint
            ? await ownerIdentity.loadCredential(nextServers.first.id)
            : null;
        if (ownerCredential != null) {
          try {
            final challenge = await nextApi.createOwnerChallenge(
              nextSession.token,
              nextServers.first.id,
              method: 'device',
              deviceId: ownerCredential.deviceId,
            );
            final signature = await ownerIdentity.sign(
              ownerCredential,
              challenge.challenge,
            );
            nextSession = await nextApi.authenticateOwner(
              nextSession.token,
              nextServers.first.id,
              challengeId: challenge.id,
              signature: signature,
            );
            nextServers = await nextApi.listServers(nextSession.token);
          } on OpenSpeakException catch (exception) {
            if (exception.message.contains('HTTP 401')) {
              await ownerIdentity.deleteCredential(nextServers.first.id);
            }
          }
        }
      }
      // Owner device authentication can switch the ordinary installation
      // login to the stable owner identity. Sync only after that switch so the
      // avatar is cached on the identity that will actually enter the server.
      if (!kIsWeb) {
        nextSession = await syncLocalAvatarWithServer(nextApi, nextSession);
      }
      E2EEDeviceIdentity? e2eeIdentity;
      if (nextServers.isNotEmpty &&
          nextServers.first.encryptionMode == 'e2ee') {
        e2eeIdentity = await deviceIdentity.loadOrCreate(
          nextServers.first.id,
          userId: nextSession.user.id,
          migrateLegacyIdentity: nextSession.user.id == loginUserId,
        );
      }
      final nextDevice = await nextApi.registerDevice(
        nextSession.token,
        nextSession.user.id,
        kIsWeb ? 'OpenSpeak Web' : 'OpenSpeak Desktop Prototype',
        deviceId: e2eeIdentity?.deviceId ?? '',
        identityPublicKey: e2eeIdentity?.identityPublicKey ?? '',
        envelopePublicKey: e2eeIdentity?.envelopePublicKey ?? '',
      );
      if (!isActiveConnectionGeneration(generation)) return;
      attachmentCache.updateApi(nextApi);
      setState(() {
        api = nextApi;
        session = nextSession;
        device = nextDevice;
        e2eeDeviceIdentity = e2eeIdentity;
        servers = nextServers;
        selectedServer = nextServers.isEmpty ? null : nextServers.first;
        selectedChannel = null;
        mobileTabIndex = 0;
        mobileChatOpen = false;
        activity.clear();
      });
      await showWebRtcWarningIfNeeded();
      if (!isActiveConnectionGeneration(generation)) return;
      voiceSession.startServerLatencyMonitor(nextApi);
      if (nextServers.isNotEmpty) {
        await updateSelectedConnectionServerMetadata(nextServers.first);
      }
      if (selectedServer != null) {
        await loadServer(selectedServer!, generation: generation);
      }
    });
  }

  bool isActiveConnectionGeneration(int generation) {
    return mounted && generation == connectionGeneration;
  }

  Future<void> connectSavedConnection(SavedServerConnection connection) async {
    if (isCurrentSavedConnection(connection)) return;
    serverUrlController.text = connection.url;
    passwordController.text = connection.password;
    setState(() => selectedConnection = connection);
    await login();
  }

  bool isCurrentSavedConnection(SavedServerConnection connection) {
    return session != null &&
        selectedServer != null &&
        selectedConnection?.id == connection.id;
  }

  Future<void> disconnectCurrentServer() async {
    connectionGeneration += 1;
    channelJoinQueue.invalidate();
    resetChannelKeyCoordination();
    await leaveVoiceSession(clearVoiceState: true);
    voiceSession.stopServerLatencyMonitor();
    await realtimeConnection.close();
    if (!mounted) return;
    attachmentTransfers.cancelAndClear();
    setState(() {
      session = null;
      api = null;
      device = null;
      serverMenuOpen = false;
      selectedServer = null;
      selectedChannel = null;
      mobileTabIndex = 0;
      mobileChatOpen = false;
      selectedConnection = null;
      servers = [];
      channels = [];
      channelMessageStore.reset();
      channelKeys.clear();
      directMessageKeys.clear();
      e2eeDeviceIdentity = null;
      directMessageStore.reset();
      unreadState.reset();
      currentChatNewMessages = 0;
      attachmentTransfers.localSources.clear();
      imagePreviewFutures.clear();
      linkPreviewFutures.clear();
      audioMetadataFutures.clear();
      presence = PresenceSnapshot.empty();
      currentServerRole = 'user';
      currentServerPermissions = <String>{};
      activity.clear();
      error = null;
    });
    unawaited(audioPlayback.stop());
    attachmentCache.updateApi(null);
  }

  Future<void> loadSavedConnections() async {
    final loaded = await loadSavedServerConnections(
      onlyUrl: kIsWeb ? initialServerUrl() : null,
    );
    if (loaded == null) return;
    if (!mounted) return;
    setState(() => savedConnections = loaded);
  }

  Future<void> loadLocalProfile() async {
    final profile = await localProfileService.load(includeAvatar: !kIsWeb);
    if (!mounted) return;
    setState(() {
      if (profile.displayName case final String displayName
          when displayName.isNotEmpty) {
        localDisplayName = displayName;
      }
      if (!kIsWeb) {
        localAvatarFile = profile.avatar;
        if (profile.avatar != null) localAvatarRevision += 1;
      }
    });
  }

  Future<AuthSession> syncLocalAvatarWithServer(
    OpenSpeakApi client,
    AuthSession auth,
  ) async {
    final result = await localProfileService.syncAvatar(
      session: auth,
      upload: (file) => client.uploadCurrentUserAvatar(auth.token, file),
      download: () => client.downloadUserAvatar(
        auth.token,
        auth.user.id,
        auth.user.avatarVersion,
      ),
    );
    if (mounted && result.downloadedAvatar != null) {
      setState(() {
        localAvatarFile = result.downloadedAvatar;
        localAvatarRevision += 1;
      });
    }
    return result.session;
  }

  Future<void> loadAudioDevicePreferences() async {
    final preferences = await audioPreferences.load();
    audioInputVolume = preferences.inputVolume;
    audioOutputVolume = preferences.outputVolume;
    soundEffectVolume = preferences.soundEffectVolume;
    soundEffects.volume = soundEffectVolume;
    noiseSuppressionEnabled = preferences.noiseSuppressionEnabled;
    microphoneActivationMode = preferences.activationMode;
    microphoneThreshold = preferences.microphoneThreshold;
    microphonePushToTalkHotkey = preferences.pushToTalkHotkey;
    final selection = audioDeviceMonitor.hasLoaded
        ? audioDeviceSelectionAfterRefresh(
            inputDeviceId: preferences.inputDeviceId,
            outputDeviceId: preferences.outputDeviceId,
            devices: audioDeviceMonitor.devices,
          )
        : (
            inputDeviceId: preferences.inputDeviceId,
            outputDeviceId: preferences.outputDeviceId,
          );
    selectedAudioInputDeviceId = selection.inputDeviceId;
    selectedAudioOutputDeviceId = selection.outputDeviceId;
    await voiceSession.configureAudioDevices(
      inputDeviceId: selectedAudioInputDeviceId,
      outputDeviceId: selectedAudioOutputDeviceId,
      inputAvailable: !audioDeviceKindUnavailable(
        audioDeviceMonitor,
        'audioinput',
      ),
    );
    await voiceSession.setNoiseSuppressionEnabled(noiseSuppressionEnabled);
    await voiceSession.configureMicrophoneActivation(
      mode: microphoneActivationMode,
      threshold: microphoneThreshold,
    );
    await _applyPushToTalkHotkeyRegistration();
    await voiceSession.setOutputVolume(audioOutputVolume);
    if (mounted) setState(() {});
  }

  Future<bool> _applyPushToTalkHotkeyRegistration() async {
    final binding = microphonePushToTalkHotkey;
    if (microphoneActivationMode == MicrophoneActivationMode.pushToTalk &&
        binding != null) {
      return pushToTalkHotkey.register(binding);
    }
    await pushToTalkHotkey.clear();
    return true;
  }

  Future<void> loadMemberOutputVolumes() async {
    final loaded = await audioPreferences.loadMemberOutputVolumes();
    if (loaded == null) return;
    memberOutputVolumes
      ..clear()
      ..addAll(loaded);
    for (final entry in loaded.entries) {
      await voiceSession.setParticipantOutputVolume(entry.key, entry.value);
    }
    if (mounted) setState(() {});
  }

  double memberOutputVolume(String userId) =>
      memberOutputVolumes[userId] ?? 1.0;

  void previewMemberOutputVolume(String userId, double value) {
    final next = value.clamp(0.0, 2.0).toDouble();
    setState(() {
      if (next == 1.0) {
        memberOutputVolumes.remove(userId);
      } else {
        memberOutputVolumes[userId] = next;
      }
    });
    unawaited(voiceSession.setParticipantOutputVolume(userId, next));
  }

  Future<void> persistMemberOutputVolumes() async {
    await audioPreferences.saveMemberOutputVolumes(memberOutputVolumes);
  }

  Future<void> persistAudioDevicePreferences() async {
    await audioPreferences.saveDeviceSelection(
      inputDeviceId: selectedAudioInputDeviceId,
      outputDeviceId: selectedAudioOutputDeviceId,
    );
  }

  Future<void> setAudioInputVolume(double value) async {
    final next = value.clamp(0.0, 1.0).toDouble();
    setState(() => audioInputVolume = next);
    Future<void>? muteChange;
    if (next <= 0 && !voiceSession.snapshot.muted) {
      muteChange = setMuted(true);
    } else if (next > 0 && voiceSession.snapshot.muted) {
      muteChange = setMuted(false);
    }
    await audioPreferences.saveInputVolume(next);
    await muteChange;
  }

  Future<void> setAudioOutputVolume(double value) async {
    final next = value.clamp(0.0, 1.0).toDouble();
    setState(() => audioOutputVolume = next);
    Future<void>? listenChange;
    if (next <= 0 && !voiceSession.snapshot.listenOff) {
      listenChange = setListenOff(true);
    } else if (next > 0 && voiceSession.snapshot.listenOff) {
      listenChange = setListenOff(false);
    }
    final volumeChange = voiceSession.setOutputVolume(next);
    await audioPreferences.saveOutputVolume(next);
    await volumeChange;
    await listenChange;
  }

  Future<void> toggleNoiseSuppression() async {
    final previous = noiseSuppressionEnabled;
    final next = !previous;
    setState(() => noiseSuppressionEnabled = next);
    try {
      await voiceSession.setNoiseSuppressionEnabled(next);
      await audioPreferences.saveNoiseSuppression(next);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        noiseSuppressionEnabled = previous;
        error = '切换降噪失败: $e';
      });
    }
  }

  Future<void> persistSavedConnections() async {
    await saveSavedServerConnections(savedConnections);
  }

  Future<void> persistSelectedConnectionUrl(String url) async {
    if (url.isEmpty) return;
    serverUrlController.text = url;
    final connection = selectedConnection;
    if (connection == null || connection.url == url) return;
    final updated = connection.copyWith(url: url);
    if (!mounted) return;
    setState(() {
      selectedConnection = updated;
      savedConnections = savedConnections
          .map((item) => item.id == connection.id ? updated : item)
          .toList();
    });
    await persistSavedConnections();
  }

  Future<void> updateSelectedConnectionServerMetadata(OsServer server) async {
    final connection = selectedConnection;
    if (connection == null) return;
    final updated = connection.copyWith(
      name: server.name,
      serverId: server.id,
      avatarVersion: server.avatarVersion,
    );
    if (!mounted) return;
    setState(() {
      selectedConnection = updated;
      savedConnections = savedConnections
          .map((item) => item.id == connection.id ? updated : item)
          .toList();
    });
    await persistSavedConnections();
  }

  Future<void> addSavedConnection(SavedServerConnection connection) async {
    final next = [
      connection,
      ...savedConnections.where((item) => item.id != connection.id),
    ];
    setState(() {
      savedConnections = next;
      selectedConnection = connection;
    });
    await persistSavedConnections();
    await connectSavedConnection(connection);
  }

  Future<void> showAddServerDialog() async {
    if (kIsWeb) return;
    final addressController = TextEditingController();
    final portController = TextEditingController();
    final passwordController = TextEditingController(
      text: this.passwordController.text,
    );
    try {
      final connection = await showDialog<SavedServerConnection>(
        context: context,
        barrierColor: const Color(0xB8000000),
        builder: (context) => AddServerDialog(
          addressController: addressController,
          portController: portController,
          passwordController: passwordController,
        ),
      );
      if (connection != null) {
        await addSavedConnection(connection);
      }
    } finally {
      addressController.dispose();
      portController.dispose();
      passwordController.dispose();
    }
  }

  Future<void> showEditServerDialog(SavedServerConnection connection) async {
    final addressController = TextEditingController(
      text: serverHostFromUrl(connection.url),
    );
    final portController = TextEditingController(
      text: serverPortFromUrl(connection.url),
    );
    final passwordController = TextEditingController(text: connection.password);
    try {
      final updated = await showDialog<SavedServerConnection>(
        context: context,
        barrierColor: const Color(0xB8000000),
        builder: (context) => AddServerDialog(
          addressController: addressController,
          portController: portController,
          passwordController: passwordController,
          editing: true,
          scheme: parseServerUri(connection.url)?.scheme ?? 'http',
        ),
      );
      if (updated == null) return;
      final next = updated.id == connection.id
          ? updated.copyWith(
              name: connection.name,
              serverId: connection.serverId,
              avatarVersion: connection.avatarVersion,
            )
          : updated;
      final wasCurrent = isCurrentSavedConnection(connection);
      setState(() {
        savedConnections =
            savedConnections
                .where((item) => item.id != connection.id && item.id != next.id)
                .toList()
              ..insert(
                savedConnections
                    .indexOf(connection)
                    .clamp(0, savedConnections.length),
                next,
              );
        if (wasCurrent) selectedConnection = next;
      });
      await persistSavedConnections();
    } finally {
      addressController.dispose();
      portController.dispose();
      passwordController.dispose();
    }
  }

  Future<void> deleteSavedServer(SavedServerConnection connection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: OsColors.sidebar,
        title: const Text('删除服务器？'),
        content: Text('确定要从左侧列表删除“${connection.name}”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: OsColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (isCurrentSavedConnection(connection)) {
      await disconnectCurrentServer();
    }
    if (!mounted) return;
    setState(() {
      savedConnections = savedConnections
          .where((item) => item.id != connection.id)
          .toList();
    });
    await persistSavedConnections();
  }

  Future<void> showSavedServerContextMenu(
    SavedServerConnection connection,
    TapDownDetails details,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(details.globalPosition.dx, details.globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );
    final action = await showMenu<SavedServerMenuAction>(
      context: context,
      position: position,
      color: OsColors.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      constraints: const BoxConstraints(minWidth: 224),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: OsColors.panelBorder),
      ),
      items: const [
        PopupMenuItem(
          value: SavedServerMenuAction.edit,
          height: 58,
          child: OsPopupMenuRow(
            icon: Icons.edit_rounded,
            title: '编辑服务器',
            subtitle: '修改连接信息',
          ),
        ),
        PopupMenuItem(
          value: SavedServerMenuAction.delete,
          height: 58,
          child: OsPopupMenuRow(
            icon: Icons.delete_outline_rounded,
            title: '删除服务器',
            subtitle: '从本机列表移除',
            danger: true,
          ),
        ),
      ],
    );
    switch (action) {
      case SavedServerMenuAction.edit:
        await showEditServerDialog(connection);
      case SavedServerMenuAction.delete:
        await deleteSavedServer(connection);
      case null:
        return;
    }
  }

  Future<void> loadServer(OsServer server, {int? generation}) async {
    final client = api;
    final auth = session;
    final dev = device;
    if (client == null || auth == null || dev == null) return;
    final activeGeneration = generation ?? connectionGeneration;
    resetChannelKeyCoordination();
    await realtimeConnection.close();
    if (!isActiveConnectionGeneration(activeGeneration)) return;
    setState(() {
      error = null;
      selectedServer = server;
      selectedChannel = null;
      serverMenuOpen = false;
      selectedServerOwnerStatus = null;
      channels = [];
      chatScope = ChatScope.channel;
      selectedDirectUserId = null;
      mobileTabIndex = 0;
      mobileChatOpen = false;
      channelMessageStore.reset();
      channelKeys.clear();
      directMessageKeys.clear();
      directMessageStore.reset();
      unreadState.reset(serverId: server.id, userId: auth.user.id);
      currentChatNewMessages = 0;
      attachmentTransfers.localSources.clear();
      imagePreviewFutures.clear();
      linkPreviewFutures.clear();
      audioMetadataFutures.clear();
      attachmentTransfers.pendingLocalUploads.clear();
      attachmentTransfers.cancelAndClear();
      presence = PresenceSnapshot.empty(serverId: server.id);
      currentServerRole = 'user';
      currentServerPermissions = <String>{};
      myVoiceState = null;
    });
    await audioPlayback.stop();
    final initialState = await client.getServerState(auth.token, server.id);
    if (!isActiveConnectionGeneration(activeGeneration)) return;
    final targetChannel = channelForId(
      initialState.channels,
      initialState.currentUser.selectedChannelId,
    );
    if (targetChannel == null) {
      throw OpenSpeakException('服务器没有可进入的频道');
    }
    setState(() {
      channels = initialState.channels;
      presence = initialState.presence;
      currentServerRole = initialState.currentUser.role;
      currentServerPermissions = initialState.currentUser.permissions;
      myVoiceState = voiceStateForUser(initialState.presence, auth.user.id);
      selectedChannel = targetChannel;
    });
    await restoreUnreadState(server.id, auth.user.id);
    if (!isActiveConnectionGeneration(activeGeneration)) return;
    final websocketConnected = await connectWebSocket(
      client,
      auth,
      dev,
      server,
      expectedConnectionGeneration: activeGeneration,
    );
    if (!websocketConnected) return;
    if (!isActiveConnectionGeneration(activeGeneration)) return;
    if (!hasServerPermission('voice.join') &&
        hasServerPermission('channel.messages.view')) {
      await client.accessChannel(auth.token, targetChannel.id);
      if (!isActiveConnectionGeneration(activeGeneration)) return;
    }
    if (hasServerPermission('voice.join')) {
      await joinChannelAsCurrentUser(targetChannel);
    }
    if (!isActiveConnectionGeneration(activeGeneration)) return;
    await refreshServerState(generation: activeGeneration);
    if (!isActiveConnectionGeneration(activeGeneration)) return;
    await loadChannelMessages(channel: targetChannel);
    if (!isActiveConnectionGeneration(activeGeneration)) return;
    if (channelChatVisibleNow(targetChannel.id)) {
      setState(() => clearChannelUnread(targetChannel.id));
    }
    if (hasServerPermission('voice.join')) {
      await waitForCurrentUserOnline(server.id, generation: activeGeneration);
      if (!isActiveConnectionGeneration(activeGeneration)) return;
      await joinLiveKitVoice(generation: activeGeneration);
    }
  }

  Future<void> loadChannel(Channel channel, {bool join = false}) async {
    final client = api;
    final auth = session;
    if (client == null || auth == null) return;
    final selectionGeneration = ++channelSelectionGeneration;
    String? joinedChannelId;
    for (final user in presence.users) {
      if (user.userId == auth.user.id) {
        joinedChannelId = user.currentChannelId;
        break;
      }
    }
    final shouldJoin =
        join &&
        joinedChannelId != channel.id &&
        hasServerPermission('voice.join');
    final channelJoinGeneration = shouldJoin ? channelJoinQueue.begin() : null;
    final activeConnectionGeneration = connectionGeneration;
    if (selectedChannel?.id == channel.id && !shouldJoin) {
      if (chatScope == ChatScope.channel) return;
      setState(() {
        chatScope = ChatScope.channel;
        selectedDirectUserId = null;
        if (channelChatVisibleNow(channel.id)) clearChannelUnread(channel.id);
        messageController.clear();
      });
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => scrollMessagesToEnd(animated: false, settle: true),
      );
      return;
    }
    var switchVoice = false;
    var loadMessages = false;
    await runGuarded(() async {
      final previous = selectedChannel;
      final channelChanged = previous?.id != channel.id;
      if (channelChanged &&
          !shouldJoin &&
          hasServerPermission('channel.messages.view')) {
        await client.accessChannel(auth.token, channel.id);
      }
      if (shouldJoin) {
        final joinedLatest = await channelJoinQueue.run(
          channelJoinGeneration!,
          () async {
            if (!isActiveConnectionGeneration(activeConnectionGeneration)) {
              return;
            }
            await voiceSession.isolatePersistentRoomForChannelSwitch();
            await joinChannelAsCurrentUser(channel);
          },
        );
        if (!joinedLatest ||
            selectionGeneration != channelSelectionGeneration ||
            !isActiveConnectionGeneration(activeConnectionGeneration)) {
          return;
        }
        switchVoice = voiceSession.isJoined;
      }
      if (selectionGeneration != channelSelectionGeneration ||
          !isActiveConnectionGeneration(activeConnectionGeneration)) {
        return;
      }
      if (channelChanged || chatScope != ChatScope.channel) {
        setState(() {
          if (shouldJoin) retainChannelUnreadOnly(channel.id);
          selectedChannel = channel;
          chatScope = ChatScope.channel;
          if (channelChatVisibleNow(channel.id)) clearChannelUnread(channel.id);
          messageController.clear();
          if (channelChanged) channelMessageStore.reset();
        });
        loadMessages = channelChanged;
      }
      if (shouldJoin && !switchVoice) {
        await refreshServerState();
      }
    });
    if (channelJoinGeneration != null &&
        !channelJoinQueue.isCurrent(channelJoinGeneration)) {
      return;
    }
    if (switchVoice) await switchLocalVoiceChannel(channel);
    if (loadMessages) {
      await runGuarded(() => loadChannelMessages(channel: channel));
    }
  }

  Future<void> showChannelContextMenu(
    Offset globalPosition, {
    Channel? channel,
  }) async {
    final canCreate = channel == null && hasServerPermission('channel.create');
    final canEdit = channel != null && hasServerPermission('channel.edit');
    final canDelete =
        channel != null &&
        channels.length > 1 &&
        hasServerPermission('channel.delete');
    if (!canCreate && !canEdit && !canDelete) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<ChannelContextAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      color: OsColors.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      constraints: const BoxConstraints(minWidth: 224),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: OsColors.panelBorder),
      ),
      items: [
        if (canCreate)
          const PopupMenuItem(
            value: ChannelContextAction.create,
            height: 58,
            child: OsPopupMenuRow(
              icon: Icons.add_rounded,
              title: '创建频道',
              subtitle: '在服务器中添加新频道',
            ),
          ),
        if (canEdit)
          const PopupMenuItem(
            value: ChannelContextAction.edit,
            height: 58,
            child: OsPopupMenuRow(
              icon: Icons.edit_outlined,
              title: '编辑频道',
              subtitle: '修改频道名称',
            ),
          ),
        if (canDelete)
          const PopupMenuItem(
            value: ChannelContextAction.delete,
            height: 58,
            child: OsPopupMenuRow(
              icon: Icons.delete_outline_rounded,
              title: '删除频道',
              subtitle: '删除频道及其中的历史内容',
            ),
          ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case ChannelContextAction.create:
        await createOrEditChannel();
      case ChannelContextAction.edit:
        await createOrEditChannel(channel: channel);
      case ChannelContextAction.delete:
        await deleteExistingChannel(channel!);
    }
  }

  Future<void> createOrEditChannel({Channel? channel}) async {
    final client = api;
    final auth = session;
    final server = selectedServer;
    if (client == null || auth == null || server == null) return;
    final name = await showChannelNameDialog(channel: channel);
    if (name == null || !mounted) return;
    await runGuarded(() async {
      if (channel == null) {
        await client.createChannel(
          auth.token,
          server.id,
          name,
          sortOrder: channels.fold(
            0,
            (value, item) =>
                item.sortOrder >= value ? item.sortOrder + 1 : value,
          ),
        );
      } else {
        await client.updateChannelName(auth.token, channel.id, name);
      }
      await refreshServerState();
    });
  }

  Future<void> reorderChannelList(int oldIndex, int newIndex) async {
    final client = api;
    final auth = session;
    if (client == null ||
        auth == null ||
        channelReorderSaving ||
        !hasServerPermission('channel.reorder')) {
      return;
    }
    final reordered = channelsAfterMove(channels, oldIndex, newIndex);
    final previousSortOrders = {
      for (final channel in channels) channel.id: channel.sortOrder,
    };
    final changed = <Channel>[
      for (final channel in reordered)
        if (previousSortOrders[channel.id] != channel.sortOrder) channel,
    ];
    setState(() {
      channels = reordered;
      channelReorderSaving = true;
    });
    try {
      await Future.wait([
        for (final channel in changed)
          client.updateChannelSortOrder(
            auth.token,
            channel.id,
            channel.sortOrder,
          ),
      ]);
      await refreshServerState();
    } catch (exception) {
      if (mounted) setState(() => error = '$exception');
      try {
        await refreshServerState();
      } catch (_) {}
    } finally {
      if (mounted) setState(() => channelReorderSaving = false);
    }
  }

  Future<String?> showChannelNameDialog({Channel? channel}) async {
    final controller = TextEditingController(text: channel?.name ?? '');
    try {
      final value = await showDialog<String>(
        context: context,
        barrierColor: const Color(0xC7000000),
        builder: (context) => OsSettingsDialog(
          icon: channel == null ? Icons.add_rounded : Icons.edit_outlined,
          eyebrow: '频道管理',
          title: channel == null ? '创建频道' : '编辑频道',
          subtitle: channel == null ? '输入新频道的名称。' : '修改“${channel.name}”的名称。',
          maxWidth: 480,
          resizable: false,
          actions: [
            OsSecondaryButton(
              label: '取消',
              onPressed: () => Navigator.pop(context),
            ),
            OsPrimaryButton(
              label: channel == null ? '创建频道' : '保存更改',
              icon: channel == null ? Icons.add_rounded : Icons.check_rounded,
              onPressed: () => Navigator.pop(context, controller.text),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const OsFieldLabel('频道名称'),
              const SizedBox(height: 7),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 100,
                decoration: const InputDecoration(
                  hintText: '输入频道名称',
                  prefixIcon: Icon(Icons.tag_rounded, size: 20),
                ),
                onSubmitted: (value) => Navigator.pop(context, value),
              ),
            ],
          ),
        ),
      );
      final trimmed = value?.trim();
      if (trimmed == null || trimmed.isEmpty || trimmed == channel?.name) {
        return null;
      }
      return trimmed;
    } finally {
      controller.dispose();
    }
  }

  Future<void> deleteExistingChannel(Channel channel) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0xC7000000),
      builder: (context) => OsSettingsDialog(
        icon: Icons.delete_outline_rounded,
        eyebrow: '频道管理',
        title: '删除 ${channel.name}',
        subtitle: '频道及其中的历史消息将被永久删除。',
        maxWidth: 480,
        resizable: false,
        actions: [
          OsSecondaryButton(
            label: '取消',
            onPressed: () => Navigator.pop(context, false),
          ),
          OsPrimaryButton(
            label: '确认删除',
            icon: Icons.delete_outline_rounded,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
        child: const Text(
          '此操作无法撤销，当前在该频道中的成员也会离开频道。',
          style: TextStyle(color: OsColors.muted, height: 1.5),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final client = api;
    final auth = session;
    if (client == null || auth == null) return;
    final deletingSelectedChannel = selectedChannel?.id == channel.id;
    await runGuarded(() async {
      await client.deleteChannel(auth.token, channel.id);
      if (deletingSelectedChannel && voiceSession.isJoined) {
        await leaveVoiceSession(clearVoiceState: false);
      }
      await refreshServerState();
    });
  }

  Future<void> joinChannelAsCurrentUser(Channel channel) async {
    final client = api;
    final auth = session;
    if (client == null || auth == null) return;
    await client.joinChannel(auth.token, channel.id, userId: auth.user.id);
  }

  Future<void> waitForCurrentUserOnline(
    String serverId, {
    int? generation,
  }) async {
    final client = api;
    final auth = session;
    if (client == null || auth == null) return;
    for (var attempt = 0; attempt < 12; attempt += 1) {
      final nextState = await client.getServerState(auth.token, serverId);
      if (generation != null && !isActiveConnectionGeneration(generation)) {
        return;
      }
      final isOnline = nextState.onlineUsers.any(
        (user) => user.userId == auth.user.id,
      );
      if (!mounted) return;
      applyServerState(nextState);
      if (isOnline) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  Channel? channelForId(
    List<Channel> nextChannels,
    String? channelId, {
    bool fallbackToFirst = true,
  }) {
    if (nextChannels.isEmpty) return null;
    if (channelId != null && channelId.isNotEmpty) {
      for (final channel in nextChannels) {
        if (channel.id == channelId) return channel;
      }
    }
    return fallbackToFirst ? nextChannels.first : null;
  }

  Future<bool> connectWebSocket(
    OpenSpeakApi client,
    AuthSession auth,
    Device dev,
    OsServer server, {
    int? expectedConnectionGeneration,
  }) async {
    return realtimeConnection.connect(
      open: () => client.openWebSocket(auth.token, dev.id, server.id),
      canActivate: expectedConnectionGeneration == null
          ? null
          : () => isActiveConnectionGeneration(expectedConnectionGeneration),
      handleEvent: handleRealtimeEvent,
      onError: (exception, stackTrace) {
        ClientLog.error('realtime.websocket', exception, stackTrace);
        if (mounted) {
          setState(() => error = 'WebSocket disconnected: $exception');
        }
      },
      onDisconnected: (generation, closeCode, closeReason) {
        if (!mounted) return;
        ClientLog.write(
          'realtime.websocket',
          'closed code=$closeCode reason=${closeReason ?? ''}',
        );
        unawaited(reconnectWebSocketAfterDrop(generation));
      },
    );
  }

  void scheduleRealtimeStateRefresh() {
    if (realtimeStateRefreshTimer != null) return;
    final generation = connectionGeneration;
    realtimeStateRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      realtimeStateRefreshTimer = null;
      unawaited(
        refreshServerState(generation: generation).catchError((
          Object exception,
          StackTrace stackTrace,
        ) {
          ClientLog.error('realtime.state', exception, stackTrace);
        }),
      );
    });
  }

  void applyRealtimeVoiceEvent(RealtimeEvent event) {
    final raw = event.payload['state'];
    if (raw is! Map) {
      scheduleRealtimeStateRefresh();
      return;
    }
    try {
      final state = VoiceState.fromJson(raw.cast<String, dynamic>());
      final previousState = presence.voiceStates
          .where((item) => item.userId == state.userId)
          .firstOrNull;
      final inCurrentVoiceChannel =
          state.channelId == voiceSession.currentChannelId;
      if (state.userId != session?.user.id && inCurrentVoiceChannel) {
        if (event.type == 'voice.joined') {
          unawaited(soundEffects.play(SoundEffect.memberJoin));
        } else if (event.type == 'voice.left') {
          unawaited(soundEffects.play(SoundEffect.memberLeave));
        }
      }
      if (event.type == 'voice.state_changed' &&
          inCurrentVoiceChannel &&
          previousState != null &&
          previousState.screenSharing != state.screenSharing) {
        unawaited(
          soundEffects.play(
            state.screenSharing
                ? SoundEffect.screenShareStart
                : SoundEffect.screenShareStop,
          ),
        );
      }
      final voiceStates = presence.voiceStates
          .where((item) => item.userId != state.userId)
          .toList();
      if (event.type != 'voice.left') voiceStates.add(state);
      setState(() {
        presence = PresenceSnapshot(
          serverId: presence.serverId,
          users: presence.users,
          voiceStates: voiceStates,
        );
        if (state.userId == session?.user.id) {
          myVoiceState = event.type == 'voice.left' ? null : state;
        }
      });
      updateVoiceMediaRouting();
    } catch (_) {
      scheduleRealtimeStateRefresh();
    }
  }

  Future<bool> handleRealtimeEvent(RealtimeEvent event) async {
    if (kIsWeb && event.type == 'web.settings_changed') {
      await disconnectCurrentServer();
      if (mounted) {
        setState(() => error = '网页端配置已更改，请从新的访问地址重新进入');
      }
      return false;
    }
    setState(() {
      activity.insert(0, event);
      if (activity.length > 80) activity.removeLast();
    });
    if (event.type.startsWith('voice.')) {
      applyRealtimeVoiceEvent(event);
    } else if (event.type.startsWith('user.') ||
        event.type.startsWith('channel.presence_') ||
        event.type.startsWith('channel.access_') ||
        event.type == 'server.permissions_updated') {
      scheduleRealtimeStateRefresh();
    }
    if (event.type == 'voice.state_changed' &&
        event.fromUser == session?.user.id) {
      final state = event.payload['state'];
      if (state is Map<String, dynamic>) {
        final forcedDeafened = state['deafened'] == true;
        final forcedMuted = state['muted'] == true;
        final screenShareAccepted = state['screen_sharing'] == true;
        if (forcedDeafened && !voiceSession.snapshot.listenOff) {
          await voiceSession.setListenOff(true);
        } else if (forcedMuted && !voiceSession.snapshot.muted) {
          await voiceSession.setMuted(true);
        }
        if (!screenShareAccepted && voiceSession.isScreenSharing) {
          await voiceSession.stopScreenShare();
        }
      }
    }
    if (event.type == 'channel.message_created') {
      handleChannelMessage(event);
    }
    if (event.type == 'channel.message_deleted') {
      handleChannelMessageDeleted(event);
    }
    if (event.type == 'e2ee.envelope_created') {
      handleChannelEnvelopeCreated(event);
    }
    if (event.type == 'e2ee.media_envelope_created') {
      handleChannelEnvelopeCreated(event, media: true);
    }
    if (event.type == 'e2ee.key_requested') {
      unawaited(handleChannelKeyRequest(event));
    }
    if (event.type == 'e2ee.media_key_requested') {
      unawaited(handleChannelKeyRequest(event, media: true));
    }
    if (event.type == 'e2ee.media_key_activated') {
      unawaited(handleVoiceMediaKeyActivated(event));
    }
    if (event.type == 'e2ee.media_key_fallback') {
      unawaited(handleVoiceMediaKeyFallback(event));
    }
    if ((event.type == 'channel.access_granted' ||
            event.type == 'channel.epoch_changed') &&
        selectedServer?.encryptionMode == 'e2ee') {
      unawaited(handleChannelEpochChanged(event));
    }
    if (event.type == 'direct.file_expired') {
      handleDirectFileExpired(event);
    }
    if (event.type == 'direct.message_created') {
      await handleDirectMessage(event);
    }
    if (event.type == 'direct.message_deleted') {
      handleDirectMessageDeleted(event);
    }
    if (event.type == 'server.tls_enabled') {
      final secureUrl = event.payload['secure_url'] as String? ?? '';
      if (secureUrl.isNotEmpty) {
        await persistSelectedConnectionUrl(secureUrl);
        if (mounted) await login();
      }
      return false;
    }
    if (event.type == 'server.encryption_changed') {
      final plainUrl = event.payload['plain_url'] as String? ?? '';
      if (plainUrl.isNotEmpty) {
        await persistSelectedConnectionUrl(plainUrl);
      }
      if (mounted) await login();
      return false;
    }
    if (event.type == 'owner.credentials_revoked') {
      final serverId = selectedServer?.id;
      if (serverId != null) {
        await ownerIdentity.deleteCredential(serverId);
      }
      if (mounted) {
        setState(() => error = '本机的 owner 凭据已被服务端撤销');
      }
    }
    if ((event.type == 'member.kicked' || event.type == 'member.banned') &&
        event.fromUser == session?.user.id) {
      final message = event.type == 'member.banned'
          ? '你已被此服务器封禁'
          : '你已被服务器管理员踢出';
      await handleForcedServerDisconnect(message);
      return false;
    }
    return true;
  }

  Future<void> restoreRealtimeConnection(
    OpenSpeakApi client,
    AuthSession auth,
    Device dev,
    OsServer server,
    int activeConnectionGeneration,
  ) async {
    final voiceChannelId =
        voiceSession.snapshot.voiceState?.channelId ??
        voiceSession.snapshot.voiceToken?.channelId;
    final presenceChannelId = presence.users
        .where((user) => user.userId == auth.user.id)
        .firstOrNull
        ?.currentChannelId;
    final channel = channelForId(
      channels,
      voiceChannelId ?? presenceChannelId,
      fallbackToFirst: false,
    );
    final websocketConnected = await connectWebSocket(
      client,
      auth,
      dev,
      server,
      expectedConnectionGeneration: activeConnectionGeneration,
    );
    if (!websocketConnected ||
        !isActiveConnectionGeneration(activeConnectionGeneration)) {
      return;
    }
    if (channel != null) {
      await client.joinChannel(auth.token, channel.id, userId: auth.user.id);
    }
    if (!isActiveConnectionGeneration(activeConnectionGeneration)) return;
    if (channel != null && voiceSession.isJoined) {
      if (server.encryptionMode == 'e2ee') {
        final mediaState = await client.getChannelE2EEState(
          auth.token,
          channel.id,
          media: true,
        );
        if (!isActiveConnectionGeneration(activeConnectionGeneration)) return;
        final identity = e2eeDeviceIdentity;
        if (identity == null) return;
        await ensureChannelKey(
          channel,
          epochId: mediaState.epoch.id,
          media: true,
        );
        if (!isActiveConnectionGeneration(activeConnectionGeneration)) return;
        final refreshedToken = await client.getVoiceToken(
          auth.token,
          channel.id,
          deviceId: identity.deviceId,
          e2eeEpochId: mediaState.epoch.id,
        );
        if (!isActiveConnectionGeneration(activeConnectionGeneration)) return;
        if (realtimeReconnectRequiresVoiceRestart(
          e2eeServer: true,
          currentToken: voiceSession.snapshot.voiceToken,
          currentMediaEpochId: refreshedToken.e2eeEpochId,
          currentMediaKeyIndex: refreshedToken.e2eeKeyIndex,
          mediaKeySlots: refreshedToken.mediaKeySlots,
          refreshedToken: refreshedToken,
        )) {
          await joinLiveKitVoice(channel: channel, forceReconnect: true);
          return;
        }
        await voiceSession.setExternalVoiceToken(refreshedToken);
        if (refreshedToken.mediaKeySlots && !refreshedToken.e2eeKeyActive) {
          unawaited(
            completeVoiceMediaKeyTransition(
              channel,
              epochId: refreshedToken.e2eeEpochId,
              keyIndex: refreshedToken.e2eeKeyIndex,
            ),
          );
        }
      }
      final state = await voiceSession.restoreRealtimeState();
      if (!isActiveConnectionGeneration(activeConnectionGeneration)) return;
      setState(() => myVoiceState = state);
    }
    await refreshServerState(generation: activeConnectionGeneration);
  }

  Future<void> reconnectWebSocketAfterDrop(int generation) async {
    final connectionId = selectedConnection?.id;
    if (connectionId == null) return;
    var delay = const Duration(milliseconds: 500);
    while (mounted &&
        realtimeConnection.isCurrent(generation) &&
        !realtimeConnection.connected &&
        selectedConnection?.id == connectionId) {
      await Future<void>.delayed(delay);
      if (!mounted ||
          !realtimeConnection.isCurrent(generation) ||
          realtimeConnection.connected ||
          selectedConnection?.id != connectionId) {
        return;
      }
      final client = api;
      final auth = session;
      final dev = device;
      final server = selectedServer;
      if (client == null || auth == null || dev == null || server == null) {
        return;
      }
      try {
        await restoreRealtimeConnection(
          client,
          auth,
          dev,
          server,
          connectionGeneration,
        );
        return;
      } on OpenSpeakException catch (exception, stackTrace) {
        ClientLog.error('realtime.restore', exception, stackTrace);
        if (exception.statusCode == HttpStatus.unauthorized ||
            exception.statusCode == HttpStatus.forbidden ||
            exception.statusCode == HttpStatus.notFound ||
            exception.code == 'https_required' ||
            exception.code == 'http_required') {
          if (kIsWeb) {
            await disconnectCurrentServer();
            if (mounted) {
              setState(() => error = '网页端会话已失效，请重新进入');
            }
            return;
          }
          await login();
          return;
        }
        await realtimeConnection.closeForRetry();
      } catch (exception, stackTrace) {
        ClientLog.error('realtime.restore', exception, stackTrace);
        if (!realtimeConnection.isCurrent(generation)) {
          await realtimeConnection.closeForRetry();
        } else {
          try {
            await client.listServers(auth.token);
          } on OpenSpeakException catch (probeError) {
            if (probeError.statusCode == HttpStatus.unauthorized ||
                probeError.statusCode == HttpStatus.forbidden ||
                probeError.code == 'https_required' ||
                probeError.code == 'http_required') {
              if (kIsWeb) {
                await disconnectCurrentServer();
                if (mounted) {
                  setState(() => error = '网页端会话已失效，请重新进入');
                }
                return;
              }
              await login();
              return;
            }
          } catch (_) {}
        }
      }
      if (realtimeConnection.connected ||
          !realtimeConnection.isCurrent(generation)) {
        return;
      }
      delay = Duration(
        milliseconds: (delay.inMilliseconds * 2).clamp(500, 10000),
      );
    }
  }

  Future<void> handleForcedServerDisconnect(String message) async {
    await disconnectCurrentServer();
    if (!mounted) return;
    setState(() => error = message);
  }

  String channelKeyId(String channelId, String epochId, {bool media = false}) =>
      '$channelId:$epochId${media ? ':media' : ''}';

  void resetChannelKeyCoordination() {
    channelKeyCoordinationGeneration += 1;
    channelEnvelopeRefreshTimer?.cancel();
    channelEnvelopeRefreshTimer = null;
    channelKeyLoads.clear();
    for (final arrival in channelKeyEnvelopeArrivals.values) {
      if (!arrival.isCompleted) arrival.complete();
    }
    channelKeyEnvelopeArrivals.clear();
  }

  void handleChannelEnvelopeCreated(RealtimeEvent event, {bool media = false}) {
    final epochId = event.payload['epoch_id'] as String? ?? '';
    if (event.channelId.isEmpty || epochId.isEmpty) return;
    final key = channelKeyId(event.channelId, epochId, media: media);
    final arrival = channelKeyEnvelopeArrivals.remove(key);
    if (arrival != null && !arrival.isCompleted) arrival.complete();
    if (media || event.channelId != selectedChannel?.id) return;
    channelEnvelopeRefreshTimer?.cancel();
    channelEnvelopeRefreshTimer = Timer(const Duration(milliseconds: 150), () {
      channelEnvelopeRefreshTimer = null;
      if (!mounted || event.channelId != selectedChannel?.id) return;
      unawaited(loadChannelMessages(scrollToEnd: false));
    });
  }

  Future<SecretKeyData> ensureChannelKey(
    Channel channel, {
    String? epochId,
    bool media = false,
  }) async {
    if (epochId != null) {
      final cached =
          channelKeys[channelKeyId(channel.id, epochId, media: media)];
      if (cached != null) return cached;
    }
    final loadId = channelKeyId(channel.id, epochId ?? 'current', media: media);
    final pending = channelKeyLoads[loadId];
    if (pending != null) return pending;
    final coordinationGeneration = channelKeyCoordinationGeneration;
    final load = _loadChannelKey(
      channel,
      epochId: epochId,
      retry: 0,
      media: media,
      coordinationGeneration: coordinationGeneration,
    );
    channelKeyLoads[loadId] = load;
    try {
      return await load;
    } finally {
      if (identical(channelKeyLoads[loadId], load)) {
        channelKeyLoads.remove(loadId);
      }
    }
  }

  Future<SecretKeyData> _loadChannelKey(
    Channel channel, {
    String? epochId,
    required int retry,
    required bool media,
    required int coordinationGeneration,
  }) async {
    ensureChannelKeyCoordinationActive(coordinationGeneration);
    final client = api;
    final auth = session;
    final identity = e2eeDeviceIdentity;
    if (client == null || auth == null || identity == null) {
      throw OpenSpeakException('当前设备没有端到端加密密钥');
    }
    if (epochId != null) {
      final cached =
          channelKeys[channelKeyId(channel.id, epochId, media: media)];
      if (cached != null) return cached;
    }
    final state = await client.getChannelE2EEState(
      auth.token,
      channel.id,
      media: media,
    );
    ensureChannelKeyCoordinationActive(coordinationGeneration);
    final targetEpochId = epochId ?? state.epoch.id;
    final cached =
        channelKeys[channelKeyId(channel.id, targetEpochId, media: media)];
    if (cached != null) return cached;
    final envelopes = await client.listKeyEnvelopes(
      auth.token,
      channelId: channel.id,
      recipientDeviceId: identity.deviceId,
      media: media,
    );
    ensureChannelKeyCoordinationActive(coordinationGeneration);
    final envelope = envelopes
        .where((item) => item.epochId == targetEpochId)
        .firstOrNull;
    if (envelope != null) {
      if (envelope.senderIdentityPublicKey.isEmpty) {
        throw OpenSpeakException('无法验证频道密钥发送设备');
      }
      final key = await deviceIdentity.unwrapChannelKey(
        recipient: identity,
        channelId: media ? mediaEncryptionScope(channel.id) : channel.id,
        epochId: targetEpochId,
        senderDeviceId: envelope.senderDeviceId,
        senderIdentityPublicKey: envelope.senderIdentityPublicKey,
        ciphertext: envelope.ciphertext,
      );
      ensureChannelKeyCoordinationActive(coordinationGeneration);
      channelKeys[channelKeyId(channel.id, targetEpochId, media: media)] = key;
      if (targetEpochId == state.epoch.id) {
        await distributeMissingChannelKeys(channel, state, key, media: media);
      }
      return key;
    }
    if (targetEpochId != state.epoch.id) {
      throw OpenSpeakException('当前设备没有此历史周期的频道密钥');
    }
    if (state.devices.isEmpty ||
        !state.devices.any((item) => item.id == identity.deviceId)) {
      throw OpenSpeakException('当前设备尚未注册端到端加密公钥');
    }
    if (state.devices.any((item) => item.hasEnvelope)) {
      final arrivalId = !media && retry == 0
          ? channelKeyId(channel.id, targetEpochId, media: false)
          : null;
      final arrival = arrivalId == null
          ? null
          : channelKeyEnvelopeArrivals.putIfAbsent(
              arrivalId,
              Completer<void>.new,
            );
      if (!media || retry == 0) {
        try {
          await client.requestChannelKey(
            auth.token,
            channelId: channel.id,
            epochId: state.epoch.id,
            recipientDeviceId: identity.deviceId,
            media: media,
          );
        } on OpenSpeakException catch (exception) {
          if (arrivalId != null &&
              identical(channelKeyEnvelopeArrivals[arrivalId], arrival)) {
            channelKeyEnvelopeArrivals.remove(arrivalId);
          }
          if (retry == 0 && exception.code == 'key_not_required') {
            return _loadChannelKey(
              channel,
              epochId: epochId,
              retry: 1,
              media: media,
              coordinationGeneration: coordinationGeneration,
            );
          }
          rethrow;
        } catch (_) {
          if (arrivalId != null &&
              identical(channelKeyEnvelopeArrivals[arrivalId], arrival)) {
            channelKeyEnvelopeArrivals.remove(arrivalId);
          }
          rethrow;
        }
      }
      if (media && retry < 10) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _loadChannelKey(
          channel,
          epochId: epochId,
          retry: retry + 1,
          media: true,
          coordinationGeneration: coordinationGeneration,
        );
      }
      if (arrivalId != null && arrival != null) {
        try {
          await arrival.future.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          // The WebSocket event may be lost during a reconnect. Recheck the
          // server once before reporting that the key is still unavailable.
        } finally {
          if (identical(channelKeyEnvelopeArrivals[arrivalId], arrival)) {
            channelKeyEnvelopeArrivals.remove(arrivalId);
          }
        }
        return _loadChannelKey(
          channel,
          epochId: targetEpochId,
          retry: 1,
          media: false,
          coordinationGeneration: coordinationGeneration,
        );
      }
      throw OpenSpeakException('正在等待其他在线设备分发频道密钥');
    }
    final key = await deviceIdentity.newChannelKey();
    ensureChannelKeyCoordinationActive(coordinationGeneration);
    try {
      await client.storeKeyEnvelopeBatch(
        auth.token,
        channelId: channel.id,
        epochId: state.epoch.id,
        senderDeviceId: identity.deviceId,
        envelopes: await buildChannelKeyEnvelopes(
          state,
          identity,
          key,
          media: media,
        ),
        media: media,
      );
      ensureChannelKeyCoordinationActive(coordinationGeneration);
      channelKeys[channelKeyId(channel.id, state.epoch.id, media: media)] = key;
      return key;
    } on OpenSpeakException catch (exception) {
      if (retry == 0 && exception.code == 'envelope_conflict') {
        return _loadChannelKey(
          channel,
          epochId: epochId,
          retry: 1,
          media: media,
          coordinationGeneration: coordinationGeneration,
        );
      }
      rethrow;
    }
  }

  void ensureChannelKeyCoordinationActive(int generation) {
    if (generation != channelKeyCoordinationGeneration) {
      throw OpenSpeakException('频道密钥请求已取消');
    }
  }

  Future<List<KeyEnvelopeUpload>> buildChannelKeyEnvelopes(
    ChannelE2EEState state,
    E2EEDeviceIdentity identity,
    SecretKey channelKey, {
    Iterable<ChannelE2EEDevice>? recipients,
    bool media = false,
  }) async {
    final devices = recipients ?? state.devices;
    return Future.wait(
      devices.map(
        (recipient) async => KeyEnvelopeUpload(
          recipientUserId: recipient.userId,
          recipientDeviceId: recipient.id,
          ciphertext: await deviceIdentity.wrapChannelKey(
            sender: identity,
            channelId: media
                ? mediaEncryptionScope(state.epoch.channelId)
                : state.epoch.channelId,
            epochId: state.epoch.id,
            recipientDeviceId: recipient.id,
            recipientEnvelopePublicKey: recipient.envelopePublicKey,
            channelKey: channelKey,
          ),
        ),
      ),
    );
  }

  Future<void> distributeMissingChannelKeys(
    Channel channel,
    ChannelE2EEState state,
    SecretKey channelKey, {
    bool media = false,
  }) async {
    final client = api;
    final auth = session;
    final identity = e2eeDeviceIdentity;
    if (client == null || auth == null || identity == null) return;
    final current = state.devices
        .where((item) => item.id == identity.deviceId)
        .firstOrNull;
    final missing = state.devices.where((item) => !item.hasEnvelope).toList();
    if (current?.hasEnvelope != true || missing.isEmpty) return;
    try {
      await client.storeKeyEnvelopeBatch(
        auth.token,
        channelId: channel.id,
        epochId: state.epoch.id,
        senderDeviceId: identity.deviceId,
        envelopes: await buildChannelKeyEnvelopes(
          state,
          identity,
          channelKey,
          recipients: missing,
          media: media,
        ),
        media: media,
      );
    } on OpenSpeakException catch (exception) {
      if (exception.code != 'envelope_conflict') rethrow;
    }
  }

  Future<void> handleChannelKeyRequest(
    RealtimeEvent event, {
    bool media = false,
  }) async {
    final client = api;
    final auth = session;
    final identity = e2eeDeviceIdentity;
    final channel = channels
        .where((item) => item.id == event.channelId)
        .firstOrNull;
    if (client == null || auth == null || identity == null || channel == null) {
      return;
    }
    try {
      final state = await client.getChannelE2EEState(
        auth.token,
        channel.id,
        media: media,
      );
      final current = state.devices
          .where((item) => item.id == identity.deviceId)
          .firstOrNull;
      if (current?.hasEnvelope != true) return;
      final cached =
          channelKeys[channelKeyId(channel.id, state.epoch.id, media: media)];
      if (cached != null) {
        await distributeMissingChannelKeys(
          channel,
          state,
          cached,
          media: media,
        );
      } else {
        await ensureChannelKey(channel, epochId: state.epoch.id, media: media);
      }
    } catch (exception, stackTrace) {
      ClientLog.error('e2ee.key_request', exception, stackTrace);
    }
  }

  Future<void> handleChannelEpochChanged(RealtimeEvent event) async {
    final channel = channels
        .where((item) => item.id == event.channelId)
        .firstOrNull;
    if (channel == null) return;
    channelKeys.removeWhere((key, _) => key.startsWith('${channel.id}:'));
    if (hasServerPermission('channel.messages.view')) {
      try {
        await ensureChannelKey(channel);
      } catch (exception, stackTrace) {
        ClientLog.error('e2ee.epoch', exception, stackTrace);
      }
    }
    if (hasServerPermission('voice.join') &&
        voiceSession.isJoined &&
        voiceSession.currentChannelId == channel.id) {
      try {
        final client = api;
        final auth = session;
        if (client == null || auth == null) return;
        final state = await client.getChannelE2EEState(
          auth.token,
          channel.id,
          media: true,
        );
        final key = await ensureChannelKey(
          channel,
          epochId: state.epoch.id,
          media: true,
        );
        if (!state.mediaKeySlots) {
          await joinLiveKitVoice(channel: channel);
          return;
        }
        await voiceSession.stageE2EEMediaKey(
          key: Uint8List.fromList(await key.extractBytes()),
          epochId: state.epoch.id,
          keyIndex: state.mediaKeyIndex,
        );
        unawaited(
          completeVoiceMediaKeyTransition(
            channel,
            epochId: state.epoch.id,
            keyIndex: state.mediaKeyIndex,
          ),
        );
      } catch (exception, stackTrace) {
        ClientLog.error('e2ee.media_epoch', exception, stackTrace);
      }
    }
  }

  Future<void> completeVoiceMediaKeyTransition(
    Channel channel, {
    required String epochId,
    required int keyIndex,
  }) async {
    final client = api;
    final auth = session;
    final identity = e2eeDeviceIdentity;
    if (client == null || auth == null || identity == null) return;
    final transition = '${channel.id}:$epochId';
    if (mediaKeyReadyTransition == transition) return;
    mediaKeyReadyTransition = transition;
    try {
      var attempt = 0;
      while (mediaKeyReadyTransition == transition) {
        if (!mounted || voiceSession.currentChannelId != channel.id) return;
        try {
          final ready = await client.markMediaKeyReady(
            auth.token,
            channelId: channel.id,
            epochId: epochId,
            deviceId: identity.deviceId,
          );
          if (mediaKeyReadyTransition != transition) return;
          if (!ready.mediaKeySlots) {
            await joinLiveKitVoice(channel: channel);
            return;
          }
          if (ready.activated) {
            try {
              await voiceSession.activateE2EEMediaKey(
                epochId: epochId,
                keyIndex: ready.keyIndex,
              );
            } catch (exception, stackTrace) {
              ClientLog.error('e2ee.media_activate', exception, stackTrace);
              await joinLiveKitVoice(channel: channel);
            }
            return;
          }
        } on OpenSpeakException catch (exception, stackTrace) {
          if (exception.code == 'epoch_changed') return;
          if (attempt == 59) {
            ClientLog.error('e2ee.media_ready', exception, stackTrace);
          }
        } catch (exception, stackTrace) {
          if (attempt == 59) {
            ClientLog.error('e2ee.media_ready', exception, stackTrace);
          }
        }
        attempt += 1;
        if (attempt == 60) {
          ClientLog.write(
            'e2ee.media_ready',
            'activation still pending epoch=$epochId index=$keyIndex',
          );
        }
        await Future<void>.delayed(
          attempt < 60
              ? const Duration(milliseconds: 250)
              : const Duration(seconds: 2),
        );
      }
    } finally {
      if (mediaKeyReadyTransition == transition) {
        mediaKeyReadyTransition = null;
      }
    }
  }

  Future<void> handleVoiceMediaKeyActivated(RealtimeEvent event) async {
    if (voiceSession.currentChannelId != event.channelId) return;
    final epochId = event.payload['epoch_id'] as String? ?? '';
    final keyIndex = event.payload['key_index'] as int? ?? -1;
    if (epochId.isEmpty || keyIndex < 0) return;
    try {
      await voiceSession.activateE2EEMediaKey(
        epochId: epochId,
        keyIndex: keyIndex,
      );
    } catch (exception, stackTrace) {
      ClientLog.error('e2ee.media_activate', exception, stackTrace);
      final channel = channels
          .where((item) => item.id == event.channelId)
          .firstOrNull;
      if (channel != null) await joinLiveKitVoice(channel: channel);
    }
  }

  Future<void> handleVoiceMediaKeyFallback(RealtimeEvent event) async {
    try {
      if (voiceSession.currentChannelId != event.channelId) return;
      final client = api;
      final auth = session;
      if (client == null || auth == null) return;
      final channel = channels
          .where((item) => item.id == event.channelId)
          .firstOrNull;
      if (channel == null) return;
      final latest = await client.getChannelE2EEState(
        auth.token,
        channel.id,
        media: true,
      );
      final eventEpochId = event.payload['epoch_id'] as String? ?? '';
      if (eventEpochId.isNotEmpty && latest.epoch.id != eventEpochId) return;
      await joinLiveKitVoice(channel: channel);
    } catch (exception, stackTrace) {
      ClientLog.error('e2ee.media_fallback', exception, stackTrace);
    }
  }

  Future<List<ChannelMessage>> decryptChannelMessages(
    Channel channel,
    List<ChannelMessage> messages,
  ) async {
    final keys = <String, SecretKeyData>{};
    for (final epochId in encryptedChannelMessageEpochIds(messages)) {
      try {
        keys[epochId] = await ensureChannelKey(channel, epochId: epochId);
      } catch (_) {
        // One failed lookup covers every message from this epoch.
      }
    }
    final decrypted = <ChannelMessage>[];
    for (final message in messages) {
      if (message.encryptionMode != 'e2ee' || message.kind != 'text') {
        decrypted.add(message);
        continue;
      }
      try {
        final key = keys[message.epochId];
        if (key == null) throw StateError('channel key unavailable');
        decrypted.add(
          message.withBody(
            await deviceIdentity.decryptChannelText(
              channelKey: key,
              channelId: channel.id,
              epochId: message.epochId,
              body: message.body,
              nonce: message.nonce,
            ),
          ),
        );
      } catch (_) {
        decrypted.add(message.withBody('[无法解密的加密消息]'));
      }
    }
    return decrypted;
  }

  Future<void> loadChannelMessages({
    Channel? channel,
    bool scrollToEnd = true,
  }) async {
    final client = api;
    final auth = session;
    final target = channel ?? selectedChannel;
    if (client == null || auth == null || target == null) return;
    if (!hasServerPermission('channel.messages.view')) {
      setState(() {
        channelMessageStore.reset();
      });
      return;
    }
    var generation = 0;
    setState(() => generation = channelMessageStore.beginLoad());
    try {
      if (selectedServer?.encryptionMode == 'e2ee') {
        await ensureChannelKey(target);
      }
      final messages = await decryptChannelMessages(
        target,
        await client.listChannelMessages(auth.token, target.id),
      );
      if (!mounted ||
          selectedChannel?.id != target.id ||
          !channelMessageStore.isCurrent(generation)) {
        return;
      }
      setState(() {
        channelMessageStore.replaceHistory(
          generation,
          messages,
          channelId: target.id,
          isPending: attachmentTransfers.pendingLocalUploads.contains,
        );
        error = null;
      });
      if (scrollToEnd) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => scrollMessagesToEnd(animated: false, settle: true),
        );
      }
    } finally {
      if (mounted && channelMessageStore.isCurrent(generation)) {
        setState(() => channelMessageStore.finishLoad(generation));
      }
    }
  }

  void handleChannelMessage(RealtimeEvent event) {
    unawaited(handleChannelMessageAsync(event));
  }

  void handleChannelMessageDeleted(RealtimeEvent event) {
    final messageId = event.payload['message_id'] as String? ?? '';
    if (messageId.isEmpty || event.channelId != selectedChannel?.id) return;
    setState(() => attachmentTransfers.pendingLocalUploads.remove(messageId));
    unawaited(loadChannelMessages(scrollToEnd: false));
  }

  Future<void> deleteChannelMessage(
    ChannelMessage message,
    ChannelMessageContextAction action,
  ) async {
    final client = api;
    final auth = session;
    if (client == null || auth == null) return;
    await runGuarded(() async {
      await client.deleteChannelMessage(
        auth.token,
        message.channelId,
        message.id,
        moderatorDelete: action == ChannelMessageContextAction.delete,
      );
      if (!mounted) return;
      await loadChannelMessages(scrollToEnd: false);
    });
  }

  Future<void> showChannelMessageContextMenu(
    ChannelMessage message,
    Offset globalPosition,
  ) async {
    final action = channelMessageContextAction(
      mine: message.senderUserId == session?.user.id,
      canManageOthers: hasServerPermission('channel.messages.manage'),
      pending: attachmentTransfers.pendingLocalUploads.contains(message.id),
      canRetractOwn: canRetractChannelMessage(message),
    );
    if (action == null) return;
    final selected = await showOsCompactContextMenu(context, globalPosition, [
      action == ChannelMessageContextAction.retract ? '撤回消息' : '删除消息',
    ]);
    if (selected == 0 && mounted) await deleteChannelMessage(message, action);
  }

  Future<void> handleChannelMessageAsync(RealtimeEvent event) async {
    if (!hasServerPermission('channel.messages.view')) return;
    final channelId = event.channelId;
    if (channelId.isEmpty) return;
    final chatVisible = channelChatVisibleNow(channelId);
    final shouldUnread = channelMessageNeedsUnread(
      channelId: channelId,
      currentChannelId: channelMessageNotificationChannelId(),
      chatVisible: chatVisible,
      atBottom: messageViewAtBottom,
    );
    if (!shouldUnread) {
      if (chatVisible) {
        await loadChannelMessages(
          channel: selectedChannel,
          scrollToEnd: messageViewAtBottom,
        );
      }
      return;
    }

    final messageId = event.payload['message_id'] as String? ?? '';
    final message = await fetchChannelMessageForEvent(channelId, messageId);
    if (!mounted) return;
    final visibleNow = channelChatVisibleNow(channelId);
    if (!channelMessageNeedsUnread(
      channelId: channelId,
      currentChannelId: channelMessageNotificationChannelId(),
      chatVisible: visibleNow,
      atBottom: messageViewAtBottom,
    )) {
      if (visibleNow) {
        await loadChannelMessages(
          channel: selectedChannel,
          scrollToEnd: messageViewAtBottom,
        );
      }
      return;
    }
    if (message?.senderUserId == session?.user.id) return;
    unawaited(
      soundEffects.play(
        SoundEffect.messageChannel,
        cooldown: const Duration(seconds: 1),
      ),
    );
    setState(() {
      if (visibleNow) showCurrentChatNewMessageHint();
      unreadState.addChannel(
        channelId,
        mention: message != null && channelMessageMentionsCurrentUser(message),
      );
    });
  }

  Future<ChannelMessage?> fetchChannelMessageForEvent(
    String channelId,
    String messageId,
  ) async {
    final client = api;
    final auth = session;
    if (client == null ||
        auth == null ||
        messageId.isEmpty ||
        !hasServerPermission('channel.messages.view')) {
      return null;
    }
    try {
      final channel = channels
          .where((item) => item.id == channelId)
          .firstOrNull;
      if (channel == null) return null;
      final messages = await decryptChannelMessages(
        channel,
        await client.listChannelMessages(auth.token, channelId, limit: 50),
      );
      return messages.where((item) => item.id == messageId).firstOrNull;
    } catch (_) {
      return null;
    }
  }

  Future<void> sendChannelMessage() async {
    final client = api;
    final auth = session;
    final channel = selectedChannel;
    final body = messageController.text.trim();
    if (client == null || auth == null || channel == null || body.isEmpty) {
      return;
    }
    if (!hasServerPermission('channel.messages.send_text')) {
      setState(() => error = '当前账号没有发送此内容的权限');
      return;
    }
    await runGuarded(() async {
      final mode = selectedServer?.encryptionMode ?? 'none';
      late ChannelMessage message;
      if (mode == 'e2ee') {
        Future<ChannelMessage> sendEncrypted() async {
          final state = await client.getChannelE2EEState(
            auth.token,
            channel.id,
          );
          final key = await ensureChannelKey(channel, epochId: state.epoch.id);
          final encrypted = await deviceIdentity.encryptChannelText(
            channelKey: key,
            channelId: channel.id,
            epochId: state.epoch.id,
            cleartext: body,
          );
          final stored = await client.sendChannelTextMessage(
            auth.token,
            channel.id,
            encrypted.body,
            mode,
            epochId: state.epoch.id,
            nonce: encrypted.nonce,
          );
          return stored.withBody(body);
        }

        try {
          message = await sendEncrypted();
        } on OpenSpeakException catch (exception) {
          if (exception.code != 'epoch_changed') rethrow;
          channelKeys.removeWhere((key, _) => key.startsWith('${channel.id}:'));
          message = await sendEncrypted();
        }
      } else {
        message = await client.sendChannelTextMessage(
          auth.token,
          channel.id,
          body,
          mode,
        );
      }
      if (!mounted || selectedChannel?.id != channel.id) return;
      if (messageController.text.trim() == body) messageController.clear();
      setState(() => channelMessageStore.add(message));
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => scrollMessagesToEnd(),
      );
    });
  }

  Future<void> sendDirectMessage() async {
    final realtimeGeneration = realtimeConnection.generation;
    final auth = session;
    final peer = selectedDirectUser();
    final body = messageController.text.trim();
    if (!realtimeConnection.connected ||
        auth == null ||
        peer == null ||
        body.isEmpty) {
      return;
    }
    if (!hasServerPermission('direct.send_text')) {
      setState(() => error = '当前账号没有发起私聊的权限');
      return;
    }
    if (utf8.encode(body).length > 8192) {
      setState(() => error = '私聊消息不能超过 8192 字节');
      return;
    }
    await runGuarded(() async {
      final mode = selectedServer?.encryptionMode ?? 'none';
      final payload = <String, dynamic>{
        'kind': 'text',
        'body': body,
        'encryption_mode': mode,
      };
      if (mode == 'e2ee') {
        final prepared = await prepareDirectEncryption(peer.userId);
        final scope = directEncryptionScope(
          prepared.serverId,
          auth.user.id,
          peer.userId,
        );
        final encrypted = await deviceIdentity.encryptChannelText(
          channelKey: prepared.key,
          channelId: scope,
          epochId: prepared.messageId,
          cleartext: body,
        );
        payload.addAll({
          'message_id': prepared.messageId,
          'body': encrypted.body,
          'nonce': encrypted.nonce,
          'sender_device_id': prepared.senderDeviceId,
          'envelopes': prepared.envelopes,
        });
      }
      final sent = realtimeConnection.send(
        jsonEncode({
          'type': 'direct.message_send',
          'to_user': peer.userId,
          'payload': payload,
        }),
        generation: realtimeGeneration,
      );
      if (sent && messageController.text.trim() == body) {
        messageController.clear();
      }
    });
  }

  Future<
    ({
      String serverId,
      String messageId,
      String senderDeviceId,
      SecretKeyData key,
      List<Map<String, String>> envelopes,
    })
  >
  prepareDirectEncryption(String peerUserId) async {
    final client = api;
    final auth = session;
    final server = selectedServer;
    final identity = e2eeDeviceIdentity;
    if (client == null || auth == null || server == null || identity == null) {
      throw OpenSpeakException('私聊加密设备尚未就绪');
    }
    final devices = await client.getDirectE2EEDevices(
      auth.token,
      serverId: server.id,
      toUserId: peerUserId,
    );
    if (!devices.any((item) => item.id == identity.deviceId) ||
        !devices.any((item) => item.userId == peerUserId)) {
      throw OpenSpeakException('私聊设备已变化，请重试');
    }
    final messageId = deviceIdentity.newDirectMessageId();
    final key = await deviceIdentity.newChannelKey();
    final scope = directEncryptionScope(server.id, auth.user.id, peerUserId);
    final envelopes = await Future.wait(
      devices.map((recipient) async {
        final ciphertext = await deviceIdentity.wrapChannelKey(
          sender: identity,
          channelId: scope,
          epochId: messageId,
          recipientDeviceId: recipient.id,
          recipientEnvelopePublicKey: recipient.envelopePublicKey,
          channelKey: key,
        );
        return <String, String>{
          'algorithm': 'openspeak-envelope-v1',
          'recipient_user_id': recipient.userId,
          'recipient_device_id': recipient.id,
          'ciphertext': ciphertext,
        };
      }),
    );
    return (
      serverId: server.id,
      messageId: messageId,
      senderDeviceId: identity.deviceId,
      key: key,
      envelopes: envelopes,
    );
  }

  Future<void> handleDirectMessage(RealtimeEvent event) async {
    final auth = session;
    if (auth == null) return;
    final peerId = event.fromUser == auth.user.id
        ? event.toUser
        : event.fromUser;
    if (peerId.isEmpty ||
        (event.fromUser != auth.user.id && event.toUser != auth.user.id)) {
      return;
    }
    var message = DirectMessage.fromEvent(event);
    if (message.encryptionMode == 'e2ee') {
      try {
        final key = await unwrapDirectMessageKey(event);
        directMessageKeys[message.id] = key;
        if (message.kind == 'text') {
          final cleartext = await deviceIdentity.decryptChannelText(
            channelKey: key,
            channelId: directEncryptionScope(
              event.serverId,
              event.fromUser,
              event.toUser,
            ),
            epochId: message.id,
            body: message.body,
            nonce: message.nonce,
          );
          message = message.withBody(cleartext);
        }
      } catch (exception, stackTrace) {
        ClientLog.error('e2ee.direct_message', exception, stackTrace);
        message = message.withBody('[无法解密的私聊消息]');
      }
    }
    if (!mounted ||
        session?.user.id != auth.user.id ||
        selectedServer?.id != event.serverId) {
      directMessageKeys.remove(message.id);
      return;
    }
    final activeDirect =
        chatScope == ChatScope.direct && selectedDirectUser()?.userId == peerId;
    final wasAtBottom = messageViewAtBottom;
    final mine = message.fromUserId == auth.user.id;
    final deferVisibleInsert = activeDirect && !wasAtBottom && !mine;
    setState(() {
      final removedLocalIds = directMessageStore.addIncoming(
        peerId,
        message,
        pending: deferVisibleInsert,
        removeWhere: (item) =>
            attachmentTransfers.pendingLocalUploads.contains(item.id) &&
            item.fromUserId == message.fromUserId &&
            item.toUserId == message.toUserId &&
            item.kind == message.kind &&
            item.originalName == message.originalName &&
            item.sizeBytes == message.sizeBytes,
      );
      for (final id in removedLocalIds) {
        attachmentTransfers.removeLocalUpload(id);
        imagePreviewFutures.remove(id);
        audioMetadataFutures.remove(id);
      }
      if (!mine) {
        if (activeDirect) {
          if (!wasAtBottom) {
            showCurrentChatNewMessageHint();
            unreadState.addDirect(peerId);
          }
        } else {
          unreadState.addDirect(peerId);
        }
      }
    });
    if (!mine && (!activeDirect || !wasAtBottom)) {
      unawaited(
        soundEffects.play(
          SoundEffect.messageDirect,
          cooldown: const Duration(seconds: 1),
        ),
      );
    }
    if (activeDirect && wasAtBottom) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => scrollMessagesToEnd(),
      );
    }
  }

  Future<SecretKeyData> unwrapDirectMessageKey(RealtimeEvent event) async {
    final identity = e2eeDeviceIdentity;
    final messageId = event.payload['id'] as String? ?? '';
    final senderDeviceId = event.payload['sender_device_id'] as String? ?? '';
    final senderIdentityPublicKey =
        event.payload['sender_identity_public_key'] as String? ?? '';
    final rawEnvelopes = event.payload['envelopes'];
    if (identity == null || rawEnvelopes is! List) {
      throw const FormatException('missing direct key envelope');
    }
    Map<String, dynamic>? envelope;
    for (final raw in rawEnvelopes) {
      if (raw is Map && raw['recipient_device_id'] == identity.deviceId) {
        envelope = raw.cast<String, dynamic>();
        break;
      }
    }
    if (envelope == null || envelope['algorithm'] != 'openspeak-envelope-v1') {
      throw const FormatException('direct key envelope not found');
    }
    return deviceIdentity.unwrapChannelKey(
      recipient: identity,
      channelId: directEncryptionScope(
        event.serverId,
        event.fromUser,
        event.toUser,
      ),
      epochId: messageId,
      senderDeviceId: senderDeviceId,
      senderIdentityPublicKey: senderIdentityPublicKey,
      ciphertext: envelope['ciphertext'] as String? ?? '',
    );
  }

  void handleDirectFileExpired(RealtimeEvent event) {
    final fileId = event.payload['file_id'] as String? ?? '';
    if (fileId.isEmpty) return;
    setState(() {
      directMessageStore.markFileExpired(fileId);
      attachmentTransfers.cancelDownload(fileId);
    });
  }

  void handleDirectMessageDeleted(RealtimeEvent event) {
    final auth = session;
    final messageId = event.payload['message_id'] as String? ?? '';
    if (auth == null || messageId.isEmpty) return;
    final peerId = event.fromUser == auth.user.id
        ? event.toUser
        : event.fromUser;
    if (peerId.isEmpty) return;
    setState(() {
      directMessageKeys.remove(messageId);
      directMessageStore.markRetracted(peerId, messageId);
    });
  }

  void retractDirectMessage(DirectMessage message) {
    realtimeConnection.send(
      jsonEncode({
        'type': 'direct.message_delete',
        'payload': {'message_id': message.id},
      }),
    );
  }

  Future<void> showDirectMessageContextMenu(
    DirectMessage message,
    Offset position,
  ) async {
    final selected = await showOsCompactContextMenu(context, position, [
      '撤回消息',
    ]);
    if (selected == 0 && mounted) retractDirectMessage(message);
  }

  List<DirectMessage> selectedDirectMessages() {
    final peer = selectedDirectUser();
    if (peer == null) return const [];
    return directMessageStore.messagesFor(peer.userId);
  }

  Future<void> pickAndUploadAttachment() async {
    final directPeer = selectedDirectUser();
    final channel = selectedChannel;
    final scope = chatScope;
    if (chatScope == ChatScope.channel && selectedChannel == null) {
      setState(() => error = '未进入频道');
      return;
    }
    if (chatScope == ChatScope.direct && directPeer == null) {
      setState(() => error = '未选择私聊对象');
      return;
    }

    await runGuarded(() async {
      final selected = await openFiles();
      if (selected.isEmpty) return;
      final files = <XFile>[];
      for (final item in selected) {
        final file = await fileFromSelection(item);
        if (file != null) files.add(file);
      }
      enqueueAttachmentUploads(
        files,
        direct: scope == ChatScope.direct,
        targetId: scope == ChatScope.direct ? directPeer!.userId : channel!.id,
      );
    });
  }

  void enqueueAttachmentUploads(
    List<XFile> files, {
    required bool direct,
    required String targetId,
  }) {
    if (files.isEmpty) return;
    setState(() {
      for (final file in files) {
        attachmentTransfers.uploads.add(
          TransferTask.upload(
            file: file,
            direct: direct,
            targetId: targetId,
            image: isImageFile(file),
          ),
        );
      }
    });
    unawaited(processUploadQueue());
  }

  Future<void> processUploadQueue() => attachmentTransfers.processUploads(
    upload: (task) => task.direct
        ? uploadDirectAttachment(task)
        : uploadChannelAttachment(task),
    onChanged: () {
      if (mounted) setState(() {});
    },
    onCompleted: (_) {
      if (mounted) unawaited(soundEffects.play(SoundEffect.messageSend));
    },
    onFailed: (_, exception) {
      if (!mounted) return;
      error = '$exception';
      unawaited(soundEffects.play(SoundEffect.error));
    },
  );

  Future<XFile?> fileFromSelection(XFile? selected) async {
    if (selected == null) return null;
    if (kIsWeb) {
      if (await selected.length() <= 0) {
        throw OpenSpeakException('所选文件为空');
      }
      return selected;
    }
    final path = selected.path.trim();
    if (path.isEmpty) {
      throw OpenSpeakException('无法读取所选文件路径，请检查 macOS 文件访问权限');
    }
    final file = File(path);
    if (!await file.exists()) {
      throw OpenSpeakException('所选文件不存在或无法访问: $path');
    }
    return selected;
  }

  Future<void> uploadChannelAttachment(TransferTask task) async {
    final client = api;
    final auth = session;
    if (client == null || auth == null) {
      throw OpenSpeakException('未连接服务器');
    }
    final permission = task.image
        ? 'channel.messages.send_image'
        : 'channel.messages.send_file';
    if (!hasServerPermission(permission)) {
      throw OpenSpeakException('当前账号没有发送此类附件的权限');
    }
    final file = task.file;
    final fileLength = await file.length();
    task.totalBytes = fileLength;
    final desktopFile = kIsWeb ? null : File(file.path);
    final localMessage = task.image && desktopFile != null
        ? createOptimisticChannelAttachmentMessage(
            file: desktopFile,
            channelId: task.targetId,
            senderUserId: auth.user.id,
            sizeBytes: fileLength,
            kind: 'image',
          )
        : null;
    if (mounted &&
        localMessage != null &&
        selectedChannel?.id == task.targetId) {
      setState(() => channelMessageStore.addOrReplace(localMessage));
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => scrollMessagesToEnd(animated: false),
      );
    }
    ChannelUploadResult result;
    try {
      final mode = selectedServer?.encryptionMode ?? 'none';
      Future<ChannelUploadResult> uploadOnce() async {
        var uploadFile = file;
        var epochId = '';
        var nonce = '';
        var format = '';
        var chunkSize = 0;
        Directory? tempDir;
        try {
          if (mode == 'e2ee') {
            final channel = channels
                .where((item) => item.id == task.targetId)
                .firstOrNull;
            if (channel == null) throw OpenSpeakException('频道不存在');
            final state = await client.getChannelE2EEState(
              auth.token,
              channel.id,
            );
            final key = await ensureChannelKey(
              channel,
              epochId: state.epoch.id,
            );
            String encryptedNonce;
            if (kIsWeb) {
              final encrypted = await deviceIdentity.encryptAttachmentBytes(
                input: await file.readAsBytes(),
                channelKey: key,
                channelId: channel.id,
                epochId: state.epoch.id,
                checkCancelled: () =>
                    task.cancelToken.throwIfCancelled('上传已取消'),
              );
              uploadFile = XFile.fromData(encrypted.bytes, name: 'payload');
              encryptedNonce = encrypted.nonce;
            } else {
              tempDir = await Directory.systemTemp.createTemp(
                'openspeak_e2ee_upload_',
              );
              final encrypted = await deviceIdentity.encryptAttachmentFile(
                input: File(file.path),
                output: File('${tempDir.path}${Platform.pathSeparator}payload'),
                channelKey: key,
                channelId: channel.id,
                epochId: state.epoch.id,
                checkCancelled: () =>
                    task.cancelToken.throwIfCancelled('上传已取消'),
              );
              uploadFile = XFile(encrypted.file.path);
              encryptedNonce = encrypted.nonce;
            }
            epochId = state.epoch.id;
            nonce = encryptedNonce;
            format = attachmentEncryptionFormatV1;
            chunkSize = attachmentEncryptionChunkSize;
          }
          void uploadProgress(int sent, int total) =>
              updateTransferProgress(task, sent, total);
          return await (task.image
              ? client.uploadChannelImage(
                  auth.token,
                  task.targetId,
                  uploadFile,
                  encryptionMode: mode,
                  originalName: fileNameFor(file),
                  contentType: contentTypeForPath(fileNameFor(file)),
                  epochId: epochId,
                  nonce: nonce,
                  plaintextSizeBytes: mode == 'e2ee' ? fileLength : 0,
                  attachmentFormat: format,
                  chunkSize: chunkSize,
                  onProgress: uploadProgress,
                  cancelToken: task.cancelToken,
                )
              : client.uploadChannelFile(
                  auth.token,
                  task.targetId,
                  uploadFile,
                  encryptionMode: mode,
                  originalName: fileNameFor(file),
                  contentType: contentTypeForPath(fileNameFor(file)),
                  epochId: epochId,
                  nonce: nonce,
                  plaintextSizeBytes: mode == 'e2ee' ? fileLength : 0,
                  attachmentFormat: format,
                  chunkSize: chunkSize,
                  onProgress: uploadProgress,
                  cancelToken: task.cancelToken,
                ));
        } finally {
          if (tempDir != null && await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        }
      }

      try {
        result = await uploadOnce();
      } on OpenSpeakException catch (exception) {
        if (mode != 'e2ee' || exception.code != 'epoch_changed') rethrow;
        channelKeys.removeWhere(
          (key, _) => key.startsWith('${task.targetId}:'),
        );
        result = await uploadOnce();
      }
    } catch (_) {
      if (mounted && localMessage != null) {
        setState(() => removeOptimisticChannelMessage(localMessage.id));
      }
      rethrow;
    }
    if (!kIsWeb) {
      await seedUploadedAttachmentCache(
        file: File(file.path),
        fileId: result.file.id,
        originalName: result.file.originalName,
        sizeBytes: fileLength,
      );
    }
    if (task.cancelToken.isCancelled || !mounted) return;
    setState(() {
      if (localMessage != null) {
        removeOptimisticChannelMessage(localMessage.id);
      }
      if (selectedChannel?.id == task.targetId) {
        channelMessageStore.addOrReplace(result.message);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => scrollMessagesToEnd());
  }

  Future<void> uploadDirectAttachment(TransferTask task) async {
    final client = api;
    final auth = session;
    if (client == null || auth == null) {
      throw OpenSpeakException('未连接服务器');
    }
    final permission = task.image ? 'direct.send_image' : 'direct.send_file';
    if (!hasServerPermission(permission)) {
      throw OpenSpeakException('当前账号没有发送此类私聊附件的权限');
    }
    final file = task.file;
    final fileLength = await file.length();
    task.totalBytes = fileLength;
    final desktopFile = kIsWeb ? null : File(file.path);
    final localMessage = task.image && desktopFile != null
        ? createOptimisticDirectAttachmentMessage(
            file: desktopFile,
            fromUserId: auth.user.id,
            toUserId: task.targetId,
            sizeBytes: fileLength,
            kind: 'image',
          )
        : null;
    if (mounted && localMessage != null) {
      setState(() {
        directMessageStore.add(task.targetId, localMessage);
      });
      if (chatScope == ChatScope.direct &&
          selectedDirectUserId == task.targetId) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => scrollMessagesToEnd(animated: false),
        );
      }
    }
    DirectFile directFile;
    Directory? tempDir;
    try {
      final mode = selectedServer?.encryptionMode ?? 'none';
      var uploadFile = file;
      var messageId = '';
      var senderDeviceId = '';
      var nonce = '';
      var format = '';
      var chunkSize = 0;
      var envelopes = const <Map<String, String>>[];
      if (mode == 'e2ee') {
        final prepared = await prepareDirectEncryption(task.targetId);
        final scope = directEncryptionScope(
          prepared.serverId,
          auth.user.id,
          task.targetId,
        );
        String encryptedNonce;
        if (kIsWeb) {
          final encrypted = await deviceIdentity.encryptAttachmentBytes(
            input: await file.readAsBytes(),
            channelKey: prepared.key,
            channelId: scope,
            epochId: prepared.messageId,
            checkCancelled: () => task.cancelToken.throwIfCancelled('上传已取消'),
          );
          uploadFile = XFile.fromData(encrypted.bytes, name: 'payload');
          encryptedNonce = encrypted.nonce;
        } else {
          tempDir = await Directory.systemTemp.createTemp(
            'openspeak_e2ee_direct_',
          );
          final encrypted = await deviceIdentity.encryptAttachmentFile(
            input: File(file.path),
            output: File('${tempDir.path}${Platform.pathSeparator}payload'),
            channelKey: prepared.key,
            channelId: scope,
            epochId: prepared.messageId,
            checkCancelled: () => task.cancelToken.throwIfCancelled('上传已取消'),
          );
          uploadFile = XFile(encrypted.file.path);
          encryptedNonce = encrypted.nonce;
        }
        messageId = prepared.messageId;
        senderDeviceId = prepared.senderDeviceId;
        nonce = encryptedNonce;
        format = attachmentEncryptionFormatV1;
        chunkSize = attachmentEncryptionChunkSize;
        envelopes = prepared.envelopes;
      }
      directFile = await client.uploadDirectFile(
        auth.token,
        task.targetId,
        uploadFile,
        originalName: fileNameFor(file),
        contentType: contentTypeForPath(fileNameFor(file)),
        encryptionMode: mode,
        messageId: messageId,
        senderDeviceId: senderDeviceId,
        nonce: nonce,
        plaintextSizeBytes: mode == 'e2ee' ? fileLength : 0,
        attachmentFormat: format,
        chunkSize: chunkSize,
        directEnvelopes: envelopes,
        onProgress: (sent, total) => updateTransferProgress(task, sent, total),
        cancelToken: task.cancelToken,
      );
    } catch (_) {
      if (mounted && localMessage != null) {
        setState(
          () => removeOptimisticDirectMessage(task.targetId, localMessage.id),
        );
      }
      rethrow;
    } finally {
      if (tempDir != null && await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
    if (!kIsWeb) {
      await seedUploadedAttachmentCache(
        file: File(file.path),
        fileId: directFile.id,
        originalName: directFile.originalName,
        sizeBytes: fileLength,
      );
    }
  }

  void updateTransferProgress(TransferTask task, int transferred, int total) {
    if (!mounted) return;
    setState(
      () => attachmentTransfers.updateProgress(task, transferred, total),
    );
  }

  String createLocalAttachmentId() {
    return 'local:${DateTime.now().microsecondsSinceEpoch}';
  }

  String fileNameFor(XFile file) => file.name.isEmpty ? 'upload' : file.name;

  String desktopFileNameFor(File file) =>
      file.uri.pathSegments.isEmpty ? 'upload' : file.uri.pathSegments.last;

  ChannelMessage createOptimisticChannelAttachmentMessage({
    required File file,
    required String channelId,
    required String senderUserId,
    required int sizeBytes,
    required String kind,
  }) {
    final fileId = createLocalAttachmentId();
    final originalName = desktopFileNameFor(file);
    registerLocalAttachmentSource(fileId, file, expectedSizeBytes: sizeBytes);
    attachmentTransfers.pendingLocalUploads.add(fileId);
    return ChannelMessage(
      id: fileId,
      channelId: channelId,
      senderUserId: senderUserId,
      senderDisplayName: localDisplayName,
      kind: kind,
      encryptionMode: selectedServer?.encryptionMode ?? 'none',
      body: '',
      metadata: {
        'file_id': fileId,
        'original_name': originalName,
        'content_type': contentTypeForPath(file.path),
        'size_bytes': '$sizeBytes',
      },
      createdAt: DateTime.now(),
    );
  }

  DirectMessage createOptimisticDirectAttachmentMessage({
    required File file,
    required String fromUserId,
    required String toUserId,
    required int sizeBytes,
    required String kind,
  }) {
    final fileId = createLocalAttachmentId();
    final originalName = desktopFileNameFor(file);
    registerLocalAttachmentSource(fileId, file, expectedSizeBytes: sizeBytes);
    attachmentTransfers.pendingLocalUploads.add(fileId);
    return DirectMessage(
      id: fileId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      kind: kind,
      body: '',
      fileId: fileId,
      originalName: originalName,
      contentType: contentTypeForPath(file.path),
      sizeBytes: sizeBytes,
      expiresAt: null,
      sentAt: DateTime.now(),
    );
  }

  void removeOptimisticChannelMessage(String localId) {
    attachmentTransfers.removeLocalUpload(localId);
    audioMetadataFutures.remove(localId);
    channelMessageStore.remove(localId);
  }

  void removeOptimisticDirectMessage(String peerId, String localId) {
    attachmentTransfers.removeLocalUpload(localId);
    audioMetadataFutures.remove(localId);
    directMessageStore.remove(peerId, localId);
  }

  Future<void> seedUploadedAttachmentCache({
    required File file,
    required String fileId,
    required String originalName,
    required int sizeBytes,
  }) async {
    if (fileId.isEmpty) return;
    registerLocalAttachmentSource(fileId, file, expectedSizeBytes: sizeBytes);
    unawaited(
      attachmentCache
          .seedFromLocalFile(
            fileId: fileId,
            originalName: originalName,
            source: file,
            expectedSizeBytes: sizeBytes,
          )
          .catchError((_) => File('')),
    );
  }

  void registerLocalAttachmentSource(
    String fileId,
    File file, {
    int expectedSizeBytes = 0,
  }) {
    if (fileId.isEmpty) return;
    audioMetadataFutures.remove(fileId);
    attachmentTransfers.registerLocalSource(
      fileId,
      file,
      expectedSizeBytes: expectedSizeBytes,
      onInvalid: () {
        imagePreviewFutures.remove(fileId);
        audioMetadataFutures.remove(fileId);
      },
    );
  }

  void cancelUpload(TransferTask task) {
    setState(() => attachmentTransfers.cancelUpload(task));
  }

  Future<void> retryUpload(TransferTask task) async {
    try {
      if (await task.file.length() <= 0) throw const FileSystemException();
    } catch (_) {
      setState(() {
        task.status = TransferStatus.failed;
        task.error = '原文件不存在，无法重试';
      });
      return;
    }
    setState(() => attachmentTransfers.retryUpload(task));
    await processUploadQueue();
  }

  Future<File> ensureAttachmentCached(
    ChatAttachment attachment, {
    TransferProgress? onProgress,
    TransferCancelToken? cancelToken,
  }) async {
    final auth = session;
    if (auth == null) {
      throw OpenSpeakException('未连接服务器');
    }
    if (attachment.expired) {
      throw OpenSpeakException('文件已过期');
    }
    final localSource = attachmentTransfers.localSources[attachment.fileId];
    if (localSource != null &&
        await localSource.exists() &&
        (attachment.sizeBytes <= 0 ||
            await localSource.length() == attachment.sizeBytes)) {
      return localSource;
    }
    if (attachment.encrypted) {
      final client = api;
      if (client == null) {
        throw OpenSpeakException('无法下载加密附件');
      }
      final existing = await attachmentCache.existingCachedFile(
        fileId: attachment.fileId,
        originalName: attachment.originalName,
        expectedSizeBytes: attachment.sizeBytes,
      );
      if (existing != null) return existing;
      if (attachment.attachmentFormat != attachmentEncryptionFormatV1) {
        throw OpenSpeakException('不支持此加密附件格式');
      }
      final channel = attachment.direct
          ? null
          : channels
                .where((item) => item.id == attachment.channelId)
                .firstOrNull;
      final key = attachment.direct
          ? directMessageKeys[attachment.epochId]
          : channel == null
          ? null
          : await ensureChannelKey(channel, epochId: attachment.epochId);
      if (key == null) throw OpenSpeakException('缺少附件解密密钥');
      File encrypted;
      try {
        void onDownloadProgress(int done, int _) => onProgress?.call(
          attachment.ciphertextSizeBytes <= 0
              ? 0
              : (done *
                        attachment.sizeBytes ~/
                        attachment.ciphertextSizeBytes) *
                    4 ~/
                    5,
          attachment.sizeBytes,
        );
        encrypted = attachment.direct
            ? await client.downloadDirectFile(
                auth.token,
                attachment.fileId,
                '${attachment.originalName}.encrypted',
                cancelToken: cancelToken,
                onProgress: onDownloadProgress,
              )
            : await client.downloadStoredFile(
                auth.token,
                attachment.fileId,
                '${attachment.originalName}.encrypted',
                cancelToken: cancelToken,
                onProgress: onDownloadProgress,
              );
      } catch (exception) {
        if (attachment.direct && isDirectFileExpiredError(exception)) {
          if (mounted) {
            setState(
              () => directMessageStore.markFileExpired(attachment.fileId),
            );
          }
          throw OpenSpeakException('文件已过期');
        }
        rethrow;
      }
      try {
        final cached = await attachmentCache.cachedFile(
          fileId: attachment.fileId,
          originalName: attachment.originalName,
        );
        return await deviceIdentity.decryptAttachmentFile(
          input: encrypted,
          output: cached,
          channelKey: key,
          channelId: attachment.channelId,
          epochId: attachment.epochId,
          nonce: attachment.nonce,
          plaintextSize: attachment.sizeBytes,
          checkCancelled: () => cancelToken?.throwIfCancelled('下载已取消'),
          onProgress: (done, total) =>
              onProgress?.call(total * 4 ~/ 5 + done ~/ 5, total),
        );
      } finally {
        if (await encrypted.exists()) await encrypted.delete();
      }
    }
    try {
      return await attachmentCache.ensureCached(
        token: auth.token,
        direct: attachment.direct,
        fileId: attachment.fileId,
        originalName: attachment.originalName,
        expectedSizeBytes: attachment.sizeBytes,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    } catch (e) {
      if (attachment.direct && isDirectFileExpiredError(e)) {
        if (mounted) {
          setState(() => directMessageStore.markFileExpired(attachment.fileId));
        }
        throw OpenSpeakException('文件已过期');
      }
      rethrow;
    }
  }

  Future<Uint8List> downloadAttachmentBytes(
    ChatAttachment attachment, {
    TransferProgress? onProgress,
    TransferCancelToken? cancelToken,
  }) async {
    final auth = session;
    final client = api;
    if (auth == null || client == null) {
      throw OpenSpeakException('未连接服务器');
    }
    if (attachment.expired) throw OpenSpeakException('文件已过期');
    Uint8List bytes;
    void downloadProgress(int done, int total) {
      if (!attachment.encrypted) {
        onProgress?.call(done, total);
        return;
      }
      final ciphertextSize = attachment.ciphertextSizeBytes > 0
          ? attachment.ciphertextSizeBytes
          : total;
      final plaintextSize = attachment.sizeBytes > 0
          ? attachment.sizeBytes
          : total;
      final scaled = ciphertextSize <= 0
          ? 0
          : done * plaintextSize ~/ ciphertextSize * 4 ~/ 5;
      onProgress?.call(scaled, plaintextSize);
    }

    bytes = attachment.direct
        ? await client.downloadDirectFileBytes(
            auth.token,
            attachment.fileId,
            onProgress: downloadProgress,
            cancelToken: cancelToken,
          )
        : await client.downloadStoredFileBytes(
            auth.token,
            attachment.fileId,
            onProgress: downloadProgress,
            cancelToken: cancelToken,
          );
    if (!attachment.encrypted) return bytes;
    if (attachment.attachmentFormat != attachmentEncryptionFormatV1) {
      throw OpenSpeakException('不支持此加密附件格式');
    }
    final channel = attachment.direct
        ? null
        : channels.where((item) => item.id == attachment.channelId).firstOrNull;
    final key = attachment.direct
        ? directMessageKeys[attachment.epochId]
        : channel == null
        ? null
        : await ensureChannelKey(channel, epochId: attachment.epochId);
    if (key == null) throw OpenSpeakException('缺少附件解密密钥');
    return deviceIdentity.decryptAttachmentBytes(
      input: bytes,
      channelKey: key,
      channelId: attachment.channelId,
      epochId: attachment.epochId,
      nonce: attachment.nonce,
      plaintextSize: attachment.sizeBytes,
      checkCancelled: () => cancelToken?.throwIfCancelled('下载已取消'),
      onProgress: (done, total) =>
          onProgress?.call(total * 4 ~/ 5 + done ~/ 5, total),
    );
  }

  Future<CachedImagePreview> loadImagePreview(ChatAttachment attachment) {
    final cached = imagePreviewFutures[attachment.fileId];
    if (cached != null) return cached;

    final future = () async {
      try {
        if (kIsWeb) {
          final bytes = await downloadAttachmentBytes(attachment);
          return CachedImagePreview(
            bytes: bytes,
            size: await _readImageSizeBytes(bytes),
          );
        }
        final file = await ensureAttachmentCached(attachment);
        final size = await _readImageSize(file);
        return CachedImagePreview(file: file, size: size);
      } catch (_) {
        imagePreviewFutures.remove(attachment.fileId);
        rethrow;
      }
    }();

    imagePreviewFutures[attachment.fileId] = future;
    return future;
  }

  Future<void> openAttachment(ChatAttachment attachment) async {
    final auth = session;
    if (auth == null) return;
    if (kIsWeb && attachment.isImage) {
      await showImageLightbox(attachment);
      return;
    }
    if (kIsWeb) {
      await downloadAttachmentInBrowser(attachment);
      return;
    }
    await runDownloadTask(attachment, () async {
      final file = await ensureAttachmentCached(
        attachment,
        onProgress: (done, total) =>
            updateDownloadProgress(attachment.fileId, done, total),
        cancelToken:
            attachmentTransfers.downloads[attachment.fileId]?.cancelToken,
      );
      await openDownloadedFile(file);
    });
  }

  Future<void> saveAttachmentAs(ChatAttachment attachment) async {
    final auth = session;
    if (auth == null) return;
    if (kIsWeb) {
      await downloadAttachmentInBrowser(attachment);
      return;
    }
    final destination = await getSaveLocation(
      suggestedName: attachment.displayName,
    );
    if (destination == null) return;
    await runDownloadTask(attachment, () async {
      final cached = await ensureAttachmentCached(
        attachment,
        onProgress: (done, total) =>
            updateDownloadProgress(attachment.fileId, done, total),
        cancelToken:
            attachmentTransfers.downloads[attachment.fileId]?.cancelToken,
      );
      await cached.copy(destination.path);
    });
  }

  Future<void> downloadAttachmentInBrowser(ChatAttachment attachment) {
    return runDownloadTask(attachment, () async {
      final bytes = await downloadAttachmentBytes(
        attachment,
        onProgress: (done, total) =>
            updateDownloadProgress(attachment.fileId, done, total),
        cancelToken:
            attachmentTransfers.downloads[attachment.fileId]?.cancelToken,
      );
      downloadBrowserBytes(
        bytes,
        attachment.displayName,
        attachmentContentType(attachment.contentType, attachment.displayName),
      );
    });
  }

  Future<void> showImageLightbox(ChatAttachment attachment) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭图片预览',
      barrierColor: const Color(0xE6000000),
      builder: (dialogContext) => ImageLightbox(
        preview: loadImagePreview(attachment),
        onDownload: () => unawaited(saveAttachmentAs(attachment)),
        onClose: () => Navigator.pop(dialogContext),
      ),
    );
  }

  Future<void> runDownloadTask(
    ChatAttachment attachment,
    Future<void> Function() action,
  ) async {
    if (attachment.expired) {
      setState(() => error = '文件已过期');
      return;
    }
    final task = TransferTask.download(attachment: attachment);
    setState(() => attachmentTransfers.downloads[attachment.fileId] = task);
    try {
      await action();
      if (!mounted) return;
      setState(() => attachmentTransfers.downloads.remove(attachment.fileId));
    } catch (e) {
      if (!mounted) return;
      if (task.cancelToken.isCancelled) {
        setState(() => attachmentTransfers.downloads.remove(attachment.fileId));
        return;
      }
      setState(() {
        if (attachment.direct && isDirectFileExpiredError(e)) {
          directMessageStore.markFileExpired(attachment.fileId);
          attachmentTransfers.downloads.remove(attachment.fileId);
          error = '文件已过期';
        } else {
          task.status = TransferStatus.failed;
          task.error = '$e';
          attachmentTransfers.downloads[attachment.fileId] = task;
          error = '$e';
        }
      });
    }
  }

  void updateDownloadProgress(String fileId, int transferred, int total) {
    if (!mounted) return;
    final task = attachmentTransfers.downloads[fileId];
    if (task == null) return;
    setState(
      () => attachmentTransfers.updateProgress(task, transferred, total),
    );
  }

  void cancelDownload(ChatAttachment attachment) {
    if (!attachmentTransfers.downloads.containsKey(attachment.fileId)) return;
    setState(() => attachmentTransfers.cancelDownload(attachment.fileId));
  }

  Future<LinkPreview?>? loadLinkPreviewForBody(String body) {
    final fallback = fallbackLinkPreviewForBody(body);
    if (fallback == null) {
      return null;
    }
    final cached = linkPreviewFutures[fallback.url];
    if (cached != null) return cached;
    final future = fetchClientLinkPreview(fallback.url)
        .then(
          (preview) => preview.hasContent
              ? mergeLinkPreview(preview, fallback)
              : fallback,
        )
        .catchError((_) => fallback);
    linkPreviewFutures[fallback.url] = future;
    return future;
  }

  LinkPreview? fallbackLinkPreviewForBody(String body) {
    final previewUrl = firstPreviewableUrl(body);
    return previewUrl == null ? null : fallbackLinkPreview(previewUrl);
  }

  Future<AudioAttachmentMetadata> loadAudioMetadata(ChatAttachment attachment) {
    final cached = audioMetadataFutures[attachment.fileId];
    if (cached != null) return cached;
    final future = () async {
      final metadata = await readAudioAttachmentMetadata(attachment);
      return metadata.withFallbackTitle(attachment.displayName);
    }();
    audioMetadataFutures[attachment.fileId] = future;
    return future;
  }

  Future<AudioAttachmentMetadata> readAudioAttachmentMetadata(
    ChatAttachment attachment,
  ) async {
    if (!kIsWeb) {
      final localSource = attachmentTransfers.localSources[attachment.fileId];
      if (localSource != null && await localSource.exists()) {
        return readAudioAttachmentMetadataFromFile(localSource);
      }
      final cachedFile = await attachmentCache.existingCachedFile(
        fileId: attachment.fileId,
        originalName: attachment.originalName,
        expectedSizeBytes: attachment.sizeBytes,
      );
      if (cachedFile != null) {
        return readAudioAttachmentMetadataFromFile(cachedFile);
      }
    }
    final auth = session;
    final client = api;
    if (auth == null || client == null || attachment.expired) {
      return const AudioAttachmentMetadata();
    }
    try {
      Future<Uint8List> readRange(int start, int endInclusive) {
        return attachment.encrypted
            ? readAttachmentRange(
                attachment,
                start: start,
                endInclusive: endInclusive,
              )
            : attachment.direct
            ? client.readDirectFileRange(
                auth.token,
                attachment.fileId,
                start: start,
                endInclusive: endInclusive,
              )
            : client.readStoredFileRange(
                auth.token,
                attachment.fileId,
                start: start,
                endInclusive: endInclusive,
              );
      }

      final header = await readRange(0, 9);
      if (header.length != 10 ||
          header[0] != 0x49 ||
          header[1] != 0x44 ||
          header[2] != 0x33) {
        if (header.length >= 4 &&
            header[0] == 0x66 &&
            header[1] == 0x4C &&
            header[2] == 0x61 &&
            header[3] == 0x43) {
          final flacBytes = await readRange(0, 64 * 1024 - 1);
          final metadataLength = flacMetadataLength(flacBytes);
          if (metadataLength > flacBytes.length &&
              metadataLength <= audioMetadataReadLimitBytes) {
            final fullFlacMetadata = await readRange(0, metadataLength - 1);
            return parseFlacMetadata(fullFlacMetadata);
          }
          return parseFlacMetadata(flacBytes);
        }
        return readMp4MetadataFromRanges(
          sizeBytes: attachment.sizeBytes,
          readRange: readRange,
        );
      }
      final tagSize = readSynchsafeInt(header, 6);
      if (tagSize <= 0) return const AudioAttachmentMetadata();
      if (tagSize > audioMetadataReadLimitBytes) {
        return const AudioAttachmentMetadata();
      }
      final metadataEnd = tagSize + 9;
      final tagBytes = await readRange(10, metadataEnd);
      return parseID3v2Metadata(
        tagBytes,
        majorVersion: header[3],
        unsynchronized: (header[5] & 0x80) != 0,
        extendedHeader: (header[5] & 0x40) != 0,
      );
    } catch (_) {
      return const AudioAttachmentMetadata();
    }
  }

  Future<void> toggleAudioAttachment(ChatAttachment attachment) async {
    if (attachment.expired) {
      setState(() => error = '文件已过期');
      return;
    }
    try {
      await audioPlayback.toggle(attachment);
    } catch (exception) {
      if (!mounted) return;
      if (attachment.direct && isDirectFileExpiredError(exception)) {
        setState(() {
          directMessageStore.markFileExpired(attachment.fileId);
          error = '文件已过期';
        });
      } else {
        setState(() => error = '$exception');
      }
    }
  }

  Future<File?> localAudioSourceFile(ChatAttachment attachment) async {
    if (kIsWeb) return null;
    final localSource = attachmentTransfers.localSources[attachment.fileId];
    if (localSource != null && await localSource.exists()) {
      return localSource;
    }
    return attachmentCache.existingCachedFile(
      fileId: attachment.fileId,
      originalName: attachment.originalName,
      expectedSizeBytes: attachment.sizeBytes,
    );
  }

  Future<Uint8List> readAttachmentRange(
    ChatAttachment attachment, {
    required int start,
    required int endInclusive,
    http.Client? rangeClient,
  }) async {
    final client = api;
    final auth = session;
    if (!attachment.encrypted) {
      if (client == null || auth == null) throw OpenSpeakException('未连接服务器');
      return attachment.direct
          ? client.readDirectFileRange(
              auth.token,
              attachment.fileId,
              start: start,
              endInclusive: endInclusive,
              rangeClient: rangeClient,
            )
          : client.readStoredFileRange(
              auth.token,
              attachment.fileId,
              start: start,
              endInclusive: endInclusive,
              rangeClient: rangeClient,
            );
    }
    final channel = attachment.direct
        ? null
        : channels.where((item) => item.id == attachment.channelId).firstOrNull;
    if (client == null ||
        auth == null ||
        (!attachment.direct && channel == null)) {
      throw OpenSpeakException('无法读取加密附件');
    }
    if (attachment.attachmentFormat != attachmentEncryptionFormatV1) {
      throw OpenSpeakException('不支持此加密附件格式');
    }
    final key = attachment.direct
        ? directMessageKeys[attachment.epochId]
        : await ensureChannelKey(channel!, epochId: attachment.epochId);
    if (key == null) throw OpenSpeakException('缺少附件解密密钥');
    return deviceIdentity.decryptAttachmentRange(
      readCipherRange: (cipherStart, cipherEnd) => attachment.direct
          ? client.readDirectFileRange(
              auth.token,
              attachment.fileId,
              start: cipherStart,
              endInclusive: cipherEnd,
              rangeClient: rangeClient,
            )
          : client.readStoredFileRange(
              auth.token,
              attachment.fileId,
              start: cipherStart,
              endInclusive: cipherEnd,
              rangeClient: rangeClient,
            ),
      channelKey: key,
      channelId: attachment.channelId,
      epochId: attachment.epochId,
      nonce: attachment.nonce,
      plaintextSize: attachment.sizeBytes,
      start: start,
      endInclusive: endInclusive,
    );
  }

  bool isDirectFileExpiredError(Object error) {
    final text = '$error';
    return text.contains('HTTP 410') ||
        text.contains('file has expired') ||
        text.contains('文件已过期');
  }

  Future<void> openDownloadedFile(File file) async {
    await openSystemTarget(file.path);
  }

  Future<void> openExternalUrl(String url) async {
    if (!await confirmOpenExternalLink(url)) return;
    await openSystemTarget(url);
  }

  Future<bool> confirmOpenExternalLink(String url) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF232327),
        title: const Text('打开外部链接？'),
        content: SelectableText(
          url,
          style: const TextStyle(color: OsColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (kIsWeb) {
                openBrowserUrl(url);
                Navigator.pop(context, false);
                return;
              }
              Navigator.pop(context, true);
            },
            child: const Text('打开'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> openSystemTarget(String target) async {
    if (kIsWeb) {
      openBrowserUrl(target);
    } else if (Platform.isMacOS) {
      await Process.run('open', [target]);
    } else if (Platform.isWindows) {
      openWithWindowsShell(target);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [target]);
    }
  }

  bool isImageFile(XFile file) {
    return isImageContent(contentTypeForPath(file.name), file.name);
  }

  Future<void> handleDroppedFiles(List<XFile> files) async {
    if (files.isEmpty) return;
    await runGuarded(() async {
      final scope = chatScope;
      final channel = selectedChannel;
      final directPeer = selectedDirectUser();
      if (scope == ChatScope.channel && channel == null) {
        throw OpenSpeakException('未进入频道，无法上传文件');
      }
      if (scope == ChatScope.direct && directPeer == null) {
        throw OpenSpeakException('未选择私聊对象，无法上传文件');
      }
      final selected = <XFile>[];
      for (final item in files) {
        final file = await fileFromSelection(item);
        if (file != null) selected.add(file);
      }
      enqueueAttachmentUploads(
        selected,
        direct: scope == ChatScope.direct,
        targetId: scope == ChatScope.direct ? directPeer!.userId : channel!.id,
      );
    });
  }

  void scrollMessagesToEnd({bool animated = true, bool settle = false}) {
    if (!messageScrollController.hasClients) return;
    const target = 0.0;
    if (animated) {
      messageScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 120),
        curve: Curves.linear,
      );
    } else {
      messageScrollController.jumpTo(target);
    }
    if (!settle) return;
    for (final delay in const [
      Duration(milliseconds: 50),
      Duration(milliseconds: 150),
      Duration(milliseconds: 350),
    ]) {
      Future<void>.delayed(delay, () {
        if (!mounted || !messageScrollController.hasClients) return;
        messageScrollController.jumpTo(target);
      });
    }
  }

  bool get messageViewAtBottom {
    if (!messageScrollController.hasClients) return true;
    return messageScrollController.offset <= 32;
  }

  void onMessageScroll() {
    if (currentChatNewMessages <= 0 || !messageViewAtBottom || !mounted) {
      return;
    }
    unawaited(openCurrentChatLatestMessages(animated: false));
  }

  void showCurrentChatNewMessageHint() {
    currentChatNewMessages += 1;
  }

  void clearCurrentChatNewMessageHint() {
    currentChatNewMessages = 0;
  }

  Future<void> openCurrentChatLatestMessages({bool animated = true}) async {
    if (chatScope == ChatScope.channel) {
      await loadChannelMessages(scrollToEnd: false);
      if (!mounted) return;
    }
    setState(clearCurrentChatUnreadState);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => scrollMessagesToEnd(animated: animated),
    );
  }

  void clearCurrentChatUnreadState() {
    currentChatNewMessages = 0;
    if (chatScope == ChatScope.channel) {
      final channelId = selectedChannel?.id;
      if (channelId != null) {
        unreadState.clearChannel(channelId);
      }
      return;
    }
    final userId = selectedDirectUserId;
    if (userId != null) {
      directMessageStore.mergePending(userId);
      unreadState.clearDirect(userId);
    }
  }

  void clearChannelUnread(String channelId) {
    unreadState.clearChannel(channelId);
    clearCurrentChatNewMessageHint();
  }

  void retainChannelUnreadOnly(String channelId) {
    unreadState.retainChannelOnly(channelId);
    if (chatScope == ChatScope.channel) clearCurrentChatNewMessageHint();
  }

  void clearDirectUnread(String userId) {
    directMessageStore.mergePending(userId);
    unreadState.clearDirect(userId);
    clearCurrentChatNewMessageHint();
  }

  Future<void> restoreUnreadState(String serverId, String userId) async {
    final stored = await unreadState.load(serverId, userId);
    if (stored == null ||
        !mounted ||
        selectedServer?.id != serverId ||
        session?.user.id != userId) {
      return;
    }
    setState(
      () => unreadState.restoreChannels(
        stored,
        retainChannelId: channelMessageNotificationChannelId(),
      ),
    );
  }

  bool channelMessageMentionsCurrentUser(ChannelMessage message) {
    if (message.kind != 'text') return false;
    return textMentionsCurrentUser(message.body);
  }

  bool directMessageMentionsCurrentUser(DirectMessage message) {
    return textMentionsCurrentUser(message.body);
  }

  bool textMentionsCurrentUser(String body) {
    final auth = session;
    if (auth == null || body.isEmpty) return false;
    final candidates = <String>{
      auth.user.displayName,
      auth.user.id,
    }.map((value) => value.trim()).where((value) => value.isNotEmpty).toSet();
    final lower = body.toLowerCase();
    for (final candidate in candidates) {
      if (lower.contains('@${candidate.toLowerCase()}')) {
        return true;
      }
    }
    return false;
  }

  Future<void> refreshServerState({int? generation}) async {
    final client = api;
    final auth = session;
    final server = selectedServer;
    if (client == null || auth == null || server == null) return;
    final activeGeneration = generation ?? connectionGeneration;
    final nextState = await client.getServerState(auth.token, server.id);
    if (!isActiveConnectionGeneration(activeGeneration)) return;
    applyServerState(nextState);
    await followAuthoritativeVoiceChannel(
      nextState,
      generation: activeGeneration,
    );
  }

  Future<void> followAuthoritativeVoiceChannel(
    ServerState state, {
    required int generation,
  }) async {
    final targetId = state.currentUser.currentChannelId;
    if (!shouldFollowAuthoritativeVoiceChannel(
      joined: voiceSession.isJoined,
      authoritativeChannelId: targetId,
      localChannelId: voiceSession.currentChannelId,
      switchingTargetId: voiceChannelSwitchTargetId,
    )) {
      return;
    }
    final target = channelForId(
      state.channels,
      targetId,
      fallbackToFirst: false,
    );
    if (target == null) return;
    await switchLocalVoiceChannel(target, generation: generation);
  }

  Future<void> switchLocalVoiceChannel(
    Channel channel, {
    int? generation,
  }) async {
    if (voiceSession.currentChannelId == channel.id ||
        voiceChannelSwitchTargetId == channel.id) {
      return;
    }
    voiceChannelSwitchTargetId = channel.id;
    try {
      await joinLiveKitVoice(generation: generation, channel: channel);
    } finally {
      if (voiceChannelSwitchTargetId == channel.id) {
        voiceChannelSwitchTargetId = null;
      }
    }
  }

  void applyServerState(ServerState state) {
    final auth = session;
    if (!mounted || auth == null) return;
    final authoritativeChannel = channelForId(
      state.channels,
      state.currentUser.currentChannelId,
      fallbackToFirst: false,
    );
    final retainedChannel = channelForId(
      state.channels,
      selectedChannel?.id,
      fallbackToFirst: false,
    );
    final suggestedChannel = channelForId(
      state.channels,
      state.currentUser.selectedChannelId,
    );
    final previousCurrentChannelId = channelMessageNotificationChannelId();
    setState(() {
      channels = state.channels;
      presence = state.presence;
      currentServerRole = state.currentUser.role;
      currentServerPermissions = state.currentUser.permissions;
      messageRetractWindowMinutes = state.messageRetractWindowMinutes;
      myVoiceState = voiceStateForUser(state.presence, auth.user.id);
      selectedChannel =
          authoritativeChannel ?? retainedChannel ?? suggestedChannel;
      if (authoritativeChannel != null &&
          authoritativeChannel.id != previousCurrentChannelId) {
        retainChannelUnreadOnly(authoritativeChannel.id);
      }
    });
    updateVoiceMediaRouting();
  }

  void updateVoiceMediaRouting() {
    final channelId = voiceSession.currentChannelId;
    final updates = <Future<void>>[
      voiceSession.updateAuthorizedScreenShares({
        if (channelId != null)
          for (final state in presence.voiceStates)
            if (state.channelId == channelId && state.screenSharing)
              state.userId,
      }),
    ];
    if (voiceSession.usesPersistentRoom && channelId != null) {
      updates.add(
        voiceSession.updateChannelMembers(
          voiceChannelMemberUserIds(
            presence,
            channelId,
            includeUserId: session?.user.id,
          ),
        ),
      );
    }
    unawaited(
      Future.wait(updates).catchError((Object error, StackTrace stackTrace) {
        ClientLog.error('voice.routing', error, stackTrace);
        return <void>[];
      }),
    );
  }

  bool hasServerPermission(String permission) =>
      currentServerRole == 'owner' ||
      currentServerPermissions.contains(permission);

  bool canRetractChannelMessage(ChannelMessage message) {
    final createdAt = message.createdAt;
    return createdAt == null ||
        DateTime.now().toUtc().isBefore(
          createdAt.toUtc().add(Duration(minutes: messageRetractWindowMinutes)),
        );
  }

  Future<
    ({
      Uint8List? key,
      String deviceId,
      String epochId,
      int keyIndex,
      bool keyActive,
      bool mediaKeySlots,
    })
  >
  prepareVoiceEncryption(Channel channel) async {
    if (selectedServer?.encryptionMode != 'e2ee') {
      return (
        key: null,
        deviceId: '',
        epochId: '',
        keyIndex: 0,
        keyActive: true,
        mediaKeySlots: false,
      );
    }
    final client = api;
    final auth = session;
    final identity = e2eeDeviceIdentity;
    if (client == null || auth == null || identity == null) {
      throw OpenSpeakException('当前设备没有媒体端到端加密密钥');
    }
    final state = await client.getChannelE2EEState(
      auth.token,
      channel.id,
      media: true,
    );
    final key = await ensureChannelKey(
      channel,
      epochId: state.epoch.id,
      media: true,
    );
    return (
      key: Uint8List.fromList(await key.extractBytes()),
      deviceId: identity.deviceId,
      epochId: state.epoch.id,
      keyIndex: state.mediaKeyIndex,
      keyActive: state.mediaKeyActive,
      mediaKeySlots: state.mediaKeySlots,
    );
  }

  Future<void> joinLiveKitVoice({
    int? generation,
    Channel? channel,
    bool forceReconnect = false,
  }) async {
    final client = api;
    final auth = session;
    final server = selectedServer;
    final targetChannel = channel ?? selectedChannel;
    if (client == null ||
        auth == null ||
        server == null ||
        targetChannel == null) {
      return;
    }
    final activeGeneration = generation ?? connectionGeneration;
    if (!isActiveConnectionGeneration(activeGeneration)) return;
    final previousVoiceChannelId = voiceSession.currentChannelId;
    final wasVoiceConnected = voiceSession.snapshot.connected;
    final voiceJoinRequest = voiceSession.beginJoinRequest();
    final channelMemberUserIds = voiceChannelMemberUserIds(
      presence,
      targetChannel.id,
      includeUserId: auth.user.id,
    );
    await runGuarded(() async {
      Future<void> connect() async {
        if (!isActiveConnectionGeneration(activeGeneration) ||
            !voiceSession.isJoinRequestCurrent(voiceJoinRequest)) {
          return;
        }
        final encryption = await prepareVoiceEncryption(targetChannel);
        if (!isActiveConnectionGeneration(activeGeneration) ||
            !voiceSession.isJoinRequestCurrent(voiceJoinRequest)) {
          return;
        }
        await voiceSession.join(
          api: client,
          authToken: auth.token,
          serverId: server.id,
          channelId: targetChannel.id,
          localUserId: auth.user.id,
          channelMemberUserIds: channelMemberUserIds,
          requestGeneration: voiceJoinRequest,
          e2eeKey: encryption.key,
          e2eeDeviceId: encryption.deviceId,
          e2eeEpochId: encryption.epochId,
        );
      }

      if (!isActiveConnectionGeneration(activeGeneration)) return;
      if (!forceReconnect && voiceSession.canSwitchPersistentChannel) {
        final encryption = await prepareVoiceEncryption(targetChannel);
        if (!isActiveConnectionGeneration(activeGeneration) ||
            !voiceSession.isJoinRequestCurrent(voiceJoinRequest)) {
          return;
        }
        await switchVoiceChannelWithReconnectFallback(
          switchWithoutReconnect: () => voiceSession.switchPersistentChannel(
            channelId: targetChannel.id,
            channelMemberUserIds: channelMemberUserIds,
            requestGeneration: voiceJoinRequest,
            e2eeKey: encryption.key,
            e2eeEpochId: encryption.epochId,
            e2eeKeyIndex: encryption.keyIndex,
            e2eeKeyActive: encryption.keyActive,
            mediaKeySlots: encryption.mediaKeySlots,
          ),
          reconnect: (error, stackTrace) async {
            if (!isActiveConnectionGeneration(activeGeneration) ||
                !voiceSession.isJoinRequestCurrent(voiceJoinRequest)) {
              return;
            }
            ClientLog.error('voice.channel_fallback', error, stackTrace);
            await connect();
          },
        );
      } else {
        await connect();
      }
      if (!voiceSession.isJoinRequestCurrent(voiceJoinRequest)) return;
      final voiceToken = voiceSession.snapshot.voiceToken;
      if (voiceToken?.e2eeRequired == true &&
          voiceToken?.mediaKeySlots == true &&
          voiceToken?.e2eeKeyActive == false) {
        unawaited(
          completeVoiceMediaKeyTransition(
            targetChannel,
            epochId: voiceToken!.e2eeEpochId,
            keyIndex: voiceToken.e2eeKeyIndex,
          ),
        );
      }
      await audioDeviceMonitor.refresh();
      if (!isActiveConnectionGeneration(activeGeneration) ||
          !voiceSession.isJoinRequestCurrent(voiceJoinRequest)) {
        return;
      }
      final state = voiceSession.snapshot.voiceState;
      if (state != null) setState(() => myVoiceState = state);
      if (voiceSession.snapshot.connected &&
          (!wasVoiceConnected || previousVoiceChannelId != targetChannel.id)) {
        unawaited(soundEffects.play(SoundEffect.memberJoin));
      }
      scheduleRealtimeStateRefresh();
    });
  }

  Future<void> leaveLiveKitVoice() async {
    final activeGeneration = connectionGeneration;
    await runGuarded(() async {
      await leaveVoiceSession(clearVoiceState: true);
      if (!isActiveConnectionGeneration(activeGeneration)) return;
      setState(() => myVoiceState = null);
      scheduleRealtimeStateRefresh();
    });
  }

  Future<void> leaveVoiceSession({required bool clearVoiceState}) async {
    final wasJoined = voiceSession.isJoined;
    clearVoiceReconnectSound();
    await voiceSession.leave(clearVoiceState: clearVoiceState);
    if (wasJoined) unawaited(soundEffects.play(SoundEffect.memberLeave));
  }

  Future<void> setMuted(bool value) async {
    if (!value && !hasServerPermission('voice.speak')) {
      if (mounted) setState(() => error = '当前账号没有发送语音的权限');
      return;
    }
    await voiceSession.setMuted(value);
    final state = voiceSession.snapshot.voiceState;
    if (state != null && mounted) setState(() => myVoiceState = state);
  }

  Future<void> setListenOff(bool value) async {
    await voiceSession.setListenOff(value);
    final state = voiceSession.snapshot.voiceState;
    if (state != null && mounted) setState(() => myVoiceState = state);
  }

  OwnerDeviceRegistration ownerDeviceRegistration(OwnerDeviceKey key) {
    return OwnerDeviceRegistration(
      deviceId: key.deviceId,
      publicKey: key.publicKey,
      label: '${Platform.operatingSystem} OpenSpeak Desktop',
      platform: Platform.operatingSystem,
      clientVersion: '1.0.0',
    );
  }

  Future<void> showClientSettings({String? onlyPage}) async {
    assert(onlyPage == null || onlyPage == 'profile' || onlyPage == 'audio');
    await audioDeviceMonitor.refresh();
    if (!mounted) return;
    final profileController = TextEditingController(text: localDisplayName);
    File? pendingAvatarFile;
    String? nextInputDeviceId;
    String? nextOutputDeviceId;
    var nextMicrophoneActivationMode = microphoneActivationMode;
    var nextMicrophoneThreshold = microphoneThreshold;
    var nextPushToTalkHotkey = microphonePushToTalkHotkey;
    var nextSoundEffectVolume = soundEffectVolume;
    var selectedPage = onlyPage ?? 'profile';
    try {
      final action = await showDialog<String>(
        context: context,
        barrierColor: const Color(0xC7000000),
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => OsSettingsDialog(
            icon: Icons.tune_rounded,
            eyebrow: '',
            title: '个人设置',
            subtitle: '',
            compactHeader: true,
            maxWidth: 920,
            child: OsSplitSettingsBody(
              showNavigation: onlyPage == null,
              navigation: [
                OsSettingsNavEntry(
                  icon: Icons.account_circle_outlined,
                  label: '个人资料',
                  selected: selectedPage == 'profile',
                  onTap: () => setDialogState(() => selectedPage = 'profile'),
                ),
                OsSettingsNavEntry(
                  icon: Icons.headphones_rounded,
                  label: '音频设备',
                  selected: selectedPage == 'audio',
                  onTap: () => setDialogState(() => selectedPage = 'audio'),
                ),
              ],
              content: switch (selectedPage) {
                'audio' => OsClientAudioSettingsPane(
                  deviceMonitor: audioDeviceMonitor,
                  initialInputDeviceId: selectedAudioInputDeviceId,
                  initialOutputDeviceId: selectedAudioOutputDeviceId,
                  initialActivationMode: microphoneActivationMode,
                  initialThreshold: microphoneThreshold,
                  initialPushToTalkHotkey: microphonePushToTalkHotkey,
                  initialSoundEffectVolume: soundEffectVolume,
                  microphoneInputLevel: voiceSession.microphoneInputLevel,
                  captureCoordinator: voiceSession,
                  devicesOnly: onlyPage == 'audio',
                  onSoundEffectPreview: (volume) => unawaited(
                    soundEffects.play(
                      SoundEffect.messageDirect,
                      volume: volume,
                    ),
                  ),
                  onSave:
                      (
                        inputId,
                        outputId,
                        activationMode,
                        threshold,
                        pushToTalkHotkey,
                        effectVolume,
                      ) {
                        nextInputDeviceId = inputId;
                        nextOutputDeviceId = outputId;
                        nextMicrophoneActivationMode = activationMode;
                        nextMicrophoneThreshold = threshold;
                        nextPushToTalkHotkey = pushToTalkHotkey;
                        nextSoundEffectVolume = effectVolume;
                        Navigator.pop(context, 'save-audio');
                      },
                ),
                _ => OsSettingsPage(
                  icon: Icons.person_rounded,
                  title: '个人资料',
                  subtitle: kIsWeb ? '设置浏览器中使用的昵称与显示身份。' : '设置本机头像、昵称与显示身份。',
                  footer: Align(
                    alignment: Alignment.centerRight,
                    child: OsPrimaryButton(
                      label: '保存更改',
                      icon: Icons.check_rounded,
                      onPressed: () => Navigator.pop(context, 'save-profile'),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OsProfilePreview(
                        displayName: profileController.text.trim().isEmpty
                            ? localDisplayName
                            : profileController.text.trim(),
                        avatarFile: pendingAvatarFile ?? localAvatarFile,
                        avatarUri:
                            kIsWeb && (session?.user.avatarVersion ?? 0) > 0
                            ? chatAvatarUriForUser(session!.user.id)
                            : null,
                        avatarToken: kIsWeb ? session?.token : null,
                        onChooseAvatar: kIsWeb
                            ? null
                            : () async {
                                final selected = await openFile(
                                  acceptedTypeGroups: const [
                                    XTypeGroup(
                                      label: '头像图片',
                                      extensions: ['jpg', 'jpeg', 'png', 'gif'],
                                    ),
                                  ],
                                );
                                if (selected != null) {
                                  setDialogState(
                                    () =>
                                        pendingAvatarFile = File(selected.path),
                                  );
                                }
                              },
                      ),
                      const SizedBox(height: 14),
                      const OsFieldLabel('本机昵称'),
                      const SizedBox(height: 7),
                      TextField(
                        controller: profileController,
                        decoration: const InputDecoration(
                          hintText: '输入希望显示的昵称',
                          prefixIcon: Icon(Icons.badge_outlined, size: 20),
                        ),
                        onChanged: (_) => setDialogState(() {}),
                        onSubmitted: (_) =>
                            Navigator.pop(context, 'save-profile'),
                      ),
                    ],
                  ),
                ),
              },
            ),
          ),
        ),
      );
      switch (action) {
        case 'save-profile':
          await applyLocalDisplayName(
            profileController.text,
            avatarFile: pendingAvatarFile,
          );
        case 'save-audio':
          await setAudioSettings(
            nextInputDeviceId,
            nextOutputDeviceId,
            activationMode: nextMicrophoneActivationMode,
            threshold: nextMicrophoneThreshold,
            pushToTalkHotkeyBinding: nextPushToTalkHotkey,
            effectVolume: nextSoundEffectVolume,
          );
        case null:
          return;
      }
    } finally {
      profileController.dispose();
    }
  }

  Future<void> applyLocalDisplayName(String value, {File? avatarFile}) async {
    final profile = await localProfileService.save(
      value,
      avatarFile: avatarFile,
    );
    if (profile == null) return;
    if (!mounted) return;
    setState(() {
      localDisplayName = profile.displayName;
      if (profile.avatar != null) {
        localAvatarFile = profile.avatar;
        localAvatarRevision += 1;
      }
    });
    final client = api;
    final auth = session;
    if (client == null || auth == null) return;
    await runGuarded(() async {
      var updatedUser = auth.user;
      if (profile.avatar != null) {
        updatedUser = await client.uploadCurrentUserAvatar(
          auth.token,
          profile.avatar!,
        );
        await localProfileService.markAvatarSynced();
      }
      updatedUser = await client.updateCurrentUserDisplayName(
        auth.token,
        profile.displayName,
      );
      if (!mounted || !identical(session, auth)) return;
      setState(() {
        session = AuthSession(
          token: auth.token,
          user: updatedUser,
          expiresAt: auth.expiresAt,
        );
      });
      if (session case final AuthSession updatedSession) {
        cacheWebAuthSession(updatedSession);
      }
      await refreshServerState();
    });
  }

  Future<void> showClientProfileSettings() async {
    final controller = TextEditingController(text: localDisplayName);
    try {
      final nextName = await showDialog<String>(
        context: context,
        barrierColor: const Color(0xC7000000),
        builder: (context) => OsSettingsDialog(
          icon: Icons.person_rounded,
          eyebrow: '客户端设置  /  个人资料',
          title: '个人资料',
          subtitle: '这个昵称保存在本机，并在连接服务器时作为你的显示名称。',
          actions: [
            OsSecondaryButton(
              label: '取消',
              onPressed: () => Navigator.pop(context),
            ),
            OsPrimaryButton(
              label: '保存更改',
              icon: Icons.check_rounded,
              onPressed: () => Navigator.pop(context, controller.text.trim()),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OsProfilePreview(displayName: localDisplayName),
              const SizedBox(height: 18),
              const OsFieldLabel('本机昵称'),
              const SizedBox(height: 7),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '输入希望显示的昵称',
                  prefixIcon: Icon(Icons.badge_outlined, size: 20),
                ),
                onSubmitted: (value) => Navigator.pop(context, value.trim()),
              ),
            ],
          ),
        ),
      );
      if (nextName == null) return;
      await applyLocalDisplayName(nextName);
    } finally {
      controller.dispose();
    }
  }

  Future<void> showServerSettings({String initialPage = 'overview'}) async {
    if (serverMenuOpen) {
      setState(() => serverMenuOpen = false);
    }
    final server = selectedServer;
    final serverName = server?.name ?? selectedConnection?.name ?? '服务器';
    final ownerStatus = selectedServerOwnerStatus;
    final client = api;
    final auth = session;
    final isOwner = ownerStatus?.isOwner == true;
    final canEditProfile =
        isOwner || currentServerPermissions.contains('server.profile.update');
    final allowedPages = isOwner
        ? <String>[
            'overview',
            'general',
            'transport',
            'owner',
            'permissions',
            'web',
          ]
        : serverSettingsPages(currentServerPermissions);
    if (allowedPages.isEmpty ||
        client == null ||
        auth == null ||
        server == null) {
      return;
    }
    var settingsServer = server;
    if (isOwner ||
        currentServerPermissions.contains('server.settings.update')) {
      try {
        settingsServer = await client.getServerSettings(auth.token, server.id);
      } catch (exception) {
        if (mounted) setState(() => error = '$exception');
        return;
      }
    }
    ServerPermissionSettings? permissionSettings;
    if (isOwner) {
      try {
        permissionSettings = await client.getServerPermissions(
          auth.token,
          server.id,
        );
      } catch (exception) {
        if (mounted) setState(() => error = '$exception');
      }
    }
    final adminPermissions = <String>{...?permissionSettings?.admin};
    final userPermissions = <String>{...?permissionSettings?.user};
    WebSettings? webSettings;
    if (isOwner) {
      try {
        webSettings = await client.getWebSettings(auth.token, server.id);
      } catch (exception) {
        if (mounted) setState(() => error = '$exception');
      }
    }
    var mediaNodes = <MediaNode>[];
    var fileNodes = <FileNode>[];
    if (allowedPages.contains('transport')) {
      try {
        mediaNodes = await client.listMediaNodes(auth.token, server.id);
        fileNodes = await client.listFileNodes(auth.token, server.id);
      } catch (exception) {
        if (mounted) setState(() => error = '$exception');
        return;
      }
    }
    var retractWindowMinutes =
        permissionSettings?.messageRetractWindowMinutes ??
        messageRetractWindowMinutes;
    if (!mounted) return;

    File? cachedServerAvatar;
    if (!kIsWeb && settingsServer.avatarVersion > 0) {
      try {
        final support = await getApplicationSupportDirectory();
        cachedServerAvatar = await ensureServerAvatarCached(
          cacheDir: Directory(
            '${support.path}${Platform.pathSeparator}openspeak${Platform.pathSeparator}server_avatars',
          ),
          serverId: server.id,
          avatarVersion: settingsServer.avatarVersion,
          download: () => client.downloadServerAvatar(
            server.id,
            settingsServer.avatarVersion,
          ),
        );
      } catch (_) {
        // Fall back to the existing network image if the local cache is unavailable.
      }
    }
    if (!mounted || selectedServer?.id != server.id) return;

    final serverNameController = TextEditingController(text: serverName);
    final retentionController = TextEditingController(
      text: '${settingsServer.historyRetentionDays}',
    );
    final passwordController = TextEditingController();
    final tlsIdentifierController = TextEditingController(
      text: settingsServer.tlsIdentifier,
    );
    final activeMediaNode = mediaNodes
        .where((node) => node.enabled && !node.draining)
        .firstOrNull;
    final configuredMediaNode =
        mediaNodes
            .where((node) => !node.isLocal && node.enabled && !node.draining)
            .firstOrNull ??
        mediaNodes.where((node) => !node.isLocal).firstOrNull;
    final selectedMediaNodeId = configuredMediaNode?.id;
    var screenRelayMode = activeMediaNode == null || activeMediaNode.isLocal
        ? 'local'
        : 'external';
    final mediaNodeName = configuredMediaNode?.name ?? '外部屏幕共享节点';
    final configuredMediaNodeUri = Uri.tryParse(
      configuredMediaNode?.liveKitUrl ?? '',
    );
    final mediaNodePath = configuredMediaNode == null
        ? ''
        : configuredMediaNodeUri?.path ?? '';
    final mediaNodeHostController = TextEditingController(
      text: configuredMediaNodeUri?.host ?? '',
    );
    final mediaNodePortController = TextEditingController(
      text: configuredMediaNodeUri?.hasPort == true
          ? '${configuredMediaNodeUri!.port}'
          : '27412',
    );
    final mediaNodeKeyController = TextEditingController(
      text: configuredMediaNode?.apiKey ?? '',
    );
    final mediaNodeSecretController = TextEditingController();

    final configuredFileNode =
        fileNodes
            .where((node) => node.id == settingsServer.attachmentFileNodeId)
            .firstOrNull ??
        fileNodes.where((node) => node.enabled).firstOrNull ??
        fileNodes.firstOrNull;
    final selectedFileNodeId = configuredFileNode?.id;
    final configuredFileNodeUri = Uri.tryParse(
      configuredFileNode?.baseUrl ?? '',
    );
    final fileNodePath = configuredFileNode == null
        ? '/files'
        : configuredFileNodeUri?.path ?? '';
    final fileNodeHostController = TextEditingController(
      text: configuredFileNodeUri?.host ?? '',
    );
    final fileNodePortController = TextEditingController(
      text: configuredFileNodeUri?.hasPort == true
          ? '${configuredFileNodeUri!.port}'
          : '27412',
    );
    final fileNodeSecretController = TextEditingController();

    File? pendingServerAvatar;
    var selectedPage = allowedPages.contains(initialPage)
        ? initialPage
        : allowedPages.first;
    var defaultChannelId =
        settingsServer.defaultChannelId ?? channels.firstOrNull?.id;
    var clearServerPassword = false;
    var encryptionMode = settingsServer.encryptionMode;
    var tlsCertificateType = settingsServer.tlsCertificateType.isEmpty
        ? 'domain'
        : settingsServer.tlsCertificateType;
    final tlsHealth = tlsCertificateHealth(settingsServer.tlsExpiresAt);
    final tlsExpiry = settingsServer.tlsExpiresAt
        ?.toLocal()
        .toString()
        .split('.')
        .first;
    final tlsRenewal = settingsServer.tlsRenewalAt
        ?.toLocal()
        .toString()
        .split('.')
        .first;
    final tlsActive = settingsServer.tlsStatus == 'active';
    final tlsStatusText = tlsActive
        ? tlsHealth == TlsCertificateHealth.expired
              ? '证书已过期，有效期至 ${tlsExpiry ?? '未知'}；Caddy 将继续自动重试续签'
              : '证书已启用，有效期至 ${tlsExpiry ?? '未知'}；下次续签时间 ${tlsRenewal ?? '由 Caddy 自动安排'}'
        : settingsServer.tlsError.isNotEmpty
        ? '上次启用失败：${settingsServer.tlsError}'
        : '保存时将检查网络、申请证书，并在 HTTPS/WSS 自检通过后切换。';
    final tlsStatusColor = !tlsActive
        ? OsColors.dim
        : switch (tlsHealth) {
            TlsCertificateHealth.valid => OsColors.green,
            TlsCertificateHealth.expiring => OsColors.warning,
            TlsCertificateHealth.expired => OsColors.danger,
            TlsCertificateHealth.unknown => OsColors.dim,
          };
    var tlsDetectionError = '';
    var voiceAudioBitrateKbps = settingsServer.voiceAudioBitrateKbps;
    const screenShareBitrateRows = [
      ('720p', '720p'),
      ('1080p', '1080p'),
      ('source', 'Source'),
    ];
    const screenShareBitrateFps = [15, 30, 60];
    final screenShareBitrateControllers = {
      for (final row in screenShareBitrateRows)
        for (final fps in screenShareBitrateFps)
          (row.$1, fps): TextEditingController(
            text:
                '${settingsServer.screenShareBitrateLimits.bitrateMbps(row.$1, fps)}',
          ),
    };
    var attachmentMode = settingsServer.attachmentExternalEnabled
        ? 'external'
        : 'local';
    var webEnabled = webSettings?.enabled ?? false;
    var webCustomPathEnabled = webSettings?.customPathEnabled ?? true;
    final webPathController = TextEditingController(
      text: webSettings?.path ?? 'chat',
    );
    final savedWebUri = Uri.tryParse(webSettings?.accessUrl ?? '');
    final webOrigin = savedWebUri != null && savedWebUri.host.isNotEmpty
        ? savedWebUri.replace(path: '/', query: null, fragment: null).toString()
        : settingsServer.tlsIdentifier.isEmpty
        ? 'https://服务器:27412/'
        : Uri(
            scheme: 'https',
            host: settingsServer.tlsIdentifier,
            port: 27412,
            path: '/',
          ).toString();
    try {
      final action = await showDialog<String>(
        context: context,
        barrierColor: const Color(0xC7000000),
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => OsSettingsDialog(
            icon: Icons.dns_rounded,
            eyebrow: '',
            title: '服务器设置',
            subtitle: serverName,
            compactHeader: true,
            maxWidth: 920,
            child: OsSplitSettingsBody(
              navigation: [
                if (allowedPages.contains('overview'))
                  OsSettingsNavEntry(
                    icon: Icons.dashboard_outlined,
                    label: '服务器概览',
                    selected: selectedPage == 'overview',
                    onTap: () =>
                        setDialogState(() => selectedPage = 'overview'),
                  ),
                if (allowedPages.contains('general'))
                  OsSettingsNavEntry(
                    icon: Icons.tune_rounded,
                    label: '常规设置',
                    selected: selectedPage == 'general',
                    onTap: () => setDialogState(() => selectedPage = 'general'),
                  ),
                if (allowedPages.contains('transport'))
                  OsSettingsNavEntry(
                    icon: Icons.security_rounded,
                    label: '传输与安全',
                    selected: selectedPage == 'transport',
                    onTap: () =>
                        setDialogState(() => selectedPage = 'transport'),
                  ),
                if (allowedPages.contains('audit'))
                  OsSettingsNavEntry(
                    icon: Icons.history_rounded,
                    label: '审计日志',
                    selected: selectedPage == 'audit',
                    onTap: () => setDialogState(() => selectedPage = 'audit'),
                  ),
                if (allowedPages.contains('owner'))
                  OsSettingsNavEntry(
                    icon: Icons.devices_rounded,
                    label: '设备与会话',
                    selected: selectedPage == 'owner',
                    onTap: () => setDialogState(() => selectedPage = 'owner'),
                  ),
                if (allowedPages.contains('permissions'))
                  OsSettingsNavEntry(
                    icon: Icons.admin_panel_settings_outlined,
                    label: '服务器权限管理',
                    selected: selectedPage == 'permissions',
                    onTap: () =>
                        setDialogState(() => selectedPage = 'permissions'),
                  ),
                if (allowedPages.contains('web'))
                  OsSettingsNavEntry(
                    icon: Icons.language_rounded,
                    label: '网页端设置',
                    selected: selectedPage == 'web',
                    onTap: () => setDialogState(() => selectedPage = 'web'),
                  ),
              ],
              content: switch (selectedPage) {
                'web' => OsSettingsPage(
                  icon: Icons.language_rounded,
                  title: '网页端设置',
                  subtitle: '网页端与主服务器共用 HTTPS 端口，并沿用当前附件承载配置。',
                  footer: Align(
                    alignment: Alignment.centerRight,
                    child: OsPrimaryButton(
                      label: '保存更改',
                      icon: Icons.check_rounded,
                      onPressed: () => Navigator.pop(context, 'save-web'),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OsFormCard(
                        icon: Icons.public_rounded,
                        title: '网页入口',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('启用网页端'),
                              subtitle: const Text('关闭后网页入口不可访问，现有网页会话也会断开'),
                              value: webEnabled,
                              onChanged: (value) =>
                                  setDialogState(() => webEnabled = value),
                            ),
                            const Divider(height: 20),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('使用自定义访问路径'),
                              subtitle: const Text('开启后根地址保持空白，只能通过下方路径进入'),
                              value: webCustomPathEnabled,
                              onChanged: (value) => setDialogState(
                                () => webCustomPathEnabled = value,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: webPathController,
                              enabled: webCustomPathEnabled,
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'[A-Za-z0-9_-]'),
                                ),
                                LengthLimitingTextInputFormatter(64),
                              ],
                              decoration: const InputDecoration(
                                labelText: '自定义路径',
                                prefixText: '/',
                                helperText: '不能使用 api、ws 或 rtc',
                              ),
                              onChanged: (_) => setDialogState(() {}),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      OsFormCard(
                        icon: Icons.link_rounded,
                        title: '访问地址',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SelectableText(
                              webCustomPathEnabled
                                  ? '$webOrigin${webPathController.text}/'
                                  : webOrigin,
                              style: const TextStyle(
                                color: OsColors.text,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _ActivationHint(
                              text: webSettings?.assetsAvailable == false
                                  ? '当前服务器尚未安装网页资源，安装后才能启用。'
                                  : '网页端自动使用“传输与安全”中的附件承载方式，不提供单独节点配置。',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                'permissions' => OsServerPermissionsPage(
                  adminPermissions: adminPermissions,
                  userPermissions: userPermissions,
                  messageRetractWindowMinutes: retractWindowMinutes,
                  onChanged: (role, permission, enabled) {
                    setDialogState(() {
                      final values = role == 'admin'
                          ? adminPermissions
                          : userPermissions;
                      if (enabled) {
                        values.add(permission);
                      } else {
                        values.remove(permission);
                      }
                    });
                  },
                  onMessageRetractWindowChanged: (value) =>
                      setDialogState(() => retractWindowMinutes = value),
                  onSave: () => Navigator.pop(context, 'save-permissions'),
                ),
                'general' => OsSettingsPage(
                  icon: Icons.tune_rounded,
                  title: '常规设置',
                  subtitle: '设置默认频道、消息保留时间和服务器密码。',
                  footer: Align(
                    alignment: Alignment.centerRight,
                    child: OsPrimaryButton(
                      label: '保存更改',
                      icon: Icons.check_rounded,
                      onPressed: () => Navigator.pop(context, 'save-general'),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OsFormCard(
                        icon: Icons.tag_rounded,
                        title: '默认频道',
                        child: DropdownButtonFormField<String>(
                          initialValue: defaultChannelId,
                          items: [
                            for (final channel in channels)
                              DropdownMenuItem(
                                value: channel.id,
                                child: Text(channel.name),
                              ),
                          ],
                          onChanged: (value) => defaultChannelId = value,
                        ),
                      ),
                      const SizedBox(height: 12),
                      OsFormCard(
                        icon: Icons.history_rounded,
                        title: '消息历史',
                        child: TextField(
                          controller: retentionController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: '保留天数',
                            helperText: '0 表示不保留历史消息',
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      OsFormCard(
                        icon: Icons.password_rounded,
                        title: '服务器密码',
                        child: Column(
                          children: [
                            TextField(
                              controller: passwordController,
                              obscureText: true,
                              enabled: !clearServerPassword,
                              decoration: InputDecoration(
                                labelText: settingsServer.passwordProtected
                                    ? '输入新密码；留空则保持不变'
                                    : '设置连接密码；留空则不启用',
                              ),
                            ),
                            if (settingsServer.passwordProtected)
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('清除现有服务器密码'),
                                value: clearServerPassword,
                                onChanged: (value) => setDialogState(
                                  () => clearServerPassword = value == true,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                'audit' => OsAuditLogPage(
                  api: client,
                  token: auth.token,
                  serverId: server.id,
                ),
                'transport' => OsSettingsPage(
                  icon: Icons.security_rounded,
                  title: '传输与安全',
                  subtitle: '选择语音质量、内容保护、附件承载与屏幕共享路径。',
                  footer: Align(
                    alignment: Alignment.centerRight,
                    child: OsPrimaryButton(
                      label: '保存更改',
                      icon: Icons.check_rounded,
                      onPressed: () => Navigator.pop(context, 'save-transport'),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OsFormCard(
                        icon: Icons.graphic_eq_rounded,
                        title: '语音传输',
                        child: Column(
                          children: [
                            for (final option in const [
                              (24, '超低', '最低流量，适合网络较差 · 预计 24 kbps'),
                              (48, '低', '节省流量，适合普通语音 · 预计 48 kbps'),
                              (64, '中', '清晰语音，推荐默认 · 预计 64 kbps'),
                              (96, '高', '更清晰，使用更多带宽 · 预计 96 kbps'),
                              (128, '超高', '最高质量与带宽占用 · 预计 128 kbps'),
                            ]) ...[
                              if (option.$1 != 24) const SizedBox(height: 7),
                              MicrophoneActivationOption(
                                icon: Icons.multitrack_audio_rounded,
                                selected: voiceAudioBitrateKbps == option.$1,
                                title: option.$2,
                                subtitle: option.$3,
                                onTap: () => setDialogState(
                                  () => voiceAudioBitrateKbps = option.$1,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      OsFormCard(
                        icon: Icons.screen_share_rounded,
                        title: '屏幕共享画质',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              '设置各档位的发送码率上限（Mbps）。实际码率仍由 WebRTC 根据网络状况动态调整。',
                              style: TextStyle(
                                color: OsColors.muted,
                                height: 1.45,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                const SizedBox(width: 68),
                                for (final fps in screenShareBitrateFps)
                                  Expanded(
                                    child: Text(
                                      '$fps FPS',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: OsColors.dim,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            for (final row in screenShareBitrateRows) ...[
                              Row(
                                children: [
                                  SizedBox(
                                    width: 68,
                                    child: Text(
                                      row.$2,
                                      style: const TextStyle(
                                        color: OsColors.muted,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  for (final fps in screenShareBitrateFps)
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.only(left: 8),
                                        child: TextField(
                                          key: ValueKey(
                                            'screen-share-bitrate-${row.$1}-$fps',
                                          ),
                                          controller:
                                              screenShareBitrateControllers[(
                                                row.$1,
                                                fps,
                                              )],
                                          keyboardType: TextInputType.number,
                                          inputFormatters: [
                                            FilteringTextInputFormatter
                                                .digitsOnly,
                                            LengthLimitingTextInputFormatter(3),
                                          ],
                                          textAlign: TextAlign.center,
                                          decoration: const InputDecoration(
                                            isDense: true,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              if (row.$1 != 'source') const SizedBox(height: 9),
                            ],
                            const SizedBox(height: 10),
                            Align(
                              alignment: Alignment.centerRight,
                              child: OsSecondaryButton(
                                label: '恢复默认值',
                                icon: Icons.restart_alt_rounded,
                                onPressed: () {
                                  for (final row in screenShareBitrateRows) {
                                    for (final fps in screenShareBitrateFps) {
                                      screenShareBitrateControllers[(
                                                row.$1,
                                                fps,
                                              )]!
                                              .text =
                                          '${ScreenShareBitrateLimits.defaults.bitrateMbps(row.$1, fps)}';
                                    }
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      OsFormCard(
                        icon: Icons.shield_outlined,
                        title: '服务器加密类型',
                        child: Column(
                          children: [
                            MicrophoneActivationOption(
                              icon: Icons.lock_open_rounded,
                              selected: encryptionMode == 'none',
                              title: '不加密',
                              subtitle: '不做额外内容加密；保留 WebRTC 自带的安全传输',
                              onTap:
                                  settingsServer.tlsStatus == 'active' &&
                                      !isOwner
                                  ? null
                                  : () => setDialogState(
                                      () => encryptionMode = 'none',
                                    ),
                            ),
                            const SizedBox(height: 7),
                            MicrophoneActivationOption(
                              icon: Icons.https_outlined,
                              selected: encryptionMode == 'transport',
                              title: '传输层加密',
                              subtitle: '通过 HTTPS、WSS 等安全传输保护连接',
                              onTap: isOwner
                                  ? () => setDialogState(
                                      () => encryptionMode = 'transport',
                                    )
                                  : null,
                              expanded: encryptionMode == 'transport'
                                  ? Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        const Divider(height: 18),
                                        MicrophoneActivationOption(
                                          icon: Icons.language_rounded,
                                          selected:
                                              tlsCertificateType == 'domain',
                                          title: '域名证书（推荐）',
                                          subtitle:
                                              '域名已解析到服务器，80/TCP 可访问；自动申请和续签',
                                          onTap: isOwner
                                              ? () => setDialogState(() {
                                                  tlsCertificateType = 'domain';
                                                  tlsDetectionError = '';
                                                })
                                              : null,
                                        ),
                                        const SizedBox(height: 7),
                                        MicrophoneActivationOption(
                                          icon: Icons.public_rounded,
                                          selected: tlsCertificateType == 'ip',
                                          title: '公网 IP 证书',
                                          subtitle: '仅限固定公网 IP；有效期短，将自动频繁续签',
                                          onTap: isOwner
                                              ? () => setDialogState(() {
                                                  tlsCertificateType = 'ip';
                                                  tlsDetectionError = '';
                                                  unawaited(() async {
                                                    try {
                                                      final detected = await client
                                                          .detectServerPublicIp(
                                                            auth.token,
                                                            server.id,
                                                          );
                                                      if (detected.isNotEmpty &&
                                                          context.mounted &&
                                                          tlsCertificateType ==
                                                              'ip') {
                                                        setDialogState(() {
                                                          tlsIdentifierController
                                                                  .text =
                                                              detected;
                                                          tlsDetectionError =
                                                              '';
                                                        });
                                                      }
                                                    } catch (exception) {
                                                      if (context.mounted &&
                                                          tlsCertificateType ==
                                                              'ip') {
                                                        setDialogState(
                                                          () => tlsDetectionError =
                                                              '自动检测失败：$exception',
                                                        );
                                                      }
                                                    }
                                                  }());
                                                })
                                              : null,
                                        ),
                                        const SizedBox(height: 10),
                                        TextField(
                                          controller: tlsIdentifierController,
                                          enabled: isOwner,
                                          decoration: InputDecoration(
                                            labelText:
                                                tlsCertificateType == 'domain'
                                                ? '公网域名'
                                                : '固定公网 IP',
                                            hintText:
                                                tlsCertificateType == 'domain'
                                                ? 'voice.example.com'
                                                : '203.0.113.10',
                                          ),
                                        ),
                                        if (tlsDetectionError.isNotEmpty) ...[
                                          const SizedBox(height: 6),
                                          Text(
                                            tlsDetectionError,
                                            style: const TextStyle(
                                              color: OsColors.danger,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 8),
                                        Text(
                                          tlsStatusText,
                                          style: TextStyle(
                                            color: tlsStatusColor,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            height: 1.45,
                                          ),
                                        ),
                                      ],
                                    )
                                  : null,
                            ),
                            const SizedBox(height: 7),
                            MicrophoneActivationOption(
                              icon: Icons.enhanced_encryption_outlined,
                              selected: encryptionMode == 'e2ee',
                              title: '端到端加密',
                              subtitle: tlsActive
                                  ? '频道内容、临时私聊与语音媒体均由客户端加密'
                                  : '保存时将先启用并验证传输层加密',
                              onTap: isOwner
                                  ? () => setDialogState(
                                      () => encryptionMode = 'e2ee',
                                    )
                                  : null,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      OsFormCard(
                        icon: Icons.attach_file_rounded,
                        title: '附件承载',
                        child: Column(
                          children: [
                            MicrophoneActivationOption(
                              icon: Icons.dns_outlined,
                              selected: attachmentMode == 'local',
                              title: '本服务器承载',
                              subtitle: '聊天附件使用当前 OpenSpeak 服务器存储与带宽',
                              onTap: () => setDialogState(
                                () => attachmentMode = 'local',
                              ),
                            ),
                            const SizedBox(height: 7),
                            MicrophoneActivationOption(
                              icon: Icons.cloud_outlined,
                              selected: attachmentMode == 'external',
                              title: '其他服务器承载',
                              subtitle: '聊天附件交由外部附件节点传输与存储',
                              onTap: () => setDialogState(
                                () => attachmentMode = 'external',
                              ),
                              expanded: attachmentMode == 'external'
                                  ? Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        const Divider(height: 18),
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: TextField(
                                                controller:
                                                    fileNodeHostController,
                                                decoration:
                                                    const InputDecoration(
                                                      labelText: '外部服务器 IP 或域名',
                                                    ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            SizedBox(
                                              width: 128,
                                              child: TextField(
                                                controller:
                                                    fileNodePortController,
                                                keyboardType:
                                                    TextInputType.number,
                                                inputFormatters: [
                                                  FilteringTextInputFormatter
                                                      .digitsOnly,
                                                ],
                                                decoration:
                                                    const InputDecoration(
                                                      labelText: 'HTTPS 端口',
                                                      hintText: '27412',
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        TextField(
                                          controller: fileNodeSecretController,
                                          obscureText: true,
                                          decoration: InputDecoration(
                                            labelText:
                                                fileNodes
                                                        .where(
                                                          (node) =>
                                                              node.id ==
                                                              selectedFileNodeId,
                                                        )
                                                        .firstOrNull
                                                        ?.secretSet ==
                                                    true
                                                ? '节点密钥（留空保持不变）'
                                                : '节点密钥',
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        const _ActivationHint(
                                          text: '默认使用 27412；节点密钥位于外部服务器的部署凭据中。',
                                        ),
                                      ],
                                    )
                                  : null,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      OsFormCard(
                        icon: Icons.screen_share_outlined,
                        title: '屏幕共享方式',
                        child: Column(
                          children: [
                            MicrophoneActivationOption(
                              icon: Icons.dns_outlined,
                              selected: screenRelayMode == 'local',
                              title: '本服务器中转',
                              subtitle: '屏幕共享使用内置 LiveKit；语音始终保持在这里',
                              onTap: () => setDialogState(
                                () => screenRelayMode = 'local',
                              ),
                            ),
                            const SizedBox(height: 7),
                            MicrophoneActivationOption(
                              icon: Icons.cloud_outlined,
                              selected: screenRelayMode == 'external',
                              title: '外部 LiveKit 中转',
                              subtitle: '仅屏幕共享使用外部节点，不迁移语音',
                              onTap: () => setDialogState(
                                () => screenRelayMode = 'external',
                              ),
                              expanded: screenRelayMode == 'external'
                                  ? Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        const Divider(height: 18),
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: TextField(
                                                controller:
                                                    mediaNodeHostController,
                                                decoration:
                                                    const InputDecoration(
                                                      labelText:
                                                          'LiveKit 服务器 IP 或域名',
                                                    ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            SizedBox(
                                              width: 128,
                                              child: TextField(
                                                controller:
                                                    mediaNodePortController,
                                                keyboardType:
                                                    TextInputType.number,
                                                inputFormatters: [
                                                  FilteringTextInputFormatter
                                                      .digitsOnly,
                                                ],
                                                decoration:
                                                    const InputDecoration(
                                                      labelText: 'WSS 端口',
                                                      hintText: '27412',
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        TextField(
                                          controller: mediaNodeKeyController,
                                          decoration: const InputDecoration(
                                            labelText: 'LiveKit API Key',
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        TextField(
                                          controller: mediaNodeSecretController,
                                          obscureText: true,
                                          decoration: InputDecoration(
                                            labelText:
                                                mediaNodes
                                                        .where(
                                                          (node) =>
                                                              node.id ==
                                                              selectedMediaNodeId,
                                                        )
                                                        .firstOrNull
                                                        ?.apiSecretSet ==
                                                    true
                                                ? 'LiveKit API Secret（留空保持不变）'
                                                : 'LiveKit API Secret',
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        const _ActivationHint(
                                          text:
                                              '720p、1080p、Source 均提供 15、30、60 FPS；语音仍使用本服务器。',
                                        ),
                                      ],
                                    )
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                'owner' => OsSettingsPage(
                  icon: Icons.devices_rounded,
                  title: '设备与会话',
                  subtitle: ownerStatus?.isOwner == true
                      ? '管理已授权设备、会话与设备配对。'
                      : '将此设备添加为所有者设备。',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: ownerStatus?.isOwner == true
                        ? [
                            OsSettingsTile(
                              icon: Icons.devices_rounded,
                              title: '所有者设备与会话',
                              subtitle: '查看、下线或撤销已授权设备',
                              onTap: () => Navigator.pop(context, 'devices'),
                            ),
                            const SizedBox(height: 10),
                            OsSettingsTile(
                              icon: Icons.add_moderator_outlined,
                              title: '添加所有者设备',
                              subtitle: '生成 5 分钟有效的一次性配对码',
                              onTap: () =>
                                  Navigator.pop(context, 'pairing-code'),
                            ),
                          ]
                        : [
                            OsSettingsTile(
                              icon: Icons.key_rounded,
                              title: '输入设备配对码',
                              subtitle: '将这台电脑添加为服务器所有者设备',
                              onTap: () => Navigator.pop(context, 'pair'),
                            ),
                          ],
                  ),
                ),
                _ => OsSettingsPage(
                  icon: Icons.dashboard_outlined,
                  title: '服务器概览',
                  subtitle: '设置服务器头像与昵称。',
                  footer: canEditProfile
                      ? Align(
                          alignment: Alignment.centerRight,
                          child: OsPrimaryButton(
                            label: '保存更改',
                            icon: Icons.check_rounded,
                            onPressed: () =>
                                Navigator.pop(context, 'save-overview'),
                          ),
                        )
                      : null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OsProfilePreview(
                        displayName: serverNameController.text.trim().isEmpty
                            ? serverName
                            : serverNameController.text.trim(),
                        avatarFile: pendingServerAvatar ?? cachedServerAvatar,
                        avatarUri:
                            pendingServerAvatar == null &&
                                cachedServerAvatar == null &&
                                settingsServer.avatarVersion > 0
                            ? client.serverAvatarUri(
                                server.id,
                                settingsServer.avatarVersion,
                              )
                            : null,
                        onChooseAvatar: canEditProfile && !kIsWeb
                            ? () async {
                                final selected = await openFile(
                                  acceptedTypeGroups: const [
                                    XTypeGroup(
                                      label: '服务器头像',
                                      extensions: ['jpg', 'jpeg', 'png', 'gif'],
                                    ),
                                  ],
                                );
                                if (selected != null) {
                                  setDialogState(
                                    () => pendingServerAvatar = File(
                                      selected.path,
                                    ),
                                  );
                                }
                              }
                            : null,
                      ),
                      const SizedBox(height: 14),
                      const OsFieldLabel('服务器昵称'),
                      const SizedBox(height: 7),
                      TextField(
                        controller: serverNameController,
                        enabled: canEditProfile,
                        decoration: const InputDecoration(
                          hintText: '输入服务器昵称',
                          prefixIcon: Icon(Icons.badge_outlined, size: 20),
                        ),
                        onChanged: (_) => setDialogState(() {}),
                        onSubmitted: canEditProfile
                            ? (_) => Navigator.pop(context, 'save-overview')
                            : null,
                      ),
                    ],
                  ),
                ),
              },
            ),
          ),
        ),
      );
      switch (action) {
        case 'save-overview':
          await applyServerProfile(
            serverNameController.text,
            avatarFile: pendingServerAvatar,
          );
        case 'save-general':
          final retentionDays = int.tryParse(retentionController.text);
          if (retentionDays == null || defaultChannelId == null) {
            if (mounted) setState(() => error = '请填写有效的历史保留天数和默认频道');
            return;
          }
          await runGuarded(() async {
            final password = passwordController.text;
            final updated = await client.updateServerGeneralSettings(
              auth.token,
              server.id,
              historyRetentionDays: retentionDays,
              defaultChannelId: defaultChannelId!,
              serverPassword: !clearServerPassword && password.isNotEmpty
                  ? password
                  : null,
              clearServerPassword: clearServerPassword,
            );
            if (!mounted) return;
            setState(() {
              selectedServer = updated;
              servers = servers
                  .map((item) => item.id == updated.id ? updated : item)
                  .toList();
            });
          });
        case 'save-transport':
          await runGuarded(() async {
            int screenShareBitrate(String resolution, int fps) {
              final value = int.tryParse(
                screenShareBitrateControllers[(resolution, fps)]!.text,
              );
              if (value == null || value < 1 || value > 200) {
                throw OpenSpeakException('屏幕共享码率上限必须为 1–200 Mbps');
              }
              return value;
            }

            final screenShareBitrateLimits = ScreenShareBitrateLimits(
              p720Fps15: screenShareBitrate('720p', 15),
              p720Fps30: screenShareBitrate('720p', 30),
              p720Fps60: screenShareBitrate('720p', 60),
              p1080Fps15: screenShareBitrate('1080p', 15),
              p1080Fps30: screenShareBitrate('1080p', 30),
              p1080Fps60: screenShareBitrate('1080p', 60),
              sourceFps15: screenShareBitrate('source', 15),
              sourceFps30: screenShareBitrate('source', 30),
              sourceFps60: screenShareBitrate('source', 60),
            );
            FileNode? selectedFileNode;
            String? nextFileNodeUrl;
            String? nextMediaNodeUrl;
            if (attachmentMode == 'external') {
              selectedFileNode = fileNodes
                  .where((node) => node.id == selectedFileNodeId)
                  .firstOrNull;
              nextFileNodeUrl = externalFileNodeUrl(
                host: fileNodeHostController.text,
                port: fileNodePortController.text,
                path: fileNodePath,
              );
              if ((selectedFileNode == null || !selectedFileNode.secretSet) &&
                  fileNodeSecretController.text.isEmpty) {
                throw OpenSpeakException('首次配置外部附件节点需要填写节点密钥');
              }
            }
            if (screenRelayMode == 'external') {
              final existing = mediaNodes
                  .where((node) => node.id == selectedMediaNodeId)
                  .firstOrNull;
              nextMediaNodeUrl = externalLiveKitUrl(
                host: mediaNodeHostController.text,
                port: mediaNodePortController.text,
                path: mediaNodePath,
              );
              if (mediaNodeKeyController.text.trim().isEmpty) {
                throw OpenSpeakException('请填写 LiveKit API Key');
              }
              if (existing == null && mediaNodeSecretController.text.isEmpty) {
                throw OpenSpeakException('新建外部屏幕共享节点需要填写 API Secret');
              }
            }
            var transportClient = client;
            final identifier = tlsIdentifierController.text.trim();
            if (encryptionMode == 'none' &&
                settingsServer.tlsStatus == 'active') {
              if (!isOwner) {
                throw OpenSpeakException('只有服主可以关闭传输层加密');
              }
              final proof = await freshOwnerProof(client, auth, server);
              final pending = await client.beginEncryptionDowngrade(
                auth.token,
                server.id,
                challengeId: proof.challengeId,
                signature: proof.signature,
              );
              if (pending.confirmationToken.isEmpty ||
                  pending.plainUrl.isEmpty) {
                throw OpenSpeakException('服务器没有返回 HTTP 降级确认信息');
              }
              final plainClient = OpenSpeakApi(pending.plainUrl);
              final updated = await plainClient.confirmEncryptionDowngrade(
                pending.confirmationToken,
              );
              await persistSelectedConnectionUrl(pending.plainUrl);
              if (!mounted) return;
              setState(() {
                selectedServer = updated;
                servers = servers
                    .map((item) => item.id == updated.id ? updated : item)
                    .toList();
              });
              await login();
              return;
            }
            final needsTLSApply =
                encryptionMode != 'none' &&
                (settingsServer.tlsStatus != 'active' ||
                    settingsServer.tlsCertificateType != tlsCertificateType ||
                    settingsServer.tlsIdentifier != identifier);
            late OsServer updated;
            if (needsTLSApply) {
              if (!isOwner || identifier.isEmpty) {
                throw OpenSpeakException('请选择证书类型并填写域名或公网 IP');
              }
              final proof = await freshOwnerProof(client, auth, server);
              final pending = await client.enableServerTls(
                auth.token,
                server.id,
                certificateType: tlsCertificateType,
                identifier: identifier,
                challengeId: proof.challengeId,
                signature: proof.signature,
              );
              if (pending.confirmationToken.isEmpty ||
                  pending.secureUrl.isEmpty) {
                throw OpenSpeakException('服务器没有返回 TLS 确认信息');
              }
              final secureClient = OpenSpeakApi(pending.secureUrl);
              transportClient = secureClient;
              updated = await secureClient.confirmServerTls(
                auth.token,
                server.id,
                confirmationToken: pending.confirmationToken,
              );
              await persistSelectedConnectionUrl(pending.secureUrl);
              updated = await secureClient.updateServerVoiceTransport(
                auth.token,
                server.id,
                encryptionMode: encryptionMode,
                voiceAudioBitrateKbps: voiceAudioBitrateKbps,
                screenShareBitrateLimits: screenShareBitrateLimits,
              );
            } else {
              updated = await client.updateServerVoiceTransport(
                auth.token,
                server.id,
                encryptionMode: encryptionMode,
                voiceAudioBitrateKbps: voiceAudioBitrateKbps,
                screenShareBitrateLimits: screenShareBitrateLimits,
              );
            }
            await applyScreenRelaySettings(
              transportClient,
              auth,
              server,
              nodes: mediaNodes,
              external: screenRelayMode == 'external',
              selectedNodeId: selectedMediaNodeId,
              name: mediaNodeName,
              liveKitUrl: nextMediaNodeUrl ?? '',
              apiKey: mediaNodeKeyController.text.trim(),
              apiSecret: mediaNodeSecretController.text,
            );
            var attachmentFileNodeId = selectedFileNodeId;
            if (attachmentMode == 'external') {
              final node = selectedFileNode == null
                  ? await transportClient.createFileNode(
                      auth.token,
                      server.id,
                      name: '外部附件节点',
                      baseUrl: nextFileNodeUrl!,
                      secret: fileNodeSecretController.text,
                    )
                  : await transportClient.updateFileNode(
                      auth.token,
                      server.id,
                      selectedFileNode.id,
                      baseUrl: nextFileNodeUrl!,
                      secret: fileNodeSecretController.text.isEmpty
                          ? null
                          : fileNodeSecretController.text,
                      enabled: true,
                    );
              attachmentFileNodeId = node.id;
            }
            updated = await transportClient.setExternalAttachments(
              auth.token,
              server.id,
              enabled: attachmentMode == 'external',
              fileNodeId: attachmentFileNodeId,
            );
            if (!mounted) return;
            setState(() {
              selectedServer = updated;
              servers = servers
                  .map((item) => item.id == updated.id ? updated : item)
                  .toList();
            });
            if (needsTLSApply) await login();
          });
        case 'devices':
          if (await showOwnerDevices()) {
            await showServerSettings(initialPage: 'owner');
          }
        case 'pairing-code':
          if (await showOwnerPairingCode()) {
            await showServerSettings(initialPage: 'owner');
          }
        case 'pair':
          await showOwnerPairDialog();
        case 'save-permissions':
          await runGuarded(() async {
            await client.updateServerPermissions(
              auth.token,
              server.id,
              admin: adminPermissions,
              user: userPermissions,
              messageRetractWindowMinutes: retractWindowMinutes,
            );
            await refreshServerState();
          });
        case 'save-web':
          await runGuarded(() async {
            await client.updateWebSettings(
              auth.token,
              server.id,
              enabled: webEnabled,
              customPathEnabled: webCustomPathEnabled,
              path: webPathController.text.trim(),
            );
            if (mounted) {
              setState(() => error = null);
            }
          });
        case null:
          return;
      }
    } finally {
      serverNameController.dispose();
      retentionController.dispose();
      passwordController.dispose();
      tlsIdentifierController.dispose();
      mediaNodeHostController.dispose();
      mediaNodePortController.dispose();
      mediaNodeKeyController.dispose();
      mediaNodeSecretController.dispose();
      fileNodeHostController.dispose();
      fileNodePortController.dispose();
      fileNodeSecretController.dispose();
      for (final controller in screenShareBitrateControllers.values) {
        controller.dispose();
      }
      webPathController.dispose();
    }
  }

  Future<void> applyServerProfile(String name, {File? avatarFile}) async {
    final client = api;
    final auth = session;
    final server = selectedServer;
    final trimmed = name.trim();
    if (client == null || auth == null || server == null || trimmed.isEmpty) {
      return;
    }
    await runGuarded(() async {
      var updated = await client.updateServerProfile(
        auth.token,
        server.id,
        trimmed,
      );
      if (avatarFile != null) {
        updated = await client.uploadServerAvatar(
          auth.token,
          server.id,
          avatarFile,
        );
      }
      if (!mounted) return;
      setState(() {
        selectedServer = updated;
        servers = servers
            .map((item) => item.id == updated.id ? updated : item)
            .toList();
      });
      await updateSelectedConnectionServerMetadata(updated);
    });
  }

  Future<void> showMemberPermissions() async {
    if (serverMenuOpen) {
      setState(() => serverMenuOpen = false);
    }
    if (!canManageMembers) {
      if (mounted) setState(() => error = '当前账号没有成员管理权限');
      return;
    }
    final client = api;
    final auth = session;
    final server = selectedServer;
    if (client == null || auth == null || server == null) return;
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0xC7000000),
      builder: (context) => OsSettingsDialog(
        icon: Icons.manage_accounts_outlined,
        eyebrow: '',
        title: '成员与权限',
        subtitle: server.name,
        compactHeader: true,
        maxWidth: 920,
        child: OsMemberManagementPane(
          api: client,
          token: auth.token,
          serverId: server.id,
          currentUserId: auth.user.id,
          currentUserIsOwner: selectedServerOwnerStatus?.isOwner == true,
          permissions: currentServerPermissions,
        ),
      ),
    );
  }

  bool get canManageMembers {
    return hasServerPermission('member.view');
  }

  Future<void> toggleServerMenu(TapUpDetails details) async {
    if (serverMenuOpen) {
      setState(() => serverMenuOpen = false);
      return;
    }
    final client = api;
    final auth = session;
    final server = selectedServer;
    if (client == null || auth == null || server == null) return;
    try {
      final status = kIsWeb
          ? OwnerStatus(claimed: true, claimAvailable: false, isOwner: false)
          : await client.getOwnerStatus(auth.token, server.id);
      if (!mounted || selectedServer?.id != server.id) return;
      setState(() => selectedServerOwnerStatus = status);
      final items = serverMenuActions(
        claimed: status.claimed,
        isOwner: status.isOwner,
        permissions: currentServerPermissions,
        allowPairing: !kIsWeb,
      );
      if (items.isEmpty) return;
      final overlay =
          Overlay.of(context).context.findRenderObject() as RenderBox;
      final buttonLeft = details.globalPosition.dx - details.localPosition.dx;
      final buttonTop = details.globalPosition.dy - details.localPosition.dy;
      setState(() => serverMenuOpen = true);
      final action = await showMenu<ServerMenuAction>(
        context: context,
        position: RelativeRect.fromLTRB(
          buttonLeft + 36 - 227,
          buttonTop + 52,
          overlay.size.width - buttonLeft - 36,
          overlay.size.height - buttonTop - 52,
        ),
        color: OsColors.panel,
        surfaceTintColor: Colors.transparent,
        elevation: 18,
        constraints: const BoxConstraints(minWidth: 227, maxWidth: 227),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: OsColors.panelBorder),
        ),
        items: [
          for (final item in items)
            PopupMenuItem(
              value: item,
              height: 58,
              child: switch (item) {
                ServerMenuAction.settings => const OsPopupMenuRow(
                  icon: Icons.settings_outlined,
                  title: '服务器设置',
                  subtitle: '配置与所有者安全',
                ),
                ServerMenuAction.members => const OsPopupMenuRow(
                  icon: Icons.manage_accounts_outlined,
                  title: '成员与权限',
                  subtitle: '历史成员、角色与黑名单',
                ),
                ServerMenuAction.claim => const OsPopupMenuRow(
                  icon: Icons.verified_user_outlined,
                  title: '认领服务器',
                  subtitle: '绑定首台所有者设备',
                ),
                ServerMenuAction.pair => const OsPopupMenuRow(
                  icon: Icons.key_rounded,
                  title: '输入设备配对码',
                  subtitle: '将这台电脑添加为服务器所有者设备',
                ),
              },
            ),
        ],
      );
      if (!mounted) return;
      setState(() => serverMenuOpen = false);
      switch (action) {
        case ServerMenuAction.settings:
          await showServerSettings();
        case ServerMenuAction.members:
          await showMemberPermissions();
        case ServerMenuAction.claim:
          await claimServerFromMenu();
        case ServerMenuAction.pair:
          await showOwnerPairDialog();
        case null:
          return;
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          serverMenuOpen = false;
          this.error = error.toString();
        });
      }
    }
  }

  Future<void> claimServerFromMenu() async {
    if (serverMenuOpen) setState(() => serverMenuOpen = false);
    await showOwnerClaimDialog();
  }

  Future<String?> requestOwnerSecret({
    required String title,
    required String label,
    bool multiline = false,
  }) async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: OsColors.sidebar,
          title: Text(title),
          content: SizedBox(
            width: 460,
            child: TextField(
              controller: controller,
              autofocus: true,
              minLines: multiline ? 3 : 1,
              maxLines: multiline ? 5 : 1,
              decoration: InputDecoration(labelText: label),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('继续'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> showOwnerClaimDialog() async {
    final client = api;
    final auth = session;
    final server = selectedServer;
    if (client == null || auth == null || server == null) return;
    final claimKey = await requestOwnerSecret(
      title: '认领服务器所有权',
      label: '一次性 owner 认领密钥',
    );
    if (claimKey == null || claimKey.isEmpty) return;
    final deviceKey = await ownerIdentity.createDeviceKey();
    final result = await client.claimOwner(
      auth.token,
      server.id,
      claimKey: claimKey,
      device: ownerDeviceRegistration(deviceKey),
    );
    if (result.ownerDevice.id != deviceKey.deviceId) {
      throw OpenSpeakException('服务端返回了不一致的 owner 设备 ID');
    }
    await ownerIdentity.saveCredential(server.id, deviceKey);
    await login();
  }

  Future<void> showOwnerPairDialog() async {
    final client = api;
    final auth = session;
    final server = selectedServer;
    if (client == null || auth == null || server == null) return;
    final code = await requestOwnerSecret(
      title: '添加为 owner 设备',
      label: '5 分钟一次性配对码',
    );
    if (code == null || code.isEmpty) return;
    final deviceKey = await ownerIdentity.createDeviceKey();
    await ownerIdentity.saveCredential(server.id, deviceKey);
    final result = await client.pairOwnerDevice(
      auth.token,
      server.id,
      code: code,
      device: ownerDeviceRegistration(deviceKey),
    );
    if (result.ownerDevice.id != deviceKey.deviceId) {
      throw OpenSpeakException('服务端返回了不一致的 owner 设备 ID');
    }
    await login();
  }

  Future<bool> showOwnerPairingCode() async {
    final client = api;
    final auth = session;
    final server = selectedServer;
    if (client == null || auth == null || server == null) return false;
    final proof = await freshOwnerProof(client, auth, server);
    final pairing = await client.createOwnerPairingCode(
      auth.token,
      server.id,
      challengeId: proof.challengeId,
      signature: proof.signature,
    );
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierColor: const Color(0xC7000000),
          builder: (context) => OsSettingsDialog(
            icon: Icons.add_moderator_outlined,
            eyebrow: '服务器设置  /  设备与会话',
            title: '添加所有者设备',
            subtitle: '',
            compactHeader: true,
            maxWidth: 620,
            leadingActions: [
              OsSecondaryButton(
                label: '返回',
                icon: Icons.arrow_back_rounded,
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
            actions: [
              OsPrimaryButton(
                label: '完成',
                icon: Icons.check_rounded,
                onPressed: () => Navigator.pop(context, false),
              ),
            ],
            child: OsFormCard(
              icon: Icons.key_rounded,
              title: '5 分钟一次性配对码',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '在另一台电脑的服务器设置中选择“输入设备配对码”，用来获取 owner 权限。',
                    style: TextStyle(
                      color: OsColors.muted,
                      fontSize: 12,
                      height: 1.45,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 18,
                    ),
                    decoration: BoxDecoration(
                      color: OsColors.blurpleSoft,
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(color: const Color(0xFF444B72)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            pairing.code,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: OsColors.text,
                              fontSize: 23,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.8,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        TextButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: pairing.code),
                            );
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('配对码已复制')),
                            );
                          },
                          icon: const Icon(Icons.copy_rounded, size: 16),
                          label: const Text('复制'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 11),
                  const Row(
                    children: [
                      Icon(
                        Icons.schedule_rounded,
                        color: OsColors.dim,
                        size: 16,
                      ),
                      SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '该配对码仅可使用一次，并将在 5 分钟后失效。',
                          style: TextStyle(
                            color: OsColors.dim,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ) ??
        false;
  }

  Future<({String challengeId, String signature})> freshOwnerProof(
    OpenSpeakApi client,
    AuthSession auth,
    OsServer server,
  ) async {
    final credential = await ownerIdentity.loadCredential(server.id);
    if (credential == null) {
      throw OpenSpeakException('当前 owner 设备私钥不可用，请重新连接服务器');
    }
    final challenge = await client.createOwnerChallenge(
      auth.token,
      server.id,
      method: 'device',
      deviceId: credential.deviceId,
    );
    return (
      challengeId: challenge.id,
      signature: await ownerIdentity.sign(credential, challenge.challenge),
    );
  }

  Future<bool> showOwnerDevices() async {
    final client = api;
    final auth = session;
    final server = selectedServer;
    if (client == null || auth == null || server == null) return false;
    var devices = await client.listOwnerDevices(auth.token, server.id);
    final currentOwnerDeviceId = (await client.getOwnerStatus(
      auth.token,
      server.id,
    )).currentOwnerDeviceId;
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierColor: const Color(0xC7000000),
          builder: (context) => StatefulBuilder(
            builder: (context, setDialogState) => OsSettingsDialog(
              icon: Icons.devices_rounded,
              eyebrow: '服务器设置  /  设备与会话',
              title: '所有者设备与会话',
              subtitle: '',
              compactHeader: true,
              maxWidth: 760,
              leadingActions: [
                OsSecondaryButton(
                  label: '返回',
                  icon: Icons.arrow_back_rounded,
                  onPressed: () => Navigator.pop(context, true),
                ),
              ],
              actions: [
                OsSecondaryButton(
                  label: '关闭',
                  onPressed: () => Navigator.pop(context, false),
                ),
              ],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '查看、下线或撤销已授权的所有者设备。',
                    style: TextStyle(
                      color: OsColors.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SmoothListView(
                      children: [
                        for (final ownerDevice in devices) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: OsColors.panelRaised,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: OsColors.panelBorder),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: ownerDevice.online
                                        ? const Color(0x263BA55C)
                                        : const Color(0xFF31343A),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    ownerDevice.online
                                        ? Icons.computer_rounded
                                        : Icons.computer_outlined,
                                    color: ownerDevice.online
                                        ? OsColors.green
                                        : OsColors.icon,
                                    size: 21,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        ownerDevice.label.isEmpty
                                            ? ownerDevice.platform
                                            : ownerDevice.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: OsColors.text,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        ownerDevice.fingerprint,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: OsColors.dim,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${ownerDevice.online ? "当前在线" : "当前离线"} · ${ownerDevice.authorizationMethod}',
                                        style: const TextStyle(
                                          color: OsColors.muted,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                if (ownerDevice.revoked)
                                  const _OsStatusBadge(
                                    label: '已撤销',
                                    color: OsColors.dim,
                                  )
                                else if (ownerDevice.id == currentOwnerDeviceId)
                                  const _OsStatusBadge(
                                    label: '当前设备',
                                    color: OsColors.green,
                                  )
                                else
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TextButton(
                                        onPressed: () async {
                                          final proof = await freshOwnerProof(
                                            client,
                                            auth,
                                            server,
                                          );
                                          await client.kickOwnerDevice(
                                            auth.token,
                                            server.id,
                                            ownerDevice.id,
                                            challengeId: proof.challengeId,
                                            signature: proof.signature,
                                          );
                                          devices = await client
                                              .listOwnerDevices(
                                                auth.token,
                                                server.id,
                                              );
                                          setDialogState(() {});
                                        },
                                        child: const Text('下线'),
                                      ),
                                      TextButton(
                                        style: TextButton.styleFrom(
                                          foregroundColor: OsColors.danger,
                                        ),
                                        onPressed: () async {
                                          final confirmed = await showDialog<bool>(
                                            context: context,
                                            builder: (confirmContext) =>
                                                AlertDialog(
                                                  backgroundColor:
                                                      OsColors.sidebar,
                                                  title: const Text(
                                                    '撤销 owner 设备',
                                                  ),
                                                  content: Text(
                                                    '确定撤销“${ownerDevice.label}”吗？'
                                                    '该设备的公钥和所有会话会立即失效。',
                                                  ),
                                                  actions: [
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            confirmContext,
                                                            false,
                                                          ),
                                                      child: const Text('取消'),
                                                    ),
                                                    FilledButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            confirmContext,
                                                            true,
                                                          ),
                                                      child: const Text('撤销'),
                                                    ),
                                                  ],
                                                ),
                                          );
                                          if (confirmed != true) return;
                                          final proof = await freshOwnerProof(
                                            client,
                                            auth,
                                            server,
                                          );
                                          await client.revokeOwnerDevice(
                                            auth.token,
                                            server.id,
                                            ownerDevice.id,
                                            challengeId: proof.challengeId,
                                            signature: proof.signature,
                                          );
                                          devices = await client
                                              .listOwnerDevices(
                                                auth.token,
                                                server.id,
                                              );
                                          setDialogState(() {});
                                        },
                                        child: const Text('撤销'),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 9),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ) ??
        false;
  }

  Future<void> setAudioDevices(
    String? inputDeviceId,
    String? outputDeviceId, {
    bool restartInput = false,
    bool inputAvailable = true,
  }) {
    setState(() {
      selectedAudioInputDeviceId = inputDeviceId;
      selectedAudioOutputDeviceId = outputDeviceId;
    });
    return runGuarded(() async {
      await persistAudioDevicePreferences();
      await voiceSession.configureAudioDevices(
        inputDeviceId: inputDeviceId,
        outputDeviceId: outputDeviceId,
        restartInput: restartInput,
        inputAvailable: inputAvailable,
      );
    });
  }

  Future<void> setAudioSettings(
    String? inputDeviceId,
    String? outputDeviceId, {
    required MicrophoneActivationMode activationMode,
    required double threshold,
    required MicrophoneHotkeyBinding? pushToTalkHotkeyBinding,
    required double effectVolume,
  }) {
    final effectiveActivationMode = microphoneActivationModeForPlatform(
      activationMode,
    );
    setState(() {
      selectedAudioInputDeviceId = inputDeviceId;
      selectedAudioOutputDeviceId = outputDeviceId;
      microphoneActivationMode = effectiveActivationMode;
      microphoneThreshold = threshold.clamp(0.0, 1.0).toDouble();
      microphonePushToTalkHotkey = pushToTalkHotkeyBinding;
      soundEffectVolume = effectVolume.clamp(0.0, 1.0).toDouble();
      soundEffects.volume = soundEffectVolume;
    });
    return runGuarded(() async {
      await persistAudioDevicePreferences();
      await audioPreferences.saveAudioSettings(
        activationMode: effectiveActivationMode,
        microphoneThreshold: microphoneThreshold,
        pushToTalkHotkey: pushToTalkHotkeyBinding,
        soundEffectVolume: soundEffectVolume,
      );
      await voiceSession.configureAudioDevices(
        inputDeviceId: inputDeviceId,
        outputDeviceId: outputDeviceId,
      );
      await voiceSession.configureMicrophoneActivation(
        mode: effectiveActivationMode,
        threshold: microphoneThreshold,
      );
      final hotkeyReady = await _applyPushToTalkHotkeyRegistration();
      if (!hotkeyReady &&
          effectiveActivationMode == MicrophoneActivationMode.pushToTalk &&
          pushToTalkHotkeyBinding != null) {
        throw OpenSpeakException(pushToTalkHotkey.error ?? '无法注册系统级按键通话快捷键');
      }
    });
  }

  Future<void> applyScreenRelaySettings(
    OpenSpeakApi client,
    AuthSession auth,
    OsServer server, {
    required List<MediaNode> nodes,
    required bool external,
    required String? selectedNodeId,
    required String name,
    required String liveKitUrl,
    required String apiKey,
    required String apiSecret,
  }) async {
    if (!external) {
      for (final node in nodes.where((node) => node.enabled)) {
        await client.updateMediaNode(
          auth.token,
          server.id,
          node.id,
          enabled: false,
          draining: false,
        );
      }
      return;
    }
    if (name.isEmpty || liveKitUrl.isEmpty || apiKey.isEmpty) {
      throw OpenSpeakException('请填写 LiveKit 服务器地址和 API Key');
    }
    final existing = nodes
        .where((node) => node.id == selectedNodeId)
        .firstOrNull;
    if (existing == null && apiSecret.isEmpty) {
      throw OpenSpeakException('新建外部屏幕共享节点需要填写 API Secret');
    }
    final selected = existing == null
        ? await client.createMediaNode(
            auth.token,
            server.id,
            name: name,
            liveKitUrl: liveKitUrl,
            apiKey: apiKey,
            apiSecret: apiSecret,
          )
        : await client.updateMediaNode(
            auth.token,
            server.id,
            existing.id,
            name: name,
            liveKitUrl: liveKitUrl,
            apiKey: apiKey,
            apiSecret: apiSecret.isEmpty ? null : apiSecret,
            enabled: true,
            draining: false,
          );
    for (final node in nodes.where(
      (node) => node.id != selected.id && node.enabled,
    )) {
      await client.updateMediaNode(
        auth.token,
        server.id,
        node.id,
        enabled: false,
        draining: false,
      );
    }
  }

  Future<void> switchServerToNone() async {
    final client = api;
    final auth = session;
    final server = selectedServer;
    if (client == null || auth == null || server == null) return;
    await runGuarded(() async {
      final updated = await client.setServerEncryptionMode(
        auth.token,
        server.id,
        'none',
      );
      setState(() {
        selectedServer = updated;
        servers = servers
            .map((item) => item.id == updated.id ? updated : item)
            .toList();
      });
    });
  }

  String suggestedLiveKitUrl() {
    final base = api?.baseUri;
    if (base == null || base.host.isEmpty) return 'ws://SERVER_IP:27420';
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return '$scheme://${base.host}:27420';
  }

  bool isLoopbackLiveKitUrl(String value) {
    final uri = Uri.tryParse(value);
    final host = uri?.host.toLowerCase() ?? '';
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }

  Future<void> fixLoopbackLiveKitUrl() async {
    final client = api;
    final auth = session;
    final server = selectedServer;
    final token = voiceSession.snapshot.voiceToken;
    if (client == null || auth == null || server == null || token == null) {
      return;
    }
    await runGuarded(() async {
      final nodes = await client.listMediaNodes(auth.token, server.id);
      MediaNode? target;
      for (final node in nodes) {
        if (node.id == token.mediaNodeId) {
          target = node;
          break;
        }
      }
      target ??= nodes
          .where((node) => node.enabled && !node.draining)
          .firstOrNull;
      if (target == null) {
        throw OpenSpeakException('没有可更新的 media node');
      }
      await client.updateMediaNodeLiveKitUrl(
        auth.token,
        server.id,
        target.id,
        suggestedLiveKitUrl(),
      );
      final channel = channels
          .where((item) => item.id == token.channelId)
          .firstOrNull;
      if (channel == null) throw OpenSpeakException('语音频道已不存在');
      final encryption = await prepareVoiceEncryption(channel);
      final refreshedToken = await client.getVoiceToken(
        auth.token,
        token.channelId,
        deviceId: encryption.deviceId,
        e2eeEpochId: encryption.epochId,
      );
      await voiceSession.setExternalVoiceToken(refreshedToken);
    });
  }

  Future<void> fetchVoiceToken() async {
    final client = api;
    final auth = session;
    final channel = selectedChannel;
    if (client == null || auth == null || channel == null) return;
    await runGuarded(() async {
      final encryption = await prepareVoiceEncryption(channel);
      final token = await client.getVoiceToken(
        auth.token,
        channel.id,
        deviceId: encryption.deviceId,
        e2eeEpochId: encryption.epochId,
      );
      await voiceSession.setExternalVoiceToken(token);
    });
  }

  Future<ScreenShareQuality?> showScreenShareQualityDialog() async {
    final permissions = currentServerRole == 'owner'
        ? {
            voiceScreenSharePermission,
            ...screenShareResolutionPermissions.values,
            ...screenShareFPSPermissions.values,
          }
        : currentServerPermissions;
    final qualities = allowedScreenShareQualities(permissions);
    if (qualities.isEmpty) return null;
    final preferred = qualities
        .where((quality) => quality.resolution == '1080p' && quality.fps == 30)
        .firstOrNull;
    var resolution = (preferred ?? qualities.first).resolution;
    var fps = (preferred ?? qualities.first).fps;
    final resolutionOptions =
        const [
              ('720p', '720p', '适合普通网络和较小窗口'),
              ('1080p', '1080p', '文字清晰度与带宽的平衡档'),
              ('source', 'Source', '尽量保留屏幕原始分辨率'),
            ]
            .where(
              (option) =>
                  qualities.any((quality) => quality.resolution == option.$1),
            )
            .toList();
    final fpsOptions =
        const [
              (15, '15 FPS', '适合文档、代码和静态内容'),
              (30, '30 FPS', '适合日常操作和多数演示'),
              (60, '60 FPS', '适合高动态内容，需要更多带宽'),
            ]
            .where(
              (option) => qualities.any((quality) => quality.fps == option.$1),
            )
            .toList();
    return showDialog<ScreenShareQuality>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.72),
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => OsSettingsDialog(
          icon: Icons.screen_share_rounded,
          eyebrow: '屏幕共享',
          title: '选择画质',
          subtitle: '第一版使用 LiveKit 中继，分辨率和帧率由分享者决定。',
          maxWidth: 620,
          leadingActions: [
            OsSecondaryButton(
              label: '取消',
              onPressed: () => Navigator.pop(dialogContext),
            ),
          ],
          actions: [
            OsPrimaryButton(
              label: '选择分享窗口',
              icon: Icons.arrow_forward_rounded,
              onPressed: () => Navigator.pop(
                dialogContext,
                screenShareQualities.firstWhere(
                  (quality) =>
                      quality.resolution == resolution && quality.fps == fps,
                ),
              ),
            ),
          ],
          child: SmoothSingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: OsFormCard(
                    icon: Icons.aspect_ratio_rounded,
                    title: '分辨率',
                    child: Column(
                      children: [
                        for (final option in resolutionOptions) ...[
                          MicrophoneActivationOption(
                            selected: resolution == option.$1,
                            title: option.$2,
                            subtitle: option.$3,
                            onTap: () =>
                                setDialogState(() => resolution = option.$1),
                          ),
                          if (option != resolutionOptions.last)
                            const SizedBox(height: 7),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OsFormCard(
                    icon: Icons.speed_rounded,
                    title: '帧率',
                    child: Column(
                      children: [
                        for (final option in fpsOptions) ...[
                          MicrophoneActivationOption(
                            selected: fps == option.$1,
                            title: option.$2,
                            subtitle: option.$3,
                            onTap: () => setDialogState(() => fps = option.$1),
                          ),
                          if (option != fpsOptions.last)
                            const SizedBox(height: 7),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> toggleScreenShare() async {
    if (screenShareActionInFlight) return;
    if (!voiceSession.isScreenSharing &&
        kIsWeb &&
        !browserSupportsScreenShare()) {
      setState(() => error = unsupportedBrowserScreenShareMessage);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text(unsupportedBrowserScreenShareMessage)),
      );
      return;
    }
    setState(() => screenShareActionInFlight = true);
    try {
      if (voiceSession.isScreenSharing) {
        await runGuarded(voiceSession.stopScreenShare);
        return;
      }
      if (!voiceSession.snapshot.connected) {
        setState(() => error = '请先进入语音频道');
        return;
      }
      if (voiceSession.snapshot.voiceToken?.canShareScreen != true ||
          !hasServerPermission('voice.screen_share')) {
        setState(() => error = '没有屏幕共享权限');
        return;
      }
      if (voiceSession.screenSharingUserId != null) {
        setState(() => error = '当前频道有人正在分享屏幕');
        return;
      }
      final quality = await showScreenShareQualityDialog();
      if (!mounted || quality == null) return;
      rtc.DesktopCapturerSource? source;
      if (!kIsWeb) {
        source = await showDialog<rtc.DesktopCapturerSource>(
          context: context,
          barrierColor: Colors.black.withValues(alpha: 0.72),
          barrierDismissible: false,
          builder: (_) => const _ScreenShareSourceDialog(),
        );
        if (!mounted || source == null) return;
      }
      await runGuarded(() async {
        try {
          await voiceSession.startScreenShare(
            sourceId: source?.id ?? '',
            quality: quality,
          );
        } catch (exception, stackTrace) {
          if (exception is OpenSpeakException) rethrow;
          ClientLog.error('voice.screen.start', exception, stackTrace);
          throw OpenSpeakException('屏幕共享失败');
        }
      });
    } finally {
      if (mounted) setState(() => screenShareActionInFlight = false);
    }
  }

  Future<void> runGuarded(Future<void> Function() action) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb && session == null) {
      return Scaffold(
        backgroundColor: OsColors.rail,
        body: Center(
          child: loading
              ? const CircularProgressIndicator()
              : error == null
              ? const SizedBox.shrink()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Text(error!, textAlign: TextAlign.center),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => unawaited(login()),
                      child: const Text('重新连接'),
                    ),
                  ],
                ),
        ),
      );
    }
    if (useMobileWebLayout(
      isWeb: kIsWeb,
      width: MediaQuery.sizeOf(context).width,
    )) {
      return Scaffold(body: buildMobileShell());
    }
    return Scaffold(body: buildShell());
  }

  Widget buildShell() {
    return Row(
      children: [
        if (!kIsWeb) buildServerRail(),
        buildChannelPane(),
        Expanded(child: buildMainPane()),
      ],
    );
  }

  Map<String, VoiceState> displayVoiceStatesByUserId() {
    final participantUserIds = voiceSession.snapshot.liveKitParticipantUserIds;
    final speakingUserIds = voiceSession.snapshot.liveKitSpeakingUserIds;
    return {
      for (final state in presence.voiceStates)
        state.userId: VoiceState(
          serverId: state.serverId,
          userId: state.userId,
          displayName: state.displayName,
          channelId: state.channelId,
          muted: state.muted,
          deafened: state.deafened,
          speaking: channelMemberIsSpeaking(
            state.userId,
            participantUserIds,
            speakingUserIds,
            localUserId: session?.user.id,
            reportedSpeaking: state.speaking,
          ),
          screenSharing: state.screenSharing,
          screenShareResolution: state.screenShareResolution,
          screenShareFPS: state.screenShareFPS,
          screenShareMediaNodeId: state.screenShareMediaNodeId,
        ),
    };
  }

  Widget buildMobileShell() {
    final body = mobileChatOpen
        ? buildMainPane(onBack: () => setState(() => mobileChatOpen = false))
        : mobileTabIndex == 0
        ? buildMobileChannelList()
        : buildMobileDirectList();
    return PopScope(
      canPop: !mobileChatOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && mobileChatOpen) {
          setState(() => mobileChatOpen = false);
        }
      },
      child: SafeArea(
        child: ColoredBox(
          color: OsColors.content,
          child: Column(
            children: [
              Expanded(child: RepaintBoundary(child: body)),
              if (!mobileChatOpen) ...[
                RepaintBoundary(child: buildMobileVoiceStatusBar()),
                RepaintBoundary(child: buildMobileNavigationBar()),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget buildMobileServerHeader() {
    final server = selectedServer;
    if (server == null) return const SizedBox.shrink();
    return Container(
      height: 58,
      padding: const EdgeInsets.only(left: 14, right: 8),
      decoration: const BoxDecoration(
        color: OsColors.sidebar,
        border: Border(bottom: BorderSide(color: OsColors.divider)),
      ),
      child: Row(
        children: [
          OsUserAvatar(
            displayName: server.name,
            size: 34,
            avatarUri: server.avatarVersion > 0
                ? api?.serverAvatarUri(
                    server.id,
                    server.avatarVersion,
                    small: true,
                  )
                : null,
            backgroundColor: OsColors.blurple,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              server.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: OsColors.text,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> openMobileChannel(Channel channel, {bool join = false}) async {
    await loadChannel(channel, join: join);
    if (!mounted ||
        selectedChannel?.id != channel.id ||
        chatScope != ChatScope.channel) {
      return;
    }
    setState(() {
      mobileChatOpen = true;
      clearChannelUnread(channel.id);
    });
  }

  Widget buildMobileChannelList() {
    final voiceStatesByUserId = displayVoiceStatesByUserId();
    final currentVoiceChannelId = currentVoiceChannel()?.id;
    return ColoredBox(
      color: OsColors.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          buildMobileServerHeader(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              '频道',
              style: TextStyle(
                color: OsColors.text,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          Expanded(
            child: channels.isEmpty
                ? const ChatEmptyState(title: '还没有频道', subtitle: '当前没有可用频道')
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                    itemCount: channels.length,
                    itemBuilder: (context, index) {
                      final channel = channels[index];
                      return MobileChannelCard(
                        channel: channel,
                        selected: currentVoiceChannelId == channel.id,
                        unreadCount:
                            unreadState.channelUnreadCounts[channel.id] ?? 0,
                        mentionCount:
                            unreadState.channelMentionCounts[channel.id] ?? 0,
                        members: presence.users
                            .where(
                              (user) =>
                                  user.online &&
                                  user.currentChannelId == channel.id,
                            )
                            .toList(),
                        voiceStatesByUserId: voiceStatesByUserId,
                        api: api,
                        avatarToken: session?.token,
                        onOpen: () => unawaited(openMobileChannel(channel)),
                        onDoubleTap: () =>
                            unawaited(loadChannel(channel, join: true)),
                        onLongPressStart:
                            hasServerPermission('channel.edit') ||
                                hasServerPermission('channel.delete')
                            ? (details) => unawaited(
                                showChannelContextMenu(
                                  details.globalPosition,
                                  channel: channel,
                                ),
                              )
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void openMobileDirectChat(PresenceUser user) {
    startDirectChat(user);
    setState(() {
      mobileTabIndex = 1;
      mobileChatOpen = true;
    });
  }

  Widget buildMobileDirectList() {
    final voiceStatesByUserId = displayVoiceStatesByUserId();
    final users = presence.users
        .where((user) => user.online && user.userId != session?.user.id)
        .toList();
    return ColoredBox(
      color: OsColors.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          buildMobileServerHeader(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              '私聊',
              style: TextStyle(
                color: OsColors.text,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          Expanded(
            child: users.isEmpty
                ? const ChatEmptyState(
                    title: '暂无在线用户',
                    subtitle: '其他用户上线后会显示在这里',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                    itemCount: users.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final user = users[index];
                      return MobileDirectUserTile(
                        user: user,
                        voiceState: voiceStatesByUserId[user.userId],
                        channelName: channelForId(
                          channels,
                          user.currentChannelId,
                          fallbackToFirst: false,
                        )?.name,
                        unreadCount:
                            unreadState.directUnreadCounts[user.userId] ?? 0,
                        avatarUri: chatAvatarUriForUser(user.userId),
                        avatarToken: session?.token,
                        onTap: () => openMobileDirectChat(user),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Channel? currentVoiceChannel() => channelForId(
    channels,
    voiceSession.currentChannelId ?? myVoiceState?.channelId,
    fallbackToFirst: false,
  );

  String? channelMessageNotificationChannelId() {
    String? availableChannelId(String? channelId) =>
        channelId != null && channels.any((channel) => channel.id == channelId)
        ? channelId
        : null;

    final currentUserId = session?.user.id;
    for (final user in presence.users) {
      if (user.userId == currentUserId) {
        final channelId = availableChannelId(user.currentChannelId);
        if (channelId != null) return channelId;
      }
    }
    final voiceChannelId = availableChannelId(
      myVoiceState?.channelId ?? voiceSession.currentChannelId,
    );
    if (voiceChannelId != null) return voiceChannelId;
    return selectedChannel?.id;
  }

  bool channelChatVisibleNow(String channelId) => channelChatIsVisible(
    chatScope: chatScope,
    selectedChannelId: selectedChannel?.id,
    channelId: channelId,
    mobileWeb: useMobileWebLayout(
      isWeb: kIsWeb,
      width: MediaQuery.sizeOf(context).width,
    ),
    mobileChatOpen: mobileChatOpen,
  );

  Widget buildMobileVoiceStatusBar() {
    final snapshot = voiceSession.snapshot;
    final voiceChannel = currentVoiceChannel();
    final connected = snapshot.connected && voiceChannel != null;
    final canSpeak =
        hasServerPermission('voice.speak') &&
        !audioDeviceKindUnavailable(audioDeviceMonitor, 'audioinput') &&
        !voiceSession.microphoneUnavailable;
    return Material(
      color: OsColors.sidebarBottom,
      child: InkWell(
        onTap: () => unawaited(showMobileVoiceSheet()),
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: OsColors.divider)),
          ),
          child: Row(
            children: [
              IgnorePointer(
                child: NetworkQualityButton(
                  latencyMs: snapshot.latencyMs,
                  latencyJitterMs: snapshot.latencyJitterMs,
                  upstreamPacketLoss: snapshot.upstreamPacketLoss,
                  downstreamPacketLoss: snapshot.downstreamPacketLoss,
                  selected: false,
                  onPressed: () {},
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  connected ? '已连接到 #${voiceChannel.name}' : '未加入语音频道',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: connected ? OsColors.text : OsColors.dim,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              StatusBarIconButton(
                tooltip: snapshot.muted ? '取消静音' : '静音',
                icon: snapshot.muted ? Icons.mic_off : Icons.mic,
                active: canSpeak && !snapshot.muted,
                onPressed: canSpeak
                    ? () => unawaited(setMuted(!snapshot.muted))
                    : null,
              ),
              const SizedBox(width: 28),
              StatusBarIconButton(
                tooltip: snapshot.listenOff ? '开启收听' : '关闭收听',
                icon: snapshot.listenOff ? Icons.volume_off : Icons.volume_up,
                active: !snapshot.listenOff,
                onPressed: () => unawaited(setListenOff(!snapshot.listenOff)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget mobileNavigationIcon(IconData icon, int count) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon),
        if (count > 0)
          Positioned(
            right: -12,
            top: -7,
            child: UnreadBadge(count: count, compact: true),
          ),
      ],
    );
  }

  Widget buildMobileNavigationBar() {
    final channelUnread = channels.fold<int>(
      0,
      (sum, channel) =>
          sum +
          math.max(
            unreadState.channelUnreadCounts[channel.id] ?? 0,
            unreadState.channelMentionCounts[channel.id] ?? 0,
          ),
    );
    final directUnread = unreadState.directUnreadCounts.values.fold<int>(
      0,
      (sum, value) => sum + value,
    );
    return BottomNavigationBar(
      currentIndex: mobileVoiceSheetOpen ? 2 : mobileTabIndex,
      type: BottomNavigationBarType.fixed,
      backgroundColor: OsColors.sidebarBottom,
      selectedItemColor: OsColors.blurple,
      unselectedItemColor: OsColors.dim,
      selectedFontSize: 12,
      unselectedFontSize: 12,
      selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w800),
      items: [
        BottomNavigationBarItem(
          icon: mobileNavigationIcon(Icons.tag, channelUnread),
          label: '频道',
        ),
        BottomNavigationBarItem(
          icon: mobileNavigationIcon(Icons.forum_outlined, directUnread),
          label: '私聊',
        ),
        const BottomNavigationBarItem(icon: Icon(Icons.settings), label: '设置'),
      ],
      onTap: (index) {
        if (index == 2) {
          unawaited(showMobileVoiceSheet());
          return;
        }
        setState(() {
          mobileTabIndex = index;
          mobileChatOpen = false;
        });
      },
    );
  }

  Future<void> showMobileVoiceSheet() async {
    if (mobileVoiceSheetOpen) return;
    setState(() => mobileVoiceSheetOpen = true);
    var showNetworkDetails = false;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        barrierColor: const Color(0x99000000),
        builder: (sheetContext) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.46,
          maxChildSize: 0.94,
          expand: false,
          builder: (context, scrollController) => StatefulBuilder(
            builder: (context, setSheetState) => AnimatedBuilder(
              animation: voiceSession,
              builder: (context, _) => buildMobileVoiceSheet(
                sheetContext: sheetContext,
                scrollController: scrollController,
                showNetworkDetails: showNetworkDetails,
                onShowNetworkDetails: () =>
                    setSheetState(() => showNetworkDetails = true),
                onHideNetworkDetails: () =>
                    setSheetState(() => showNetworkDetails = false),
                refresh: () => setSheetState(() {}),
              ),
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => mobileVoiceSheetOpen = false);
    }
  }

  Widget buildMobileVoiceSheet({
    required BuildContext sheetContext,
    required ScrollController scrollController,
    required bool showNetworkDetails,
    required VoidCallback onShowNetworkDetails,
    required VoidCallback onHideNetworkDetails,
    required VoidCallback refresh,
  }) {
    final snapshot = voiceSession.snapshot;
    final voiceChannel = currentVoiceChannel();
    final voiceStatesByUserId = displayVoiceStatesByUserId();
    final currentVoiceState = voiceStatesByUserId[session?.user.id];
    final microphoneUnavailable =
        audioDeviceKindUnavailable(audioDeviceMonitor, 'audioinput') ||
        voiceSession.microphoneUnavailable;
    final canSpeak =
        hasServerPermission('voice.speak') && !microphoneUnavailable;
    final canShareScreen =
        (!kIsWeb || browserSupportsScreenShare()) &&
        hasServerPermission('voice.screen_share') &&
        snapshot.connected &&
        snapshot.voiceToken?.canShareScreen == true;
    final quality = networkQualityForStats(
      latencyMs: snapshot.latencyMs,
      latencyJitterMs: snapshot.latencyJitterMs,
      upstreamPacketLoss: snapshot.upstreamPacketLoss,
      downstreamPacketLoss: snapshot.downstreamPacketLoss,
    );
    final networkLabel = switch (quality.bars) {
      3 => '网络良好',
      2 => '网络一般',
      1 => '网络较差',
      _ => '正在检测网络',
    };
    final voiceStatus = !snapshot.connected
        ? '未加入语音'
        : snapshot.muted
        ? '已静音'
        : currentVoiceState?.speaking == true
        ? '正在说话'
        : '已连接';

    void refreshAfter(Future<void> action) {
      unawaited(
        action.whenComplete(() {
          if (sheetContext.mounted) refresh();
        }),
      );
    }

    return Material(
      color: OsColors.panel,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          Center(
            child: Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: OsColors.icon,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (showNetworkDetails) ...[
            Row(
              children: [
                IconButton(
                  tooltip: '返回',
                  onPressed: onHideNetworkDetails,
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 19),
                ),
                const SizedBox(width: 4),
                const Text(
                  '连接信息',
                  style: TextStyle(
                    color: OsColors.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Center(
              child: NetworkStatsCard(
                upstreamPacketLoss: snapshot.upstreamPacketLoss,
                downstreamPacketLoss: snapshot.downstreamPacketLoss,
                latencyMs: snapshot.latencyMs,
                latencyJitterMs: snapshot.latencyJitterMs,
              ),
            ),
          ] else ...[
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: OsColors.panelRaised,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: OsColors.panelBorder),
              ),
              child: Row(
                children: [
                  const Icon(Icons.tag, color: OsColors.dim, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      voiceChannel == null ? '未加入频道' : voiceChannel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: OsColors.text,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  NetworkQualityButton(
                    latencyMs: snapshot.latencyMs,
                    latencyJitterMs: snapshot.latencyJitterMs,
                    upstreamPacketLoss: snapshot.upstreamPacketLoss,
                    downstreamPacketLoss: snapshot.downstreamPacketLoss,
                    selected: false,
                    onPressed: onShowNetworkDetails,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: OsColors.panelRaised,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: OsColors.panelBorder),
              ),
              child: Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      OsUserAvatar(
                        displayName: localDisplayName,
                        size: 48,
                        avatarFile: localAvatarFile,
                        avatarRevision: localAvatarRevision,
                        avatarUri: session == null
                            ? null
                            : chatAvatarUriForUser(session!.user.id),
                        avatarToken: session?.token,
                        backgroundColor: const Color(0xFFA55CD2),
                      ),
                      Positioned(
                        right: -3,
                        bottom: -3,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: snapshot.muted
                                ? OsColors.danger
                                : OsColors.green,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: OsColors.panelRaised,
                              width: 2,
                            ),
                          ),
                          child: Icon(
                            snapshot.muted ? Icons.mic_off : Icons.mic,
                            size: 11,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          localDisplayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: OsColors.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                voiceStatus,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: OsColors.muted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: quality.color,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                networkLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: OsColors.dim,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OsSecondaryButton(
                    key: const ValueKey('mobile-edit-nickname'),
                    label: '修改昵称',
                    onPressed: () =>
                        unawaited(showClientSettings(onlyPage: 'profile')),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.16,
              children: [
                MobileVoiceActionCard(
                  label: '麦克风',
                  icon: snapshot.muted ? Icons.mic_off : Icons.mic,
                  active: canSpeak && !snapshot.muted,
                  enabled: canSpeak,
                  onTap: () => refreshAfter(setMuted(!snapshot.muted)),
                ),
                MobileVoiceActionCard(
                  label: '扬声器',
                  icon: snapshot.listenOff ? Icons.volume_off : Icons.volume_up,
                  active: !snapshot.listenOff,
                  onTap: () => refreshAfter(setListenOff(!snapshot.listenOff)),
                ),
                MobileVoiceActionCard(
                  label: '屏幕共享',
                  icon: voiceSession.isScreenSharing
                      ? Icons.stop_screen_share_rounded
                      : Icons.screen_share_rounded,
                  active: voiceSession.isScreenSharing,
                  enabled:
                      !screenShareActionInFlight &&
                      (voiceSession.isScreenSharing || canShareScreen),
                  onTap: () => refreshAfter(toggleScreenShare()),
                ),
                MobileVoiceActionCard(
                  label: '音频设备',
                  icon: Icons.headphones_rounded,
                  onTap: () => unawaited(showClientSettings(onlyPage: 'audio')),
                ),
                MobileVoiceActionCard(
                  label: '连接信息',
                  icon: Icons.signal_cellular_alt,
                  onTap: onShowNetworkDetails,
                ),
              ],
            ),
            if (kIsWeb && !browserSupportsScreenShare()) ...[
              const SizedBox(height: 10),
              const Text(
                unsupportedBrowserScreenShareMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: OsColors.dim,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget buildServerRail() {
    return Container(
      width: 72,
      color: OsColors.rail,
      child: Column(
        children: [
          Expanded(
            child: SmoothListView(
              padding: const EdgeInsets.only(top: 14),
              children: [
                for (final connection in savedConnections)
                  ServerBubble(
                    label: initials(connection.name),
                    caption: connection.name,
                    imageUri: savedServerAvatarUri(connection),
                    selected: isCurrentSavedConnection(connection),
                    badgeCount: isCurrentSavedConnection(connection)
                        ? unreadState.totalUnreadCount
                        : 0,
                    onTap: isCurrentSavedConnection(connection)
                        ? null
                        : () => unawaited(connectSavedConnection(connection)),
                    onSecondaryTapDown: kIsWeb
                        ? null
                        : (details) => unawaited(
                            showSavedServerContextMenu(connection, details),
                          ),
                  ),
                if (!kIsWeb || savedConnections.isEmpty)
                  ServerBubble(
                    label: '+',
                    selected: false,
                    tooltip: kIsWeb ? '连接服务器' : '添加服务器',
                    color: OsColors.sidebar,
                    foregroundColor: OsColors.green,
                    onTap: () => unawaited(showAddServerDialog()),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (session != null)
            ServerBubble(
              label: 'OFF',
              selected: false,
              tooltip: '断开连接',
              color: OsColors.disconnect,
              hoverColor: OsColors.danger,
              onTap: () => unawaited(disconnectCurrentServer()),
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget buildChannelPane() {
    final voiceStatesByUserId = displayVoiceStatesByUserId();
    final microphoneUnavailable =
        audioDeviceKindUnavailable(audioDeviceMonitor, 'audioinput') ||
        voiceSession.microphoneUnavailable;
    final speakerUnavailable = audioDeviceKindUnavailable(
      audioDeviceMonitor,
      'audiooutput',
    );
    return Container(
      width: 240,
      color: OsColors.sidebar,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (selectedServer != null)
                ServerHeader(
                  serverName: selectedServer!.name,
                  menuOpen: serverMenuOpen,
                  onMenuPressed: (details) =>
                      unawaited(toggleServerMenu(details)),
                ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onSecondaryTapUp: hasServerPermission('channel.create')
                      ? (details) => unawaited(
                          showChannelContextMenu(details.globalPosition),
                        )
                      : null,
                  child: SmoothWheelScroll(
                    controller: channelScrollController,
                    child: ReorderableListView.builder(
                      scrollController: channelScrollController,
                      physics: smoothWheelChildPhysics,
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 132),
                      buildDefaultDragHandles: false,
                      onReorderItem: (oldIndex, newIndex) =>
                          unawaited(reorderChannelList(oldIndex, newIndex)),
                      itemCount: channels.length,
                      itemBuilder: (context, index) {
                        final channel = channels[index];
                        return ChannelTile(
                          key: ValueKey(channel.id),
                          channel: channel,
                          selected: selectedChannel?.id == channel.id,
                          unreadCount:
                              unreadState.channelUnreadCounts[channel.id] ?? 0,
                          mentionCount:
                              unreadState.channelMentionCounts[channel.id] ?? 0,
                          members: presence.users
                              .where(
                                (user) => user.currentChannelId == channel.id,
                              )
                              .toList(),
                          directUnreadCounts: unreadState.directUnreadCounts,
                          voiceStatesByUserId: voiceStatesByUserId,
                          currentUserId: session?.user.id,
                          currentUserMicrophoneUnavailable:
                              microphoneUnavailable,
                          currentUserSpeakerUnavailable: speakerUnavailable,
                          reorderIndex:
                              hasServerPermission('channel.reorder') &&
                                  !channelReorderSaving
                              ? index
                              : null,
                          api: api,
                          avatarToken: session?.token,
                          onTap: () => loadChannel(channel),
                          onDoubleTap: () => loadChannel(channel, join: true),
                          onSecondaryTapDown: (details) => unawaited(
                            showChannelContextMenu(
                              details.globalPosition,
                              channel: channel,
                            ),
                          ),
                          onMemberTap: startDirectChat,
                          onMemberSecondaryTapDown: (user, details) =>
                              unawaited(
                                showMemberRoleContextMenu(user, details),
                              ),
                          canMoveMembers: hasServerPermission('member.move'),
                          onMemberDropped: (user) =>
                              unawaited(moveMemberToChannel(user, channel)),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 132,
            child: CurrentUserBar(
              connected: session != null && selectedServer != null,
              displayName: localDisplayName,
              avatarFile: localAvatarFile,
              avatarRevision: localAvatarRevision,
              avatarUri: kIsWeb && session != null
                  ? chatAvatarUriForUser(session!.user.id)
                  : null,
              avatarToken: kIsWeb ? session?.token : null,
              online: realtimeConnection.connected,
              muted: voiceSession.snapshot.muted,
              canSpeak:
                  hasServerPermission('voice.speak') &&
                  (!kIsWeb || !microphoneUnavailable),
              canShareScreen:
                  (!kIsWeb || browserSupportsScreenShare()) &&
                  hasServerPermission('voice.screen_share') &&
                  voiceSession.snapshot.connected &&
                  voiceSession.snapshot.voiceToken?.canShareScreen == true,
              screenShareUnavailableReason:
                  kIsWeb && !browserSupportsScreenShare()
                  ? unsupportedBrowserScreenShareMessage
                  : null,
              screenSharing: voiceSession.isScreenSharing,
              screenShareBusy: screenShareActionInFlight,
              listenOff: voiceSession.snapshot.listenOff,
              noiseSuppressionEnabled: noiseSuppressionEnabled,
              inputVolume: audioInputVolume,
              outputVolume: audioOutputVolume,
              upstreamPacketLoss: voiceSession.snapshot.upstreamPacketLoss,
              downstreamPacketLoss: voiceSession.snapshot.downstreamPacketLoss,
              latencyMs: voiceSession.snapshot.latencyMs,
              latencyJitterMs: voiceSession.snapshot.latencyJitterMs,
              onMute: () => unawaited(setMuted(!voiceSession.snapshot.muted)),
              onListenOff: () =>
                  unawaited(setListenOff(!voiceSession.snapshot.listenOff)),
              onNoiseSuppressionToggle: () =>
                  unawaited(toggleNoiseSuppression()),
              onInputVolumeChanged: (value) =>
                  unawaited(setAudioInputVolume(value)),
              onOutputVolumeChanged: (value) =>
                  unawaited(setAudioOutputVolume(value)),
              onScreenShare: () => unawaited(toggleScreenShare()),
              onSettings: () => unawaited(showClientSettings()),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildMainPane({VoidCallback? onBack}) {
    final channel = selectedChannel;
    final directPeer = selectedDirectUser();
    final directPeerName = directPeer == null
        ? '未选择用户'
        : displayNameForUser(directPeer.userId);
    final directEnabled = chatScope == ChatScope.direct && directPeer != null;
    final channelEnabled = chatScope == ChatScope.channel && channel != null;
    final canSendText = chatScope == ChatScope.channel
        ? hasServerPermission('channel.messages.send_text')
        : hasServerPermission('direct.send_text');
    final canSendAttachment = chatScope == ChatScope.channel
        ? hasServerPermission('channel.messages.send_image') ||
              hasServerPermission('channel.messages.send_file')
        : hasServerPermission('direct.send_image') ||
              hasServerPermission('direct.send_file');
    final screenShare = voiceSession.activeScreenShare;
    if (!channelEnabled && !directEnabled) {
      return Container(
        color: OsColors.content,
        alignment: Alignment.topCenter,
        child: error == null ? null : ErrorBox(message: error!),
      );
    }
    final chatPane = DropTarget(
      onDragEntered: (_) => setState(() => attachmentDragActive = true),
      onDragExited: (_) => setState(() => attachmentDragActive = false),
      onDragDone: (details) {
        setState(() => attachmentDragActive = false);
        unawaited(handleDroppedFiles(details.files));
      },
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          Positioned.fill(child: buildChatBody(directEnabled: directEnabled)),
          if (currentChatNewMessages > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: NewMessagesPill(
                count: currentChatNewMessages,
                onTap: () => unawaited(openCurrentChatLatestMessages()),
              ),
            ),
          if (attachmentDragActive)
            const Positioned.fill(child: DropUploadOverlay()),
        ],
      ),
    );
    return Container(
      color: OsColors.content,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: OsColors.divider)),
            ),
            child: Row(
              children: [
                if (onBack != null) ...[
                  IconButton(
                    tooltip: '返回',
                    onPressed: onBack,
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: OsColors.muted,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 2),
                ],
                if (chatScope == ChatScope.direct && directPeer != null)
                  ChannelMemberSpeakingAvatar(
                    displayName: directPeerName,
                    online: directPeer.online,
                    voiceState: null,
                    avatarUri: chatAvatarUriForUser(directPeer.userId),
                    avatarToken: session?.token,
                  )
                else
                  const Icon(Icons.tag, color: OsColors.icon, size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    chatScope == ChatScope.direct
                        ? directPeerName
                        : channel?.name ?? '频道',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (error != null)
            ErrorBox(
              message: error!,
              actionLabel:
                  !kIsWeb &&
                      pushToTalkHotkey.accessibilityPermissionRequired &&
                      Platform.isMacOS
                  ? '打开系统设置'
                  : null,
              onAction:
                  !kIsWeb &&
                      pushToTalkHotkey.accessibilityPermissionRequired &&
                      Platform.isMacOS
                  ? () =>
                        unawaited(pushToTalkHotkey.openAccessibilitySettings())
                  : null,
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (screenShare == null) return chatPane;
                final stageHeight = constraints.maxHeight * 3 / 5;
                final stageWidth =
                    screenShareStagePanelWidth(
                      maxWidth: constraints.maxWidth,
                      maxHeight: stageHeight,
                      aspectRatio: screenShare.aspectRatio,
                    ) +
                    _screenShareStageHorizontalInset * 2;
                final collapsed = screenShareCollapsed || screenShareWindowOpen;
                final stage = ScreenShareStage(
                  share: screenShare,
                  collapsed: collapsed,
                  onToggleCollapsed: () => setState(
                    () => screenShareCollapsed = !screenShareCollapsed,
                  ),
                  onMaximize: () => unawaited(showScreenShareWindow()),
                );
                return screenShareOverlay(
                  chat: chatPane,
                  stage: stage,
                  stageWidth: stageWidth,
                  stageHeight: collapsed ? null : stageHeight,
                );
              },
            ),
          ),
          if (attachmentTransfers.uploads.isNotEmpty)
            UploadQueuePanel(
              tasks: attachmentTransfers.uploads,
              onCancel: cancelUpload,
              onRetry: (task) => unawaited(retryUpload(task)),
            ),
          ChatComposer(
            controller: messageController,
            enabled: (channelEnabled || directEnabled) && canSendText,
            readOnly: loading,
            addEnabled:
                (channelEnabled || directEnabled) &&
                !loading &&
                canSendAttachment,
            hintText: chatScope == ChatScope.direct && directPeer != null
                ? '正在与 $directPeerName 私聊'
                : null,
            disabledHintText: chatScope == ChatScope.direct
                ? '未选择私聊对象'
                : '未进入频道',
            onAdd: () => unawaited(pickAndUploadAttachment()),
            onSend: () => unawaited(
              chatScope == ChatScope.channel
                  ? sendChannelMessage()
                  : sendDirectMessage(),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildChatBody({required bool directEnabled}) {
    final cacheExtent = messageListCacheExtent(
      isWeb: kIsWeb,
      width: MediaQuery.sizeOf(context).width,
    );
    final channel = selectedChannel;
    if (chatScope == ChatScope.direct) {
      final peer = selectedDirectUser();
      if (!directEnabled || peer == null) {
        return const ChatEmptyState(title: '未选择私聊对象', subtitle: '点击频道成员开始私聊');
      }
      final messages = selectedDirectMessages();
      if (messages.isEmpty) {
        return ChatEmptyState(
          title: '还没有私聊消息',
          subtitle: '正在与 ${displayNameForUser(peer.userId)} 私聊',
        );
      }
      return SmoothWheelScroll(
        controller: messageScrollController,
        reverse: true,
        child: ListView.builder(
          controller: messageScrollController,
          reverse: true,
          physics: smoothWheelChildPhysics,
          // ignore: deprecated_member_use
          cacheExtent: cacheExtent,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final messageIndex = messages.length - 1 - index;
            final message = messages[messageIndex];
            final attachment = attachmentFromDirectMessage(message);
            final mine = message.fromUserId == session?.user.id;
            final senderName = displayNameForUser(message.fromUserId);
            final contextAction = message.kind == 'removed'
                ? null
                : directMessageContextAction(
                    mine: mine,
                    pending: attachmentTransfers.pendingLocalUploads.contains(
                      message.id,
                    ),
                  );
            return ChatMessageEntry(
              key: ValueKey('direct-${message.id}'),
              sentAt: message.sentAt,
              previousSentAt: messageIndex > 0
                  ? messages[messageIndex - 1].sentAt
                  : null,
              child: message.kind == 'removed'
                  ? ChatMessageRemovalNotice(text: '$senderName 撤回了一条消息')
                  : ChatMessageRow(
                      body: message.body,
                      attachment: attachment,
                      sentAt: message.sentAt,
                      senderName: senderName,
                      mine: mine,
                      avatarFile: mine ? localAvatarFile : null,
                      avatarRevision: mine ? localAvatarRevision : 0,
                      avatarUri: chatAvatarUriForUser(message.fromUserId),
                      avatarToken: session?.token,
                      ensureCached: ensureAttachmentCached,
                      loadImagePreview: loadImagePreview,
                      loadAudioMetadata: loadAudioMetadata,
                      linkPreviewFallback: attachment == null
                          ? fallbackLinkPreviewForBody(message.body)
                          : null,
                      linkPreviewFuture: attachment == null
                          ? loadLinkPreviewForBody(message.body)
                          : null,
                      onOpen: openAttachment,
                      onSaveAs: saveAttachmentAs,
                      onOpenLink: openExternalUrl,
                      downloadTask:
                          attachmentTransfers.downloads[attachment?.fileId],
                      onCancelDownload: cancelDownload,
                      activeAudioFileId: audioPlayback.activeFileId,
                      audioLoadingFileId: audioPlayback.loadingFileId,
                      audioPlaying: audioPlayback.playing,
                      audioPosition: audioPlayback.position,
                      audioDuration: audioPlayback.duration,
                      onToggleAudio: toggleAudioAttachment,
                      onSeekAudio: audioPlayback.seek,
                      messageActionLabel: contextAction == null ? null : '撤回消息',
                      onMessageAction: contextAction == null
                          ? null
                          : () => retractDirectMessage(message),
                      onMessageContextMenu: contextAction == null
                          ? null
                          : (position) => unawaited(
                              showDirectMessageContextMenu(message, position),
                            ),
                    ),
            );
          },
        ),
      );
    }
    if (channel == null) {
      return const ChatEmptyState(title: '未选择频道', subtitle: '连接服务器后会进入默认频道');
    }
    if (!hasServerPermission('channel.messages.view')) {
      return const ChatEmptyState(
        title: '无法查看频道消息',
        subtitle: '当前账号没有查看频道消息的权限',
      );
    }
    final messages = channelMessageStore.messages;
    if (channelMessageStore.loading && messages.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (messages.isEmpty) {
      return const ChatEmptyState(title: '还没有消息', subtitle: '发送第一条频道消息');
    }
    return SmoothWheelScroll(
      controller: messageScrollController,
      reverse: true,
      child: ListView.builder(
        controller: messageScrollController,
        reverse: true,
        physics: smoothWheelChildPhysics,
        // ignore: deprecated_member_use
        cacheExtent: cacheExtent,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        itemCount: messages.length,
        itemBuilder: (context, index) {
          final messageIndex = messages.length - 1 - index;
          final message = messages[messageIndex];
          final attachment = attachmentFromChannelMessage(message);
          final mine = message.senderUserId == session?.user.id;
          final senderName = channelMessageSenderName(
            message: message,
            currentUserId: session?.user.id,
            currentDisplayName: localDisplayName,
            liveDisplayName: liveDisplayNameForUser(message.senderUserId),
            fallbackDisplayName: displayNameForUser(message.senderUserId),
          );
          final contextAction = message.kind == 'removed'
              ? null
              : channelMessageContextAction(
                  mine: mine,
                  canManageOthers: hasServerPermission(
                    'channel.messages.manage',
                  ),
                  pending: attachmentTransfers.pendingLocalUploads.contains(
                    message.id,
                  ),
                  canRetractOwn: canRetractChannelMessage(message),
                );
          return ChatMessageEntry(
            key: ValueKey('channel-${message.id}'),
            sentAt: message.createdAt,
            previousSentAt: messageIndex > 0
                ? messages[messageIndex - 1].createdAt
                : null,
            child: message.kind == 'removed'
                ? ChatMessageRemovalNotice(
                    text: message.metadata['removal_kind'] == 'deleted'
                        ? '一条消息已被管理员删除'
                        : '$senderName 撤回了一条消息',
                  )
                : ChatMessageRow(
                    body: channelMessageBody(message),
                    attachment: attachment,
                    attachmentDownloadsEnabled: hasServerPermission(
                      'channel.attachments.download',
                    ),
                    sentAt: message.createdAt,
                    senderName: senderName,
                    mine: mine,
                    avatarFile: mine ? localAvatarFile : null,
                    avatarRevision: mine ? localAvatarRevision : 0,
                    avatarUri: chatAvatarUriForUser(
                      message.senderUserId,
                      messageAvatarVersion: message.senderAvatarVersion,
                    ),
                    avatarToken: session?.token,
                    ensureCached: ensureAttachmentCached,
                    loadImagePreview: loadImagePreview,
                    loadAudioMetadata: loadAudioMetadata,
                    linkPreviewFallback: attachment == null
                        ? fallbackLinkPreviewForBody(message.body)
                        : null,
                    linkPreviewFuture: attachment == null
                        ? loadLinkPreviewForBody(message.body)
                        : null,
                    onOpen: openAttachment,
                    onSaveAs: saveAttachmentAs,
                    onOpenLink: openExternalUrl,
                    downloadTask:
                        attachmentTransfers.downloads[attachment?.fileId],
                    onCancelDownload: cancelDownload,
                    activeAudioFileId: audioPlayback.activeFileId,
                    audioLoadingFileId: audioPlayback.loadingFileId,
                    audioPlaying: audioPlayback.playing,
                    audioPosition: audioPlayback.position,
                    audioDuration: audioPlayback.duration,
                    onToggleAudio: toggleAudioAttachment,
                    onSeekAudio: audioPlayback.seek,
                    messageActionLabel: switch (contextAction) {
                      ChannelMessageContextAction.retract => '撤回消息',
                      ChannelMessageContextAction.delete => '删除消息',
                      null => null,
                    },
                    onMessageAction: contextAction == null
                        ? null
                        : () => unawaited(
                            deleteChannelMessage(message, contextAction),
                          ),
                    onMessageContextMenu: contextAction == null
                        ? null
                        : (position) => unawaited(
                            showChannelMessageContextMenu(message, position),
                          ),
                  ),
          );
        },
      ),
    );
  }

  String channelMessageBody(ChannelMessage message) {
    switch (message.kind) {
      case 'image':
        return message.body;
      case 'file':
        return '[文件] ${message.metadata['original_name'] ?? message.body}';
      default:
        return message.body;
    }
  }

  ChatAttachment? attachmentFromChannelMessage(ChannelMessage message) {
    if (message.kind != 'image' && message.kind != 'file') return null;
    final fileId = message.metadata['file_id'];
    if (fileId == null || fileId.isEmpty) return null;
    return ChatAttachment(
      direct: false,
      channelId: message.channelId,
      kind: message.kind,
      fileId: fileId,
      originalName: message.metadata['original_name'] ?? message.body,
      contentType: message.metadata['content_type'] ?? '',
      sizeBytes: int.tryParse(message.metadata['size_bytes'] ?? '') ?? 0,
      ciphertextSizeBytes:
          int.tryParse(message.metadata['ciphertext_size_bytes'] ?? '') ?? 0,
      encryptionMode: message.encryptionMode,
      epochId: message.epochId,
      nonce: message.nonce,
      attachmentFormat: message.metadata['attachment_format'] ?? '',
      expiresAt: null,
      expired: false,
    );
  }

  ChatAttachment? attachmentFromDirectMessage(DirectMessage message) {
    if (message.kind != 'image' && message.kind != 'file') return null;
    if (message.fileId.isEmpty) return null;
    return ChatAttachment(
      direct: true,
      channelId: message.encryptionMode == 'e2ee'
          ? directEncryptionScope(
              selectedServer?.id ?? '',
              message.fromUserId,
              message.toUserId,
            )
          : '',
      kind: message.kind,
      fileId: message.fileId,
      originalName: message.originalName,
      contentType: message.contentType,
      sizeBytes: message.sizeBytes,
      ciphertextSizeBytes: message.ciphertextSizeBytes,
      encryptionMode: message.encryptionMode,
      epochId: message.id,
      nonce: message.nonce,
      attachmentFormat: message.attachmentFormat,
      expiresAt: message.expiresAt,
      expired: directMessageStore.isFileExpired(message.fileId),
    );
  }

  void startDirectChat(PresenceUser user) {
    if (user.userId == session?.user.id) {
      return;
    }
    setState(() {
      selectedDirectUserId = user.userId;
      chatScope = ChatScope.direct;
      clearDirectUnread(user.userId);
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => scrollMessagesToEnd(animated: false, settle: true),
    );
  }

  Future<void> showMemberRoleContextMenu(
    PresenceUser user,
    TapDownDetails details,
  ) async {
    final client = api;
    final auth = session;
    final server = selectedServer;
    if (client == null || auth == null || server == null) return;
    if (user.userId == auth.user.id) return;
    var canChangeRole = selectedServerOwnerStatus?.isOwner == true;
    if (!canChangeRole && user.role != 'owner') {
      try {
        final status = await client.getOwnerStatus(auth.token, server.id);
        if (!mounted || selectedServer?.id != server.id) return;
        selectedServerOwnerStatus = status;
        canChangeRole = status.isOwner;
      } catch (_) {
        // Local volume control must remain available if owner-status lookup
        // is unavailable. The server still authorizes every role change.
      }
    }
    if (!mounted) return;
    final actions = memberContextActions(
      currentUser: false,
      canChangeRole: canChangeRole,
      targetRole: user.role,
      inVoice: voiceStateForUser(presence, user.userId) != null,
      permissions: currentServerPermissions,
    );
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(details.globalPosition.dx, details.globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );
    final items = <PopupMenuEntry<MemberContextAction>>[];
    for (final action in actions) {
      items.add(
        PopupMenuItem(
          value: action,
          height: 58,
          child: switch (action) {
            MemberContextAction.adjustVolume => OsPopupMenuRow(
              icon: Icons.volume_up_outlined,
              title: '调整音量',
              subtitle: '${(memberOutputVolume(user.userId) * 100).round()}%',
            ),
            MemberContextAction.makeUser => const OsPopupMenuRow(
              icon: Icons.person_outline_rounded,
              title: '设为普通用户',
              subtitle: '移除管理员身份与权限',
            ),
            MemberContextAction.makeAdmin => const OsPopupMenuRow(
              icon: Icons.admin_panel_settings_outlined,
              title: '设为管理员',
              subtitle: '授予管理员身份与权限',
            ),
            MemberContextAction.kick => const OsPopupMenuRow(
              icon: Icons.logout_rounded,
              title: '踢出用户',
              subtitle: '断开当前连接，不加入黑名单',
              danger: true,
            ),
            MemberContextAction.ban => const OsPopupMenuRow(
              icon: Icons.block_rounded,
              title: '封禁用户',
              subtitle: '加入黑名单并断开连接',
              danger: true,
            ),
            MemberContextAction.forceMute => const OsPopupMenuRow(
              icon: Icons.mic_off_rounded,
              title: '强制用户静音',
              subtitle: '用户之后可以自行解除',
            ),
            MemberContextAction.forceDeafen => const OsPopupMenuRow(
              icon: Icons.headset_off_rounded,
              title: '强制用户停止收听',
              subtitle: '用户之后可以自行解除',
            ),
          },
        ),
      );
    }
    final action = await showMenu<MemberContextAction>(
      context: context,
      position: position,
      color: OsColors.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      constraints: const BoxConstraints(minWidth: 224),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: OsColors.panelBorder),
      ),
      items: items,
    );
    if (action == null || !mounted) return;
    if (action == MemberContextAction.adjustVolume) {
      await showMemberVolumePopup(user, position);
      return;
    }
    if ((action == MemberContextAction.kick ||
            action == MemberContextAction.ban) &&
        !await confirmMemberModeration(
          user,
          ban: action == MemberContextAction.ban,
        )) {
      return;
    }
    await runGuarded(() async {
      switch (action) {
        case MemberContextAction.makeAdmin:
        case MemberContextAction.makeUser:
          await client.updateServerMemberRole(
            auth.token,
            server.id,
            user.userId,
            action == MemberContextAction.makeAdmin ? 'admin' : 'user',
          );
        case MemberContextAction.kick:
          await client.kickServerMember(auth.token, server.id, user.userId);
        case MemberContextAction.ban:
          await client.banServerMember(
            auth.token,
            server.id,
            user.userId,
            reason: '',
            durationSeconds: 0,
          );
        case MemberContextAction.forceMute:
          await client.forceMuteServerMember(
            auth.token,
            server.id,
            user.userId,
          );
        case MemberContextAction.forceDeafen:
          await client.forceDeafenServerMember(
            auth.token,
            server.id,
            user.userId,
          );
        case MemberContextAction.adjustVolume:
          return;
      }
      await refreshServerState();
    });
  }

  Future<void> moveMemberToChannel(PresenceUser user, Channel channel) async {
    final client = api;
    final auth = session;
    if (client == null ||
        auth == null ||
        user.userId == auth.user.id ||
        user.currentChannelId == channel.id ||
        !hasServerPermission('member.move')) {
      return;
    }
    await runGuarded(() async {
      await client.joinChannel(auth.token, channel.id, userId: user.userId);
      await refreshServerState();
    });
  }

  Future<bool> confirmMemberModeration(
    PresenceUser user, {
    required bool ban,
  }) async {
    return await showDialog<bool>(
          context: context,
          barrierColor: const Color(0xC7000000),
          builder: (context) => OsSettingsDialog(
            icon: ban ? Icons.block_rounded : Icons.logout_rounded,
            eyebrow: '成员管理',
            title: ban
                ? '封禁 ${displayNameForUser(user.userId)}'
                : '踢出 ${displayNameForUser(user.userId)}',
            subtitle: ban ? '该用户会被永久加入黑名单并断开连接。' : '只断开该用户的当前连接，不会加入黑名单。',
            maxWidth: 480,
            resizable: false,
            actions: [
              OsSecondaryButton(
                label: '取消',
                onPressed: () => Navigator.pop(context, false),
              ),
              OsPrimaryButton(
                label: ban ? '确认封禁' : '确认踢出',
                icon: ban ? Icons.block_rounded : Icons.logout_rounded,
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
            child: Text(
              ban ? '之后需要拥有“解除封禁”权限的管理员或 owner 才能移出黑名单。' : '用户之后可以重新连接服务器。',
              style: const TextStyle(color: OsColors.muted, height: 1.5),
            ),
          ),
        ) ??
        false;
  }

  Future<void> showMemberVolumePopup(
    PresenceUser user,
    RelativeRect position,
  ) async {
    await showMenu<int>(
      context: context,
      position: position,
      color: OsColors.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      constraints: const BoxConstraints(minWidth: 286, maxWidth: 286),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: OsColors.panelBorder),
      ),
      items: [
        MemberVolumePopupEntry(
          displayName: displayNameForUser(user.userId),
          initialVolume: memberOutputVolume(user.userId),
          onChanged: (value) => previewMemberOutputVolume(user.userId, value),
          onChangeEnd: (_) => unawaited(persistMemberOutputVolumes()),
        ),
      ],
    );
    await persistMemberOutputVolumes();
  }

  PresenceUser? selectedDirectUser() {
    final selectedId = selectedDirectUserId;
    if (selectedId != null) {
      for (final user in presence.users) {
        if (user.userId == selectedId) return user;
      }
    }
    return defaultDirectUser();
  }

  PresenceUser? defaultDirectUser() {
    final currentUserId = session?.user.id;
    for (final user in presence.users) {
      if (user.userId != currentUserId) return user;
    }
    return presence.users.isEmpty ? null : presence.users.first;
  }

  String displayNameForUser(String userId) {
    final auth = session;
    if (auth?.user.id == userId) {
      final localName = localDisplayName.trim();
      if (localName.isNotEmpty) return localName;
      final displayName = auth!.user.displayName.trim();
      if (displayName.isNotEmpty) return displayName;
    }
    for (final user in presence.users) {
      if (user.userId == userId && user.displayName.trim().isNotEmpty) {
        return user.displayName.trim();
      }
    }
    return userId;
  }

  String? liveDisplayNameForUser(String userId) {
    for (final user in presence.users) {
      final displayName = user.displayName.trim();
      if (user.userId == userId && user.online && displayName.isNotEmpty) {
        return displayName;
      }
    }
    return null;
  }

  Uri? chatAvatarUriForUser(String userId, {int messageAvatarVersion = 0}) {
    final client = api;
    if (client == null) return null;
    final auth = session;
    if (auth?.user.id == userId) {
      return auth!.user.avatarVersion > 0
          ? client.userAvatarUri(userId, auth.user.avatarVersion, small: true)
          : null;
    }
    if (messageAvatarVersion > 0) {
      return client.userAvatarUri(userId, messageAvatarVersion, small: true);
    }
    for (final user in presence.users) {
      if (user.userId == userId && user.avatarVersion > 0) {
        return client.userAvatarUri(userId, user.avatarVersion, small: true);
      }
    }
    return null;
  }

  String channelName(String channelId) {
    for (final channel in channels) {
      if (channel.id == channelId) return channel.name;
    }
    return channelId;
  }

  VoiceState? voiceStateForUser(PresenceSnapshot snapshot, String userId) {
    for (final state in snapshot.voiceStates) {
      if (state.userId == userId) return state;
    }
    return null;
  }
}

Set<String> voiceChannelMemberUserIds(
  PresenceSnapshot snapshot,
  String channelId, {
  String? includeUserId,
}) => {
  for (final state in snapshot.voiceStates)
    if (state.channelId == channelId) state.userId,
  if (includeUserId != null && includeUserId.isNotEmpty) includeUserId,
};

bool channelMemberIsSpeaking(
  String userId,
  Set<String> currentRoomParticipantUserIds,
  Set<String> currentRoomSpeakingUserIds, {
  String? localUserId,
  bool reportedSpeaking = false,
}) =>
    currentRoomParticipantUserIds.contains(userId) &&
    (currentRoomSpeakingUserIds.contains(userId) ||
        (userId != localUserId && reportedSpeaking));

List<Channel> channelsAfterMove(
  List<Channel> channels,
  int oldIndex,
  int newIndex,
) {
  final reordered = [...channels];
  reordered.insert(newIndex, reordered.removeAt(oldIndex));
  return [
    for (var index = 0; index < reordered.length; index += 1)
      Channel(
        id: reordered[index].id,
        name: reordered[index].name,
        sortOrder: index,
      ),
  ];
}

String channelMessageSenderName({
  required ChannelMessage message,
  required String? currentUserId,
  required String currentDisplayName,
  required String? liveDisplayName,
  required String fallbackDisplayName,
}) {
  final currentName = currentDisplayName.trim();
  if (message.senderUserId == currentUserId && currentName.isNotEmpty) {
    return currentName;
  }
  final liveName = liveDisplayName?.trim() ?? '';
  if (liveName.isNotEmpty) return liveName;
  final storedName = message.senderDisplayName.trim();
  return storedName.isNotEmpty ? storedName : fallbackDisplayName;
}

String initials(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return 'OS';
  final chars = trimmed.runes.take(2).toList();
  return String.fromCharCodes(chars).toUpperCase();
}

const sectionStyle = TextStyle(
  color: OsColors.dim,
  fontWeight: FontWeight.w700,
  fontSize: 12,
  letterSpacing: 0,
);

class OsSettingsDialog extends StatelessWidget {
  const OsSettingsDialog({
    super.key,
    required this.icon,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.child,
    this.leadingActions = const [],
    this.actions = const [],
    this.maxWidth = 520,
    this.compactHeader = false,
    this.resizable = true,
  });

  final IconData icon;
  final String eyebrow;
  final String title;
  final String subtitle;
  final Widget child;
  final List<Widget> leadingActions;
  final List<Widget> actions;
  final double maxWidth;
  final bool compactHeader;
  final bool resizable;

  @override
  Widget build(BuildContext context) {
    final frame = _ResizableDialogFrame(
      enabled: resizable,
      initialMaxWidth: maxWidth,
      initialMaxHeight: maxWidth >= 900 ? 840 : 720,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: OsColors.panel,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: OsColors.panelBorder),
          boxShadow: const [
            BoxShadow(
              color: Color(0xB3000000),
              blurRadius: 42,
              offset: Offset(0, 22),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            children: [
              const Positioned(
                right: -105,
                top: -125,
                child: _DialogGlow(size: 260, color: Color(0x245865F2)),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: compactHeader
                        ? const EdgeInsets.fromLTRB(20, 15, 16, 15)
                        : const EdgeInsets.fromLTRB(26, 24, 18, 20),
                    child: Row(
                      crossAxisAlignment: compactHeader
                          ? CrossAxisAlignment.center
                          : CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: compactHeader ? 40 : 48,
                          height: compactHeader ? 40 : 48,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [OsColors.blurple, Color(0xFF4752C4)],
                            ),
                            borderRadius: BorderRadius.circular(
                              compactHeader ? 13 : 15,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x4D5865F2),
                                blurRadius: 18,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Icon(
                            icon,
                            color: Colors.white,
                            size: compactHeader ? 21 : 24,
                          ),
                        ),
                        SizedBox(width: compactHeader ? 13 : 15),
                        Expanded(
                          child: compactHeader
                              ? Row(
                                  children: [
                                    if (eyebrow.isNotEmpty) ...[
                                      Text(
                                        eyebrow.toUpperCase(),
                                        style: const TextStyle(
                                          color: Color(0xFF8E98FF),
                                          fontSize: 10,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 0.8,
                                        ),
                                      ),
                                      const Text(
                                        '  /  ',
                                        style: TextStyle(
                                          color: OsColors.icon,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                    Text(
                                      title,
                                      style: const TextStyle(
                                        color: OsColors.text,
                                        fontSize: 21,
                                        height: 1.1,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    if (subtitle.isNotEmpty) ...[
                                      const SizedBox(width: 10),
                                      Flexible(
                                        child: Text(
                                          subtitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: OsColors.dim,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      eyebrow.toUpperCase(),
                                      style: const TextStyle(
                                        color: Color(0xFF8E98FF),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 1.15,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      title,
                                      style: const TextStyle(
                                        color: OsColors.text,
                                        fontSize: 24,
                                        height: 1.15,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      subtitle,
                                      style: const TextStyle(
                                        color: OsColors.dim,
                                        fontSize: 13,
                                        height: 1.4,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                        const SizedBox(width: 8),
                        Tooltip(
                          message: '关闭',
                          child: IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xFF303238),
                              foregroundColor: OsColors.muted,
                              fixedSize: const Size(34, 34),
                              minimumSize: const Size(34, 34),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: const Icon(Icons.close_rounded, size: 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: OsColors.panelBorder),
                  Flexible(
                    child: resizable
                        ? Padding(
                            padding: EdgeInsets.fromLTRB(
                              compactHeader ? 18 : 26,
                              compactHeader ? 14 : 20,
                              compactHeader ? 18 : 26,
                              compactHeader ? 16 : 22,
                            ),
                            child: SizedBox.expand(child: child),
                          )
                        : SmoothSingleChildScrollView(
                            padding: EdgeInsets.fromLTRB(
                              compactHeader ? 18 : 26,
                              compactHeader ? 14 : 20,
                              compactHeader ? 18 : 26,
                              compactHeader ? 16 : 22,
                            ),
                            child: child,
                          ),
                  ),
                  if (leadingActions.isNotEmpty || actions.isNotEmpty) ...[
                    const Divider(height: 1, color: OsColors.panelBorder),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(26, 15, 26, 18),
                      child: Row(
                        children: [
                          for (
                            var index = 0;
                            index < leadingActions.length;
                            index++
                          ) ...[
                            if (index > 0) const SizedBox(width: 10),
                            leadingActions[index],
                          ],
                          const Spacer(),
                          for (
                            var index = 0;
                            index < actions.length;
                            index++
                          ) ...[
                            if (index > 0) const SizedBox(width: 10),
                            actions[index],
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (resizable) {
      return Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Center(child: frame),
        ),
      );
    }
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: frame,
    );
  }
}

enum _DialogResizeEdge {
  left,
  right,
  top,
  bottom,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

class _ResizableDialogFrame extends StatefulWidget {
  const _ResizableDialogFrame({
    required this.enabled,
    required this.initialMaxWidth,
    required this.initialMaxHeight,
    required this.child,
  });

  final bool enabled;
  final double initialMaxWidth;
  final double initialMaxHeight;
  final Widget child;

  @override
  State<_ResizableDialogFrame> createState() => _ResizableDialogFrameState();
}

class _ResizableDialogFrameState extends State<_ResizableDialogFrame> {
  static const minWidth = 620.0;
  static const minHeight = 420.0;
  static const edgeExtent = 8.0;
  static const cornerExtent = 16.0;

  final panelKey = GlobalKey();
  Size? size;
  Offset offset = Offset.zero;
  Size dragStartSize = Size.zero;
  Offset dragStartOffset = Offset.zero;
  Offset dragDelta = Offset.zero;

  void startResize(DragStartDetails details) {
    final box = panelKey.currentContext?.findRenderObject() as RenderBox?;
    dragStartSize = size ?? box?.size ?? Size.zero;
    dragStartOffset = offset;
    dragDelta = Offset.zero;
  }

  void resize(
    _DialogResizeEdge edge,
    DragUpdateDetails details,
    BoxConstraints viewport,
  ) {
    if (dragStartSize.isEmpty) return;
    dragDelta += details.delta;
    final left =
        edge == _DialogResizeEdge.left ||
        edge == _DialogResizeEdge.topLeft ||
        edge == _DialogResizeEdge.bottomLeft;
    final right =
        edge == _DialogResizeEdge.right ||
        edge == _DialogResizeEdge.topRight ||
        edge == _DialogResizeEdge.bottomRight;
    final top =
        edge == _DialogResizeEdge.top ||
        edge == _DialogResizeEdge.topLeft ||
        edge == _DialogResizeEdge.topRight;
    final bottom =
        edge == _DialogResizeEdge.bottom ||
        edge == _DialogResizeEdge.bottomLeft ||
        edge == _DialogResizeEdge.bottomRight;
    final requestedWidth =
        dragStartSize.width +
        (right ? dragDelta.dx : 0) -
        (left ? dragDelta.dx : 0);
    final requestedHeight =
        dragStartSize.height +
        (bottom ? dragDelta.dy : 0) -
        (top ? dragDelta.dy : 0);
    final viewportWidth = viewport.maxWidth.isFinite
        ? viewport.maxWidth
        : dragStartSize.width;
    final viewportHeight = viewport.maxHeight.isFinite
        ? viewport.maxHeight
        : dragStartSize.height;
    final maxWidth = left
        ? viewportWidth / 2 + dragStartOffset.dx + dragStartSize.width / 2
        : right
        ? viewportWidth / 2 - dragStartOffset.dx + dragStartSize.width / 2
        : viewportWidth;
    final maxHeight = top
        ? viewportHeight / 2 + dragStartOffset.dy + dragStartSize.height / 2
        : bottom
        ? viewportHeight / 2 - dragStartOffset.dy + dragStartSize.height / 2
        : viewportHeight;
    final nextWidth = requestedWidth
        .clamp(minWidth.clamp(0, maxWidth), maxWidth)
        .toDouble();
    final nextHeight = requestedHeight
        .clamp(minHeight.clamp(0, maxHeight), maxHeight)
        .toDouble();
    final widthDelta = nextWidth - dragStartSize.width;
    final heightDelta = nextHeight - dragStartSize.height;
    setState(() {
      size = Size(nextWidth, nextHeight);
      offset =
          dragStartOffset +
          Offset(
            left
                ? -widthDelta / 2
                : right
                ? widthDelta / 2
                : 0,
            top
                ? -heightDelta / 2
                : bottom
                ? heightDelta / 2
                : 0,
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: widget.initialMaxWidth,
          maxHeight: widget.initialMaxHeight,
        ),
        child: widget.child,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final panel = size == null
            ? ConstrainedBox(
                key: panelKey,
                constraints: BoxConstraints(
                  maxWidth: widget.initialMaxWidth,
                  maxHeight: widget.initialMaxHeight,
                ),
                child: widget.child,
              )
            : SizedBox(
                key: panelKey,
                width: size!.width,
                height: size!.height,
                child: widget.child,
              );
        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Center(
            child: Transform.translate(
              offset: offset,
              child: Stack(
                clipBehavior: Clip.none,
                children: [panel, ..._resizeHandles(constraints)],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _resizeHandles(BoxConstraints viewport) {
    Widget handle({
      required _DialogResizeEdge edge,
      required MouseCursor cursor,
      double? left,
      double? right,
      double? top,
      double? bottom,
      double? width,
      double? height,
    }) {
      return Positioned(
        left: left,
        right: right,
        top: top,
        bottom: bottom,
        width: width,
        height: height,
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            key: ValueKey('settings-dialog-resize-${edge.name}'),
            behavior: HitTestBehavior.opaque,
            onPanStart: startResize,
            onPanUpdate: (details) => resize(edge, details, viewport),
          ),
        ),
      );
    }

    return [
      handle(
        edge: _DialogResizeEdge.left,
        cursor: SystemMouseCursors.resizeLeftRight,
        left: 0,
        top: cornerExtent,
        bottom: cornerExtent,
        width: edgeExtent,
      ),
      handle(
        edge: _DialogResizeEdge.right,
        cursor: SystemMouseCursors.resizeLeftRight,
        right: 0,
        top: cornerExtent,
        bottom: cornerExtent,
        width: edgeExtent,
      ),
      handle(
        edge: _DialogResizeEdge.top,
        cursor: SystemMouseCursors.resizeUpDown,
        left: cornerExtent,
        right: cornerExtent,
        top: 0,
        height: edgeExtent,
      ),
      handle(
        edge: _DialogResizeEdge.bottom,
        cursor: SystemMouseCursors.resizeUpDown,
        left: cornerExtent,
        right: cornerExtent,
        bottom: 0,
        height: edgeExtent,
      ),
      handle(
        edge: _DialogResizeEdge.topLeft,
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
        left: 0,
        top: 0,
        width: cornerExtent,
        height: cornerExtent,
      ),
      handle(
        edge: _DialogResizeEdge.topRight,
        cursor: SystemMouseCursors.resizeUpRightDownLeft,
        right: 0,
        top: 0,
        width: cornerExtent,
        height: cornerExtent,
      ),
      handle(
        edge: _DialogResizeEdge.bottomLeft,
        cursor: SystemMouseCursors.resizeUpRightDownLeft,
        left: 0,
        bottom: 0,
        width: cornerExtent,
        height: cornerExtent,
      ),
      handle(
        edge: _DialogResizeEdge.bottomRight,
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
        right: 0,
        bottom: 0,
        width: cornerExtent,
        height: cornerExtent,
      ),
    ];
  }
}

class OsSplitSettingsBody extends StatelessWidget {
  const OsSplitSettingsBody({
    super.key,
    required this.navigation,
    required this.content,
    this.showNavigation = true,
  });

  final List<Widget> navigation;
  final Widget content;
  final bool showNavigation;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 370,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (!showNavigation) return content;
          if (constraints.maxWidth < 560) {
            return Column(
              children: [
                Container(
                  height: 58,
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: const Color(0xFF222429),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: OsColors.panelBorder),
                  ),
                  child: Row(
                    children: [
                      for (final entry in navigation) Expanded(child: entry),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(child: content),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 205,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF222429),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: OsColors.panelBorder),
                ),
                child: SmoothListView(
                  padding: EdgeInsets.zero,
                  children: navigation,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(child: content),
            ],
          );
        },
      ),
    );
  }
}

class OsSettingsNavEntry extends StatelessWidget {
  const OsSettingsNavEntry({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        color: selected ? OsColors.blurpleSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          onTap: onTap,
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(11),
          hoverColor: OsColors.rowSelected,
          child: Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: selected
                  ? const Border(
                      left: BorderSide(color: OsColors.blurple, width: 3),
                    )
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: selected ? const Color(0xFF929CFF) : OsColors.dim,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? OsColors.text : OsColors.muted,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                    ),
                  ),
                ),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF34373D),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      badge!,
                      style: const TextStyle(
                        color: OsColors.dim,
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class OsSettingsNavSection extends StatelessWidget {
  const OsSettingsNavSection(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(11, 10, 8, 5),
      child: Text(
        label,
        style: const TextStyle(
          color: OsColors.icon,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class OsSettingsPage extends StatelessWidget {
  const OsSettingsPage({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
    this.footer,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF222429),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: OsColors.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 12),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: OsColors.blurpleSoft,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, color: OsColors.blurple, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: OsColors.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: OsColors.dim,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: OsColors.panelBorder),
          Expanded(
            child: SmoothSingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: child,
            ),
          ),
          if (footer != null) ...[
            const Divider(height: 1, color: OsColors.panelBorder),
            Padding(padding: const EdgeInsets.all(12), child: footer),
          ],
        ],
      ),
    );
  }
}

class OsClientAudioSettingsPane extends StatefulWidget {
  const OsClientAudioSettingsPane({
    super.key,
    required this.deviceMonitor,
    required this.initialInputDeviceId,
    required this.initialOutputDeviceId,
    required this.initialActivationMode,
    required this.initialThreshold,
    required this.initialPushToTalkHotkey,
    required this.initialSoundEffectVolume,
    required this.microphoneInputLevel,
    required this.onSave,
    required this.onSoundEffectPreview,
    this.captureCoordinator,
    this.devicesOnly = false,
  });

  final AudioDeviceMonitor deviceMonitor;
  final String? initialInputDeviceId;
  final String? initialOutputDeviceId;
  final MicrophoneActivationMode initialActivationMode;
  final double initialThreshold;
  final MicrophoneHotkeyBinding? initialPushToTalkHotkey;
  final double initialSoundEffectVolume;
  final ValueListenable<double> microphoneInputLevel;
  final VoiceSessionController? captureCoordinator;
  final bool devicesOnly;
  final void Function(
    String? inputDeviceId,
    String? outputDeviceId,
    MicrophoneActivationMode activationMode,
    double threshold,
    MicrophoneHotkeyBinding? pushToTalkHotkey,
    double soundEffectVolume,
  )
  onSave;
  final ValueChanged<double> onSoundEffectPreview;

  @override
  State<OsClientAudioSettingsPane> createState() =>
      _OsClientAudioSettingsPaneState();
}

class _OsClientAudioSettingsPaneState extends State<OsClientAudioSettingsPane> {
  String inputValue = '';
  String outputValue = '';
  late MicrophoneActivationMode activationMode;
  late double threshold;
  late double soundEffectVolume;
  MicrophoneHotkeyBinding? pushToTalkHotkey;
  bool recordingHotkey = false;
  bool saving = false;
  final hotkeyFocusNode = FocusNode(debugLabel: 'push-to-talk-recorder');
  late final MicrophoneInputLevelPreview microphoneLevelPreview;

  @override
  void initState() {
    super.initState();
    inputValue = widget.initialInputDeviceId ?? '';
    outputValue = widget.initialOutputDeviceId ?? '';
    activationMode = widget.initialActivationMode;
    threshold = widget.initialThreshold;
    soundEffectVolume = widget.initialSoundEffectVolume
        .clamp(0.0, 1.0)
        .toDouble();
    pushToTalkHotkey = widget.initialPushToTalkHotkey;
    microphoneLevelPreview = MicrophoneInputLevelPreview(
      fallbackLevel: widget.microphoneInputLevel,
    );
    widget.deviceMonitor.addListener(_onDevicesChanged);
    widget.captureCoordinator?.registerMicrophonePreviewReleaseHandler(
      this,
      _releaseMicrophonePreview,
    );
    if (!widget.devicesOnly &&
        activationMode == MicrophoneActivationMode.voiceThreshold) {
      unawaited(_startMicrophonePreview());
    }
  }

  @override
  void didUpdateWidget(OsClientAudioSettingsPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceMonitor == widget.deviceMonitor) return;
    oldWidget.deviceMonitor.removeListener(_onDevicesChanged);
    widget.deviceMonitor.addListener(_onDevicesChanged);
    _dropUnavailableSelections();
  }

  @override
  void dispose() {
    widget.deviceMonitor.removeListener(_onDevicesChanged);
    widget.captureCoordinator?.unregisterMicrophonePreviewReleaseHandler(this);
    hotkeyFocusNode.dispose();
    microphoneLevelPreview.dispose();
    super.dispose();
  }

  Future<void> _startMicrophonePreview() async {
    if (widget.captureCoordinator?.needsVoiceMicrophoneCapture == true) {
      await microphoneLevelPreview.stop();
      return;
    }
    await microphoneLevelPreview.start(
      deviceId: inputValue.isEmpty ? null : inputValue,
    );
  }

  Future<void> _releaseMicrophonePreview() => microphoneLevelPreview.stop();

  Future<void> _saveSettings() async {
    if (saving) return;
    setState(() => saving = true);
    await _releaseMicrophonePreview();
    if (!mounted) return;
    widget.onSave(
      inputValue.isEmpty ? null : inputValue,
      outputValue.isEmpty ? null : outputValue,
      activationMode,
      threshold,
      pushToTalkHotkey,
      soundEffectVolume,
    );
  }

  void _setActivationMode(MicrophoneActivationMode mode) {
    setState(() => activationMode = mode);
    if (mode == MicrophoneActivationMode.voiceThreshold) {
      unawaited(_startMicrophonePreview());
    } else {
      unawaited(microphoneLevelPreview.stop());
    }
  }

  KeyEventResult _recordHotkey(FocusNode node, KeyEvent event) {
    if (!recordingHotkey) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (event.physicalKey == PhysicalKeyboardKey.escape) {
      setState(() => recordingHotkey = false);
      return KeyEventResult.handled;
    }
    if (event.physicalKey == PhysicalKeyboardKey.backspace ||
        event.physicalKey == PhysicalKeyboardKey.delete) {
      setState(() {
        pushToTalkHotkey = null;
        recordingHotkey = false;
      });
      return KeyEventResult.handled;
    }
    if (isModifierPhysicalKey(event.physicalKey)) {
      return KeyEventResult.handled;
    }
    final modifiers = currentHotkeyModifiers();
    setState(() {
      pushToTalkHotkey = MicrophoneHotkeyBinding(
        usbHidUsage: event.physicalKey.usbHidUsage,
        modifiers: modifiers,
        label: hotkeyLabel(event.physicalKey, modifiers),
      );
      recordingHotkey = false;
    });
    return KeyEventResult.handled;
  }

  void _onDevicesChanged() {
    if (!mounted) return;
    setState(_dropUnavailableSelections);
  }

  void _dropUnavailableSelections() {
    if (!widget.deviceMonitor.lastRefreshSucceeded) return;
    final next = audioDeviceSelectionAfterRefresh(
      inputDeviceId: inputValue.isEmpty ? null : inputValue,
      outputDeviceId: outputValue.isEmpty ? null : outputValue,
      devices: widget.deviceMonitor.devices.where(
        (device) => !isWebRtcVirtualDefaultAudioDevice(device),
      ),
    );
    inputValue = next.inputDeviceId ?? '';
    outputValue = next.outputDeviceId ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final monitor = widget.deviceMonitor;
    if (!monitor.hasLoaded && monitor.error == null) {
      return const OsSettingsPage(
        icon: Icons.headphones_rounded,
        title: '音频设备',
        subtitle: '选择通话使用的输入和输出设备。',
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(36),
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }
    if (!monitor.hasLoaded && monitor.error != null) {
      return OsSettingsPage(
        icon: Icons.headphones_rounded,
        title: '音频设备',
        subtitle: '选择通话使用的输入和输出设备。',
        child: OsSettingsTile(
          icon: Icons.error_outline_rounded,
          title: '无法读取音频设备',
          subtitle: '${monitor.error}',
          enabled: false,
        ),
      );
    }
    final devices = monitor.devices;
    final inputs = selectableAudioDevices(devices, 'audioinput');
    final outputs = selectableAudioDevices(devices, 'audiooutput');
    final currentDefaultInput = webRtcDefaultAudioDeviceName(
      devices,
      'audioinput',
    );
    final defaultInputLabel = systemDefaultAudioDeviceLabel(
      devices,
      'audioinput',
      '系统默认麦克风',
    );
    final defaultOutputLabel = systemDefaultAudioDeviceLabel(
      devices,
      'audiooutput',
      '系统默认扬声器',
    );
    return OsSettingsPage(
      icon: Icons.headphones_rounded,
      title: '音频设备',
      subtitle: '选择通话使用的输入和输出设备。',
      footer: Align(
        alignment: Alignment.centerRight,
        child: OsPrimaryButton(
          label: saving ? '正在保存…' : '保存设置',
          icon: Icons.check_rounded,
          onPressed: () {
            if (!saving) unawaited(_saveSettings());
          },
        ),
      ),
      child: Column(
        children: [
          OsFormCard(
            icon: Icons.mic_none_rounded,
            title: '麦克风',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AudioDeviceDropdown(
                  label: '输入设备',
                  value: inputValue,
                  devices: inputs,
                  emptyLabel: inputs.isEmpty && currentDefaultInput == null
                      ? '未发现麦克风'
                      : defaultInputLabel,
                  onChanged: (value) {
                    setState(() => inputValue = value ?? '');
                    if (!widget.devicesOnly &&
                        activationMode ==
                            MicrophoneActivationMode.voiceThreshold) {
                      unawaited(_startMicrophonePreview());
                    }
                  },
                ),
                if (!widget.devicesOnly &&
                    (inputs.isNotEmpty || currentDefaultInput != null)) ...[
                  const SizedBox(height: 12),
                  MicrophoneActivationCard(
                    mode: activationMode,
                    threshold: threshold,
                    pushToTalkHotkey: pushToTalkHotkey,
                    microphoneInputLevel: microphoneLevelPreview,
                    recordingHotkey: recordingHotkey,
                    hotkeyFocusNode: hotkeyFocusNode,
                    onHotkeyEvent: _recordHotkey,
                    onModeChanged: _setActivationMode,
                    onThresholdChanged: (value) =>
                        setState(() => threshold = value),
                    onStartHotkeyRecording: () {
                      setState(() => recordingHotkey = true);
                      hotkeyFocusNode.requestFocus();
                    },
                    onClearHotkey: () => setState(() {
                      pushToTalkHotkey = null;
                      recordingHotkey = false;
                    }),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          OsFormCard(
            icon: Icons.volume_up_outlined,
            title: '扬声器',
            child: AudioDeviceDropdown(
              label: '输出设备',
              value: outputValue,
              devices: outputs,
              emptyLabel: defaultOutputLabel,
              onChanged: (value) {
                setState(() => outputValue = value ?? '');
              },
            ),
          ),
          if (!widget.devicesOnly) ...[
            const SizedBox(height: 12),
            OsFormCard(
              icon: Icons.music_note_rounded,
              title: '音效',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(child: OsFieldLabel('音效音量')),
                      Text(
                        '${(soundEffectVolume * 100).round()}%',
                        key: const ValueKey('sound-effect-volume-percent'),
                        style: const TextStyle(
                          color: OsColors.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          fontFeatures: [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    key: const ValueKey('sound-effect-volume-slider'),
                    value: soundEffectVolume,
                    divisions: 100,
                    onChanged: (value) =>
                        setState(() => soundEffectVolume = value),
                    onChangeEnd: widget.onSoundEffectPreview,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class MicrophoneActivationCard extends StatelessWidget {
  const MicrophoneActivationCard({
    super.key,
    required this.mode,
    required this.threshold,
    required this.pushToTalkHotkey,
    required this.microphoneInputLevel,
    required this.recordingHotkey,
    required this.hotkeyFocusNode,
    required this.onHotkeyEvent,
    required this.onModeChanged,
    required this.onThresholdChanged,
    required this.onStartHotkeyRecording,
    required this.onClearHotkey,
  });

  final MicrophoneActivationMode mode;
  final double threshold;
  final MicrophoneHotkeyBinding? pushToTalkHotkey;
  final ValueListenable<double> microphoneInputLevel;
  final bool recordingHotkey;
  final FocusNode hotkeyFocusNode;
  final FocusOnKeyEventCallback onHotkeyEvent;
  final ValueChanged<MicrophoneActivationMode> onModeChanged;
  final ValueChanged<double> onThresholdChanged;
  final VoidCallback onStartHotkeyRecording;
  final VoidCallback onClearHotkey;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: OsColors.content,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: OsColors.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const OsFieldLabel('麦克风激活方式'),
          const SizedBox(height: 8),
          if (!kIsWeb) ...[
            MicrophoneActivationOption(
              selected: mode == MicrophoneActivationMode.pushToTalk,
              title: '按键通话',
              subtitle: '按住指定快捷键时传输声音',
              onTap: () => onModeChanged(MicrophoneActivationMode.pushToTalk),
              expanded: mode == MicrophoneActivationMode.pushToTalk
                  ? Focus(
                      focusNode: hotkeyFocusNode,
                      onKeyEvent: onHotkeyEvent,
                      child: PushToTalkHotkeyField(
                        binding: pushToTalkHotkey,
                        recording: recordingHotkey,
                        onRecord: onStartHotkeyRecording,
                        onClear: onClearHotkey,
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 7),
          ],
          MicrophoneActivationOption(
            selected: mode == MicrophoneActivationMode.continuous,
            title: '持续传输',
            subtitle: '进入语音且有其他参与者时持续传输',
            onTap: () => onModeChanged(MicrophoneActivationMode.continuous),
            expanded: mode == MicrophoneActivationMode.continuous
                ? const _ActivationHint(text: '只有进入语音且房间存在其他参与者时才会上传音频。')
                : null,
          ),
          if (!kIsWeb) ...[
            const SizedBox(height: 7),
            MicrophoneActivationOption(
              selected: mode == MicrophoneActivationMode.voiceThreshold,
              title: '语音阈值',
              subtitle: '输入音量超过阈值时自动传输',
              onTap: () =>
                  onModeChanged(MicrophoneActivationMode.voiceThreshold),
              expanded: mode == MicrophoneActivationMode.voiceThreshold
                  ? MicrophoneThresholdMeter(
                      level: microphoneInputLevel,
                      threshold: threshold,
                      onChanged: onThresholdChanged,
                    )
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

class MicrophoneActivationOption extends StatelessWidget {
  const MicrophoneActivationOption({
    super.key,
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.icon,
    this.expanded,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final IconData? icon;
  final Widget? expanded;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: onTap == null && !selected ? 0.55 : 1,
      duration: const Duration(milliseconds: 150),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: selected ? OsColors.blurpleSoft : OsColors.panelRaised,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: selected ? OsColors.blurple : OsColors.panelBorder,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MouseRegion(
              cursor: onTap == null
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(11),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 9,
                  ),
                  child: Row(
                    children: [
                      if (icon != null) ...[
                        Icon(
                          icon,
                          color: selected ? OsColors.blurple : OsColors.muted,
                          size: 19,
                        ),
                        const SizedBox(width: 10),
                      ],
                      Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? OsColors.blurple : OsColors.muted,
                            width: 2,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: selected
                            ? Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: OsColors.blurple,
                                  shape: BoxShape.circle,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                color: OsColors.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              style: const TextStyle(
                                color: OsColors.dim,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (expanded != null) ...[
              const Divider(height: 1, color: OsColors.panelBorder),
              Padding(padding: const EdgeInsets.all(10), child: expanded!),
            ],
          ],
        ),
      ),
    );
  }
}

class PushToTalkHotkeyField extends StatelessWidget {
  const PushToTalkHotkeyField({
    super.key,
    required this.binding,
    required this.recording,
    required this.onRecord,
    required this.onClear,
  });

  final MicrophoneHotkeyBinding? binding;
  final bool recording;
  final VoidCallback onRecord;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const OsFieldLabel('系统级快捷键'),
        const SizedBox(height: 7),
        Row(
          children: [
            Expanded(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: InkWell(
                  onTap: onRecord,
                  borderRadius: BorderRadius.circular(9),
                  child: Container(
                    height: 42,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    decoration: BoxDecoration(
                      color: OsColors.sidebar,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: recording
                            ? OsColors.blurple
                            : OsColors.panelBorder,
                      ),
                    ),
                    child: Text(
                      recording
                          ? '请按下快捷键…'
                          : binding == null
                          ? '快捷键：未设置'
                          : hotkeyBindingLabel(binding!),
                      style: TextStyle(
                        color: recording || binding != null
                            ? OsColors.text
                            : OsColors.dim,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (binding != null) ...[
              const SizedBox(width: 7),
              IconButton(
                tooltip: '清除快捷键',
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          '点击后录制下一组按键；Esc 取消，Delete 或 Backspace 清除。',
          style: TextStyle(color: OsColors.dim, fontSize: 10),
        ),
      ],
    );
  }
}

class MicrophoneThresholdMeter extends StatelessWidget {
  const MicrophoneThresholdMeter({
    super.key,
    required this.level,
    required this.threshold,
    required this.onChanged,
  });

  final ValueListenable<double> level;
  final double threshold;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const OsFieldLabel('输入音量与传输阈值'),
            Text(
              microphoneThresholdLabel(threshold),
              style: const TextStyle(
                color: OsColors.blurple,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<double>(
          valueListenable: level,
          builder: (context, inputLevel, _) => LayoutBuilder(
            builder: (context, constraints) {
              void update(double x) => onChanged(
                (x / constraints.maxWidth).clamp(0.0, 1.0).toDouble(),
              );
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) => update(details.localPosition.dx),
                onHorizontalDragUpdate: (details) =>
                    update(details.localPosition.dx),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: SizedBox(
                    height: 24,
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        Container(
                          height: 10,
                          decoration: BoxDecoration(
                            color: OsColors.sidebar,
                            borderRadius: BorderRadius.circular(99),
                            border: Border.all(color: OsColors.panelBorder),
                          ),
                        ),
                        FractionallySizedBox(
                          key: const ValueKey('microphone-current-level'),
                          widthFactor: inputLevel.clamp(0.0, 1.0),
                          child: Container(
                            height: 8,
                            decoration: BoxDecoration(
                              color: inputLevel >= threshold
                                  ? OsColors.green
                                  : OsColors.blurple,
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                        ),
                        Positioned(
                          left: (constraints.maxWidth * threshold - 2).clamp(
                            0,
                            constraints.maxWidth - 4,
                          ),
                          child: Container(
                            width: 4,
                            height: 20,
                            decoration: BoxDecoration(
                              color: OsColors.text,
                              borderRadius: BorderRadius.circular(3),
                              boxShadow: const [
                                BoxShadow(color: Colors.black45, blurRadius: 3),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 5),
        const Text(
          '点击或拖动音量条设置阈值；只有输入音量越过标记时才传输。',
          style: TextStyle(color: OsColors.dim, fontSize: 10),
        ),
      ],
    );
  }
}

class _ActivationHint extends StatelessWidget {
  const _ActivationHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline_rounded, size: 15, color: OsColors.dim),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: OsColors.dim, fontSize: 10),
          ),
        ),
      ],
    );
  }
}

enum MemberManagementAction { makeAdmin, makeUser, kick, ban, unban }

class BanMemberRequest {
  const BanMemberRequest({required this.reason, required this.durationSeconds});

  final String reason;
  final int durationSeconds;
}

class OsMemberManagementPane extends StatefulWidget {
  const OsMemberManagementPane({
    super.key,
    required this.api,
    required this.token,
    required this.serverId,
    required this.currentUserId,
    required this.currentUserIsOwner,
    required this.permissions,
  });

  final OpenSpeakApi api;
  final String token;
  final String serverId;
  final String currentUserId;
  final bool currentUserIsOwner;
  final Set<String> permissions;

  @override
  State<OsMemberManagementPane> createState() => _OsMemberManagementPaneState();
}

class _OsMemberManagementPaneState extends State<OsMemberManagementPane> {
  var category = 'all';
  var loading = true;
  String? error;
  List<ManagedServerMember> members = const [];

  @override
  void initState() {
    super.initState();
    unawaited(loadMembers());
  }

  Future<void> loadMembers() async {
    if (mounted) setState(() => loading = true);
    try {
      final next = await widget.api.listManagedServerMembers(
        widget.token,
        widget.serverId,
      );
      if (!mounted) return;
      setState(() {
        members = next;
        error = null;
        loading = false;
      });
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        error = '$exception';
        loading = false;
      });
    }
  }

  List<ManagedServerMember> get visibleMembers => members
      .where((member) {
        return switch (category) {
          'online' => member.online,
          'admin' => member.role == 'owner' || member.role == 'admin',
          'banned' => member.banned,
          _ => true,
        };
      })
      .toList(growable: false);

  Future<void> handleAction(
    ManagedServerMember member,
    MemberManagementAction action,
  ) async {
    try {
      switch (action) {
        case MemberManagementAction.makeAdmin:
          await widget.api.updateServerMemberRole(
            widget.token,
            widget.serverId,
            member.userId,
            'admin',
          );
        case MemberManagementAction.makeUser:
          await widget.api.updateServerMemberRole(
            widget.token,
            widget.serverId,
            member.userId,
            'user',
          );
        case MemberManagementAction.kick:
          await widget.api.kickServerMember(
            widget.token,
            widget.serverId,
            member.userId,
          );
        case MemberManagementAction.ban:
          final request = await showBanDialog(member);
          if (request == null) return;
          await widget.api.banServerMember(
            widget.token,
            widget.serverId,
            member.userId,
            reason: request.reason,
            durationSeconds: request.durationSeconds,
          );
        case MemberManagementAction.unban:
          await widget.api.unbanServerMember(
            widget.token,
            widget.serverId,
            member.userId,
          );
      }
      if (action == MemberManagementAction.kick ||
          action == MemberManagementAction.ban) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      await loadMembers();
    } catch (exception) {
      if (!mounted) return;
      setState(() => error = '$exception');
    }
  }

  Future<BanMemberRequest?> showBanDialog(ManagedServerMember member) async {
    final reasonController = TextEditingController();
    var durationSeconds = 7 * 24 * 60 * 60;
    try {
      return await showDialog<BanMemberRequest>(
        context: context,
        barrierColor: const Color(0xC7000000),
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => OsSettingsDialog(
            icon: Icons.block_rounded,
            eyebrow: '成员与权限',
            title: '封禁 ${member.displayName}',
            subtitle: '封禁当前客户端识别码，并立即断开其连接。',
            actions: [
              OsSecondaryButton(
                label: '取消',
                onPressed: () => Navigator.pop(context),
              ),
              OsPrimaryButton(
                label: '确认封禁',
                icon: Icons.block_rounded,
                onPressed: () => Navigator.pop(
                  context,
                  BanMemberRequest(
                    reason: reasonController.text.trim(),
                    durationSeconds: durationSeconds,
                  ),
                ),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const OsFieldLabel('封禁原因'),
                const SizedBox(height: 7),
                TextField(
                  controller: reasonController,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    hintText: '可选，例如：骚扰其他成员',
                    prefixIcon: Icon(Icons.notes_rounded, size: 20),
                  ),
                ),
                const SizedBox(height: 12),
                const OsFieldLabel('封禁时长'),
                const SizedBox(height: 7),
                DropdownButtonFormField<int>(
                  initialValue: durationSeconds,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.schedule_rounded, size: 20),
                  ),
                  items: const [
                    DropdownMenuItem(value: 3600, child: Text('1 小时')),
                    DropdownMenuItem(value: 86400, child: Text('1 天')),
                    DropdownMenuItem(value: 604800, child: Text('7 天')),
                    DropdownMenuItem(value: 2592000, child: Text('30 天')),
                    DropdownMenuItem(value: 0, child: Text('永久')),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => durationSeconds = value ?? 0),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      reasonController.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return OsSplitSettingsBody(
      navigation: [
        OsSettingsNavEntry(
          icon: Icons.groups_outlined,
          label: '全部成员',
          selected: category == 'all',
          onTap: () => setState(() => category = 'all'),
        ),
        OsSettingsNavEntry(
          icon: Icons.wifi_rounded,
          label: '在线成员',
          selected: category == 'online',
          onTap: () => setState(() => category = 'online'),
        ),
        OsSettingsNavEntry(
          icon: Icons.admin_panel_settings_outlined,
          label: '管理员',
          selected: category == 'admin',
          onTap: () => setState(() => category = 'admin'),
        ),
        OsSettingsNavEntry(
          icon: Icons.block_rounded,
          label: '黑名单',
          selected: category == 'banned',
          onTap: () => setState(() => category = 'banned'),
        ),
      ],
      content: OsSettingsPage(
        icon: Icons.manage_accounts_outlined,
        title: switch (category) {
          'online' => '在线成员',
          'admin' => '管理员',
          'banned' => '黑名单',
          _ => '全部成员',
        },
        subtitle: '查看历史登录成员，调整角色并管理客户端黑名单。',
        child: buildMemberList(),
      ),
    );
  }

  Widget buildMemberList() {
    if (loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          OsSettingsTile(
            icon: Icons.error_outline_rounded,
            title: '无法读取成员',
            subtitle: error!,
            enabled: false,
          ),
          const SizedBox(height: 10),
          OsPrimaryButton(
            label: '重试',
            icon: Icons.refresh_rounded,
            onPressed: () => unawaited(loadMembers()),
          ),
        ],
      );
    }
    final visible = visibleMembers;
    if (visible.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('这里还没有成员', style: TextStyle(color: OsColors.dim)),
      );
    }
    return Column(
      children: [
        for (var index = 0; index < visible.length; index++) ...[
          OsManagedMemberRow(
            member: visible[index],
            currentUser: visible[index].userId == widget.currentUserId,
            canChangeRole: widget.currentUserIsOwner,
            permissions: widget.permissions,
            onAction: (action) =>
                unawaited(handleAction(visible[index], action)),
          ),
          if (index + 1 < visible.length) const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class OsManagedMemberRow extends StatelessWidget {
  const OsManagedMemberRow({
    super.key,
    required this.member,
    required this.currentUser,
    required this.canChangeRole,
    this.permissions = const {},
    required this.onAction,
  });

  final ManagedServerMember member;
  final bool currentUser;
  final bool canChangeRole;
  final Set<String> permissions;
  final ValueChanged<MemberManagementAction> onAction;

  @override
  Widget build(BuildContext context) {
    final roleLabel = switch (member.role) {
      'owner' => '服主',
      'admin' => '管理员',
      _ => '成员',
    };
    final lastSeen = member.lastSeenAt?.toLocal();
    final subtitle = [
      member.online ? '在线' : '离线',
      if (lastSeen != null)
        '最后登录 ${lastSeen.month}/${lastSeen.day} ${lastSeen.hour.toString().padLeft(2, '0')}:${lastSeen.minute.toString().padLeft(2, '0')}',
      if (member.legacy) '旧版身份',
      if (member.banned) '已封禁',
    ].join(' · ');
    final actionsEnabled = member.role != 'owner';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: member.banned ? const Color(0xFF35272B) : OsColors.panelRaised,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: member.banned ? const Color(0x665C3035) : OsColors.panelBorder,
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: member.banned
                ? OsColors.disconnect
                : OsColors.blurple,
            child: Text(
              initials(member.displayName).substring(0, 1),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        member.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: OsColors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    _MemberRoleBadge(label: roleLabel, role: member.role),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: OsColors.dim,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (actionsEnabled)
            PopupMenuButton<MemberManagementAction>(
              tooltip: '管理成员',
              onSelected: onAction,
              itemBuilder: (context) => [
                if (canChangeRole && member.role == 'user')
                  const PopupMenuItem(
                    value: MemberManagementAction.makeAdmin,
                    child: Text('设为管理员'),
                  ),
                if (canChangeRole && member.role == 'admin')
                  const PopupMenuItem(
                    value: MemberManagementAction.makeUser,
                    child: Text('设为普通成员'),
                  ),
                if (permissions.contains('member.kick') &&
                    member.online &&
                    !currentUser)
                  const PopupMenuItem(
                    value: MemberManagementAction.kick,
                    child: Text('踢出当前连接'),
                  ),
                if (permissions.contains('member.unban') && member.banned)
                  const PopupMenuItem(
                    value: MemberManagementAction.unban,
                    child: Text('解除封禁'),
                  )
                else if (permissions.contains('member.ban') &&
                    !member.legacy &&
                    !currentUser)
                  const PopupMenuItem(
                    value: MemberManagementAction.ban,
                    child: Text('加入黑名单'),
                  ),
              ],
              icon: const Icon(Icons.more_horiz_rounded, color: OsColors.dim),
            ),
        ],
      ),
    );
  }
}

class _MemberRoleBadge extends StatelessWidget {
  const _MemberRoleBadge({required this.label, required this.role});

  final String label;
  final String role;

  @override
  Widget build(BuildContext context) {
    final color = switch (role) {
      'owner' => const Color(0xFFFFC857),
      'admin' => const Color(0xFF929CFF),
      _ => OsColors.dim,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _OsStatusBadge extends StatelessWidget {
  const _OsStatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800),
    ),
  );
}

class OsSettingsTile extends StatelessWidget {
  const OsSettingsTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.enabled = true,
    this.badge,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool enabled;
  final String? badge;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onTap != null;
    final accent = danger ? OsColors.danger : OsColors.blurple;
    return Material(
      color: active ? OsColors.panelRaised : const Color(0xFF292B30),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: active ? onTap : null,
        mouseCursor: active
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        borderRadius: BorderRadius.circular(14),
        hoverColor: danger ? const Color(0x263C252A) : const Color(0x143F4EE8),
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: active ? OsColors.panelBorder : const Color(0xFF32353B),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: active
                      ? accent.withValues(alpha: 0.16)
                      : const Color(0xFF31343A),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  size: 19,
                  color: active ? accent : OsColors.icon,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: active
                            ? (danger ? const Color(0xFFFF8A8C) : OsColors.text)
                            : OsColors.icon,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: active ? OsColors.dim : const Color(0xFF70767E),
                        fontSize: 12,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF34373D),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    badge!,
                    style: const TextStyle(
                      color: OsColors.dim,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ] else if (active)
                Icon(
                  Icons.chevron_right_rounded,
                  color: danger ? OsColors.danger : OsColors.dim,
                  size: 22,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class OsPopupMenuRow extends StatelessWidget {
  const OsPopupMenuRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFFF6B6E) : OsColors.text;
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: danger ? const Color(0x333C252A) : OsColors.blurpleSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            size: 18,
            color: danger ? OsColors.danger : OsColors.blurple,
          ),
        ),
        const SizedBox(width: 11),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              subtitle,
              style: const TextStyle(
                color: OsColors.dim,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class MemberVolumePopupEntry extends PopupMenuEntry<int> {
  const MemberVolumePopupEntry({
    super.key,
    required this.displayName,
    required this.initialVolume,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String displayName;
  final double initialVolume;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  double get height => 80;

  @override
  bool represents(int? value) => false;

  @override
  State<MemberVolumePopupEntry> createState() => _MemberVolumePopupEntryState();
}

class _MemberVolumePopupEntryState extends State<MemberVolumePopupEntry> {
  late double volume = widget.initialVolume.clamp(0.0, 2.0).toDouble();

  @override
  Widget build(BuildContext context) {
    final percent = (volume * 100).round();
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: OsColors.blurpleSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.volume_up_outlined,
                    color: OsColors.blurple,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '调整音量',
                        style: TextStyle(
                          color: OsColors.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        widget.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: OsColors.dim,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '$percent%',
                  key: const ValueKey('member-volume-percent'),
                  style: const TextStyle(
                    color: OsColors.text,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 24,
              child: Row(
                children: [
                  const Text(
                    '0%',
                    style: TextStyle(color: OsColors.dim, fontSize: 11),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: OsColors.blurple,
                        inactiveTrackColor: const Color(0xFF3A3D44),
                        trackHeight: 4,
                        thumbColor: OsColors.text,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayColor: const Color(0x335865F2),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                      ),
                      child: Slider(
                        key: const ValueKey('member-volume-slider'),
                        min: 0,
                        max: 2,
                        divisions: 200,
                        value: volume,
                        onChanged: (value) {
                          setState(() => volume = value);
                          widget.onChanged(value);
                        },
                        onChangeEnd: widget.onChangeEnd,
                      ),
                    ),
                  ),
                  const Text(
                    '200%',
                    style: TextStyle(color: OsColors.dim, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class OsPrimaryButton extends StatelessWidget {
  const OsPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: OsColors.blurple,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w900),
      ),
      icon: Icon(icon ?? Icons.arrow_forward_rounded, size: 17),
      label: Text(label),
    );
  }
}

class OsSecondaryButton extends StatelessWidget {
  const OsSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final style = TextButton.styleFrom(
      foregroundColor: OsColors.muted,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      textStyle: const TextStyle(fontWeight: FontWeight.w800),
    );
    if (icon != null) {
      return TextButton.icon(
        onPressed: onPressed,
        style: style,
        icon: Icon(icon, size: 17),
        label: Text(label),
      );
    }
    return TextButton(onPressed: onPressed, style: style, child: Text(label));
  }
}

class OsFieldLabel extends StatelessWidget {
  const OsFieldLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: const TextStyle(
      color: OsColors.muted,
      fontSize: 12,
      fontWeight: FontWeight.w800,
    ),
  );
}

class OsSectionLabel extends StatelessWidget {
  const OsSectionLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: const TextStyle(
      color: OsColors.dim,
      fontSize: 11,
      fontWeight: FontWeight.w900,
      letterSpacing: 0.7,
    ),
  );
}

class OsUserAvatar extends StatelessWidget {
  const OsUserAvatar({
    super.key,
    required this.displayName,
    required this.size,
    this.avatarFile,
    this.avatarRevision = 0,
    this.avatarUri,
    this.avatarToken,
    this.borderRadius,
    this.backgroundColor = OsColors.blurple,
  });
  final String displayName;
  final double size;
  final File? avatarFile;
  final int avatarRevision;
  final Uri? avatarUri;
  final String? avatarToken;
  final BorderRadius? borderRadius;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    Widget fallback() => ColoredBox(
      color: backgroundColor,
      child: Center(
        child: Text(
          initials(displayName).substring(0, 1),
          style: TextStyle(
            color: Colors.black,
            fontSize: size * .43,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
    final Widget image;
    if (avatarFile != null) {
      image = Image.file(
        avatarFile!,
        key: ValueKey('local-avatar-${avatarFile!.path}-$avatarRevision'),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback(),
      );
    } else if (avatarUri != null) {
      image = Image.network(
        avatarUri.toString(),
        headers: avatarToken == null
            ? null
            : {HttpHeaders.authorizationHeader: 'Bearer $avatarToken'},
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback(),
      );
    } else {
      image = fallback();
    }
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: borderRadius ?? BorderRadius.circular(size / 2),
        child: image,
      ),
    );
  }
}

class OsProfilePreview extends StatelessWidget {
  const OsProfilePreview({
    super.key,
    required this.displayName,
    this.avatarFile,
    this.avatarUri,
    this.avatarToken,
    this.onChooseAvatar,
  });

  final String displayName;
  final File? avatarFile;
  final Uri? avatarUri;
  final String? avatarToken;
  final VoidCallback? onChooseAvatar;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF303653), Color(0xFF2B2E34)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF444B72)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: OsUserAvatar(
              displayName: displayName,
              size: 144,
              avatarFile: avatarFile,
              avatarUri: avatarUri,
              avatarToken: avatarToken,
              borderRadius: BorderRadius.circular(15),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: OsColors.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  avatarFile != null || avatarUri != null
                      ? '已设置自定义头像'
                      : '尚未设置头像',
                  style: const TextStyle(
                    color: OsColors.dim,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (onChooseAvatar != null) ...[
            const SizedBox(width: 10),
            OsSecondaryButton(label: '选择图片', onPressed: onChooseAvatar!),
          ],
        ],
      ),
    );
  }
}

class OsFormCard extends StatelessWidget {
  const OsFormCard({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: OsColors.panelRaised,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: OsColors.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: OsColors.blurple, size: 18),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: OsColors.text,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          child,
        ],
      ),
    );
  }
}

String auditActionLabel(String action) => switch (action) {
  'permissions.updated' => '修改服务器权限',
  'member.kicked' => '踢出成员',
  'member.banned' => '封禁成员',
  'member.unbanned' => '解除封禁',
  'member.mute' => '强制成员静音',
  'member.deafen' => '强制成员停止收听',
  'member.role_updated' => '修改成员角色',
  'message.deleted_by_moderator' => '删除他人消息',
  'channel.deleted' => '删除频道',
  _ => action,
};

class OsAuditLogPage extends StatefulWidget {
  const OsAuditLogPage({
    super.key,
    required this.api,
    required this.token,
    required this.serverId,
  });

  final OpenSpeakApi api;
  final String token;
  final String serverId;

  @override
  State<OsAuditLogPage> createState() => _OsAuditLogPageState();
}

class _OsAuditLogPageState extends State<OsAuditLogPage> {
  late final Future<List<AuditLogEntry>> entries = widget.api.listAuditLogs(
    widget.token,
    widget.serverId,
  );

  @override
  Widget build(BuildContext context) => OsSettingsPage(
    icon: Icons.history_rounded,
    title: '审计日志',
    subtitle: '最近 100 条服务器管理记录。',
    child: FutureBuilder<List<AuditLogEntry>>(
      future: entries,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        if (snapshot.hasError) {
          return Text(
            '${snapshot.error}',
            style: const TextStyle(color: OsColors.danger),
          );
        }
        final values = snapshot.data ?? const [];
        if (values.isEmpty) {
          return const Text('暂无审计记录', style: TextStyle(color: OsColors.dim));
        }
        return Column(
          children: [
            for (var index = 0; index < values.length; index++) ...[
              OsSettingsTile(
                icon: Icons.receipt_long_outlined,
                title: auditActionLabel(values[index].action),
                subtitle: [
                  if (values[index].actorUserId.isNotEmpty)
                    '操作者 ${values[index].actorUserId}',
                  if (values[index].targetId.isNotEmpty)
                    '目标 ${values[index].targetId}',
                  if (values[index].createdAt != null)
                    values[index].createdAt!.toLocal().toString(),
                ].join(' · '),
                enabled: false,
              ),
              if (index + 1 < values.length) const SizedBox(height: 8),
            ],
          ],
        );
      },
    ),
  );
}

class ServerPermissionDefinition {
  const ServerPermissionDefinition(this.key, this.title, this.subtitle);

  final String key;
  final String title;
  final String subtitle;
}

class ServerPermissionCategory {
  const ServerPermissionCategory(this.title, this.icon, this.permissions);

  final String title;
  final IconData icon;
  final List<ServerPermissionDefinition> permissions;
}

const serverPermissionCategories = <ServerPermissionCategory>[
  ServerPermissionCategory('服务器管理', Icons.dns_outlined, [
    ServerPermissionDefinition(
      'server.profile.update',
      '修改服务器资料',
      '修改服务器昵称、头像',
    ),
    ServerPermissionDefinition(
      'server.settings.update',
      '修改服务器常规设置',
      '默认频道、历史保留时间、服务器密码等',
    ),
    ServerPermissionDefinition(
      'server.transport.update',
      '修改传输与安全',
      '加密类型、附件承载、屏幕共享中转方式',
    ),
    ServerPermissionDefinition('audit.view', '查看审计日志', '查看封禁、踢出、权限修改等记录'),
  ]),
  ServerPermissionCategory('频道管理', Icons.tag_rounded, [
    ServerPermissionDefinition('channel.create', '创建频道', '创建普通频道'),
    ServerPermissionDefinition('channel.edit', '编辑频道', '修改频道名称'),
    ServerPermissionDefinition('channel.delete', '删除频道', '删除频道及其中的历史内容'),
    ServerPermissionDefinition('channel.reorder', '调整频道顺序', '拖动频道调整显示顺序'),
  ]),
  ServerPermissionCategory('用户管理', Icons.group_outlined, [
    ServerPermissionDefinition('member.view', '查看成员管理', '查看历史成员、在线状态和黑名单'),
    ServerPermissionDefinition('member.move', '拖动用户到不同频道', '包括移入和移出语音频道'),
    ServerPermissionDefinition('member.kick', '踢出用户', '断开用户当前连接，不加入黑名单'),
    ServerPermissionDefinition('member.ban', '封禁用户', '加入黑名单并断开连接'),
    ServerPermissionDefinition('member.unban', '解除封禁', '从黑名单移除'),
    ServerPermissionDefinition('member.mute', '强制用户静音', '临时关闭用户的麦克风，用户可自行解除'),
    ServerPermissionDefinition(
      'member.deafen',
      '强制用户停止收听',
      '临时关闭收听并静音，用户可自行解除',
    ),
  ]),
  ServerPermissionCategory('聊天与内容', Icons.chat_bubble_outline_rounded, [
    ServerPermissionDefinition(
      'channel.messages.view',
      '查看频道消息',
      '查看频道聊天和历史记录',
    ),
    ServerPermissionDefinition(
      'channel.messages.send_text',
      '发送文字',
      '发送普通文字消息',
    ),
    ServerPermissionDefinition('channel.messages.send_image', '发送图片', '上传图片附件'),
    ServerPermissionDefinition('channel.messages.send_file', '发送文件', '上传非图片文件'),
    ServerPermissionDefinition(
      'channel.attachments.download',
      '下载附件',
      '下载频道中的图片和文件',
    ),
    ServerPermissionDefinition(
      'channel.messages.manage',
      '管理他人消息',
      '删除其他成员发送的消息',
    ),
  ]),
  ServerPermissionCategory('语音与媒体', Icons.headset_mic_outlined, [
    ServerPermissionDefinition('voice.join', '加入语音频道', '进入语音频道'),
    ServerPermissionDefinition('voice.speak', '发送语音', '发布麦克风音频'),
    ServerPermissionDefinition(voiceScreenSharePermission, '屏幕共享', '发起屏幕共享'),
    ServerPermissionDefinition(
      'voice.screen_share.resolution.720p',
      '720p',
      '允许选择 1280×720',
    ),
    ServerPermissionDefinition(
      'voice.screen_share.resolution.1080p',
      '1080p',
      '允许选择 1920×1080',
    ),
    ServerPermissionDefinition(
      'voice.screen_share.resolution.source',
      'Source',
      '允许保留来源原始分辨率',
    ),
    ServerPermissionDefinition(
      'voice.screen_share.fps.15',
      '15 FPS',
      '适合文档、代码和静态内容',
    ),
    ServerPermissionDefinition(
      'voice.screen_share.fps.30',
      '30 FPS',
      '适合日常操作和多数演示',
    ),
    ServerPermissionDefinition(
      'voice.screen_share.fps.60',
      '60 FPS',
      '适合高动态内容',
    ),
    ServerPermissionDefinition('voice.bypass_limit', '绕过频道人数限制', '频道已满时仍可进入'),
  ]),
  ServerPermissionCategory('私聊权限', Icons.forum_outlined, [
    ServerPermissionDefinition('direct.send_text', '发起私聊', '向其他成员发送临时文字消息'),
    ServerPermissionDefinition('direct.send_image', '私聊发送图片', '发送临时图片'),
    ServerPermissionDefinition('direct.send_file', '私聊发送文件', '发送临时文件'),
  ]),
];

String? screenSharePermissionGroupLabel(String permission) {
  if (permission == 'voice.screen_share.resolution.720p') {
    return '屏幕共享可选分辨率';
  }
  if (permission == 'voice.screen_share.fps.15') {
    return '屏幕共享可选帧率';
  }
  return null;
}

bool screenSharePermissionInteractive(
  Set<String> permissions,
  String permission,
) {
  final group = permission.startsWith('voice.screen_share.resolution.')
      ? screenShareResolutionPermissions.values
      : permission.startsWith('voice.screen_share.fps.')
      ? screenShareFPSPermissions.values
      : null;
  if (group == null) return true;
  if (!permissions.contains(voiceScreenSharePermission)) return false;
  if (!permissions.contains(permission)) return true;
  return group.where(permissions.contains).length > 1;
}

class OsServerPermissionsPage extends StatelessWidget {
  const OsServerPermissionsPage({
    super.key,
    required this.adminPermissions,
    required this.userPermissions,
    required this.messageRetractWindowMinutes,
    required this.onChanged,
    required this.onMessageRetractWindowChanged,
    required this.onSave,
  });

  final Set<String> adminPermissions;
  final Set<String> userPermissions;
  final int messageRetractWindowMinutes;
  final void Function(String role, String permission, bool enabled) onChanged;
  final ValueChanged<int> onMessageRetractWindowChanged;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return OsSettingsPage(
      icon: Icons.admin_panel_settings_outlined,
      title: '服务器权限管理',
      subtitle: '设置服务器管理员与服务器成员的服务器级权限；你作为服务器拥有者，始终拥有全部权限。',
      footer: Align(
        alignment: Alignment.centerRight,
        child: OsPrimaryButton(
          label: '保存更改',
          icon: Icons.check_rounded,
          onPressed: onSave,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _PermissionColumnHeader(),
          const SizedBox(height: 10),
          for (
            var index = 0;
            index < serverPermissionCategories.length;
            index++
          ) ...[
            _PermissionCategoryCard(
              category: serverPermissionCategories[index],
              adminPermissions: adminPermissions,
              userPermissions: userPermissions,
              onChanged: onChanged,
            ),
            if (index != serverPermissionCategories.length - 1)
              const SizedBox(height: 12),
          ],
          const SizedBox(height: 12),
          const OsFormCard(
            icon: Icons.lock_rounded,
            title: '服务器拥有者专属权限',
            child: Text(
              '修改服务器管理员或服务器成员权限、修改成员角色、添加或撤销拥有者设备、生成设备配对码、转移或删除服务器、执行所有权恢复等能力不能下发。',
              style: TextStyle(color: OsColors.dim, fontSize: 11, height: 1.5),
            ),
          ),
          const SizedBox(height: 12),
          OsFormCard(
            icon: Icons.verified_user_outlined,
            title: '固定成员能力',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '所有成员都能在时限内撤回自己的消息；拥有“管理他人消息”权限的用户不受此限制。',
                  style: TextStyle(
                    color: OsColors.dim,
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: messageRetractWindowMinutes,
                  decoration: const InputDecoration(labelText: '撤回消息时限'),
                  items: const [
                    DropdownMenuItem(value: 5, child: Text('5 分钟')),
                    DropdownMenuItem(value: 15, child: Text('15 分钟')),
                    DropdownMenuItem(value: 30, child: Text('30 分钟')),
                    DropdownMenuItem(value: 60, child: Text('1 小时')),
                    DropdownMenuItem(value: 180, child: Text('3 小时')),
                    DropdownMenuItem(value: 1440, child: Text('24 小时')),
                    DropdownMenuItem(value: 10080, child: Text('7 天')),
                  ],
                  onChanged: (value) {
                    if (value != null) onMessageRetractWindowChanged(value);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionColumnHeader extends StatelessWidget {
  const _PermissionColumnHeader();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(right: 12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            '可下发权限',
            style: TextStyle(color: OsColors.text, fontWeight: FontWeight.w900),
          ),
        ),
        SizedBox(
          width: 96,
          child: Center(
            child: Text(
              '服务器管理员',
              style: TextStyle(
                color: OsColors.dim,
                fontSize: 9,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
        SizedBox(
          width: 96,
          child: Center(
            child: Text(
              '服务器成员',
              style: TextStyle(
                color: OsColors.dim,
                fontSize: 9,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _PermissionCategoryCard extends StatelessWidget {
  const _PermissionCategoryCard({
    required this.category,
    required this.adminPermissions,
    required this.userPermissions,
    required this.onChanged,
  });

  final ServerPermissionCategory category;
  final Set<String> adminPermissions;
  final Set<String> userPermissions;
  final void Function(String role, String permission, bool enabled) onChanged;

  @override
  Widget build(BuildContext context) => OsFormCard(
    icon: category.icon,
    title: category.title,
    child: Column(
      children: [
        for (var index = 0; index < category.permissions.length; index++) ...[
          if (screenSharePermissionGroupLabel(category.permissions[index].key)
              case final label?) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 3),
                child: Text(
                  label,
                  style: const TextStyle(
                    color: OsColors.dim,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          ],
          _PermissionRow(
            permission: category.permissions[index],
            adminEnabled: adminPermissions.contains(
              category.permissions[index].key,
            ),
            userEnabled: userPermissions.contains(
              category.permissions[index].key,
            ),
            adminInteractive: screenSharePermissionInteractive(
              adminPermissions,
              category.permissions[index].key,
            ),
            userInteractive: screenSharePermissionInteractive(
              userPermissions,
              category.permissions[index].key,
            ),
            onChanged: onChanged,
          ),
          if (index != category.permissions.length - 1)
            const Divider(height: 1, color: OsColors.panelBorder),
        ],
      ],
    ),
  );
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.permission,
    required this.adminEnabled,
    required this.userEnabled,
    required this.adminInteractive,
    required this.userInteractive,
    required this.onChanged,
  });

  final ServerPermissionDefinition permission;
  final bool adminEnabled;
  final bool userEnabled;
  final bool adminInteractive;
  final bool userInteractive;
  final void Function(String role, String permission, bool enabled) onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                permission.title,
                style: const TextStyle(
                  color: OsColors.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                permission.subtitle,
                style: const TextStyle(color: OsColors.dim, fontSize: 10),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 96,
          child: Checkbox(
            value: adminEnabled,
            onChanged: adminInteractive
                ? (value) => onChanged('admin', permission.key, value ?? false)
                : null,
          ),
        ),
        SizedBox(
          width: 96,
          child: Checkbox(
            value: userEnabled,
            onChanged: userInteractive
                ? (value) => onChanged('user', permission.key, value ?? false)
                : null,
          ),
        ),
      ],
    ),
  );
}

class OsServerSummary extends StatelessWidget {
  const OsServerSummary({
    super.key,
    required this.encryptionMode,
    required this.externalAttachments,
    required this.isOwner,
  });

  final String encryptionMode;
  final bool externalAttachments;
  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: BoxDecoration(
        color: OsColors.blurpleSoft,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFF444B72)),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, color: Color(0xFF9DA6FF), size: 21),
          const SizedBox(width: 11),
          Expanded(
            child: Wrap(
              spacing: 16,
              runSpacing: 5,
              children: [
                Text(
                  '加密  ${encryptionMode.toUpperCase()}',
                  style: const TextStyle(color: OsColors.muted, fontSize: 12),
                ),
                Text(
                  externalAttachments ? '外部附件已启用' : '附件由本机承载',
                  style: const TextStyle(color: OsColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: isOwner
                  ? const Color(0x3323A559)
                  : const Color(0xFF383C49),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              isOwner ? '所有者' : '成员',
              style: TextStyle(
                color: isOwner ? const Color(0xFF72D99A) : OsColors.dim,
                fontSize: 10,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AddServerDialog extends StatefulWidget {
  const AddServerDialog({
    super.key,
    required this.addressController,
    required this.portController,
    required this.passwordController,
    this.editing = false,
    this.scheme = 'http',
  });

  final TextEditingController addressController;
  final TextEditingController portController;
  final TextEditingController passwordController;
  final bool editing;
  final String scheme;

  @override
  State<AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends State<AddServerDialog> {
  String? validationError;

  void submit() {
    final host = cleanServerHost(widget.addressController.text);
    final port = widget.portController.text.trim();
    final password = widget.passwordController.text;
    final parsedPort = int.tryParse(port);
    if (host.isEmpty) {
      setState(() {
        validationError = '服务器地址不能为空';
      });
      return;
    }
    if (parsedPort == null || parsedPort <= 0 || parsedPort > 65535) {
      setState(() {
        validationError = '端口需要填写 1-65535 之间的数字';
      });
      return;
    }
    final url = serverConnectionUrl(
      host: host,
      port: parsedPort,
      previousScheme: widget.scheme,
    );
    final name = '$host:$parsedPort';
    final id = url.toLowerCase();
    Navigator.of(context).pop(
      SavedServerConnection(id: id, name: name, url: url, password: password),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 478),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: OsColors.content,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: OsColors.panelBorder),
            boxShadow: const [
              BoxShadow(
                color: Color(0x99000000),
                blurRadius: 32,
                offset: Offset(0, 18),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Stack(
              children: [
                const Positioned(
                  left: -96,
                  top: -120,
                  child: _DialogGlow(size: 230, color: Color(0x335865F2)),
                ),
                const Positioned(
                  right: -88,
                  bottom: -130,
                  child: _DialogGlow(size: 220, color: Color(0x2223A559)),
                ),
                SmoothSingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [OsColors.blurple, Color(0xFF4752C4)],
                                ),
                                borderRadius: BorderRadius.circular(18),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x665865F2),
                                    blurRadius: 16,
                                    offset: Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.dns_rounded,
                                color: Colors.white,
                                size: 26,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.editing ? '编辑服务器' : '添加服务器',
                                    style: TextStyle(
                                      color: OsColors.text,
                                      fontSize: 28,
                                      height: 1.08,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  SizedBox(height: 8),
                                  Text(
                                    widget.editing
                                        ? '修改保存在左侧服务器列表中的连接信息。'
                                        : '保存到左侧服务器列表，并立即连接到这个 OpenSpeak 服务器。',
                                    style: TextStyle(
                                      color: OsColors.dim,
                                      fontSize: 13,
                                      height: 1.35,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Tooltip(
                              message: '取消',
                              child: IconButton(
                                onPressed: () => Navigator.of(context).pop(),
                                visualDensity: VisualDensity.compact,
                                style: IconButton.styleFrom(
                                  backgroundColor: const Color(0xFF2A2C31),
                                  foregroundColor: OsColors.muted,
                                  fixedSize: const Size(34, 34),
                                  minimumSize: const Size(34, 34),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                icon: const Icon(Icons.close_rounded, size: 18),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 22),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final compact = constraints.maxWidth < 390;
                            final addressField = _AddServerTextField(
                              controller: widget.addressController,
                              label: '服务器地址',
                              hintText: '服务器域名 或 ip',
                              icon: Icons.link_rounded,
                              keyboardType: TextInputType.url,
                              onSubmitted: (_) => submit(),
                            );
                            final portField = _AddServerTextField(
                              controller: widget.portController,
                              label: '端口',
                              hintText: '27410',
                              icon: Icons.tag_rounded,
                              keyboardType: TextInputType.number,
                              onSubmitted: (_) => submit(),
                            );
                            if (compact) {
                              return Column(
                                children: [
                                  addressField,
                                  const SizedBox(height: 12),
                                  portField,
                                ],
                              );
                            }
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(flex: 7, child: addressField),
                                const SizedBox(width: 12),
                                Expanded(flex: 3, child: portField),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                        _AddServerTextField(
                          controller: widget.passwordController,
                          label: '密码（如果有）',
                          hintText: '没有密码可以留空',
                          icon: Icons.lock_outline_rounded,
                          onSubmitted: (_) => submit(),
                        ),
                        if (validationError != null) ...[
                          const SizedBox(height: 14),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 13,
                              vertical: 11,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF3C252A),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0x66ED4245),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.error_outline_rounded,
                                  color: Color(0xFFFFB7B7),
                                  size: 18,
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Text(
                                    validationError!,
                                    style: const TextStyle(
                                      color: Color(0xFFFFD7D7),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 22),
                        Row(
                          children: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              style: TextButton.styleFrom(
                                foregroundColor: OsColors.muted,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 12,
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              child: const Text('取消'),
                            ),
                            const Spacer(),
                            FilledButton.icon(
                              onPressed: submit,
                              style: FilledButton.styleFrom(
                                backgroundColor: OsColors.blurple,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              icon: const Icon(Icons.login_rounded, size: 18),
                              label: Text(widget.editing ? '保存更改' : '添加并连接'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DialogGlow extends StatelessWidget {
  const _DialogGlow({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: color, blurRadius: size / 2, spreadRadius: 20),
          ],
        ),
      ),
    );
  }
}

class _AddServerTextField extends StatelessWidget {
  const _AddServerTextField({
    required this.controller,
    required this.label,
    required this.hintText,
    required this.icon,
    this.keyboardType,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final String hintText;
  final IconData icon;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 7),
          child: Text(
            label,
            style: const TextStyle(
              color: OsColors.muted,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          onSubmitted: onSubmitted,
          style: const TextStyle(
            color: OsColors.text,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
          cursorColor: OsColors.blurple,
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: const TextStyle(
              color: Color(0xFF6F767F),
              fontWeight: FontWeight.w600,
            ),
            prefixIcon: Icon(icon, color: OsColors.dim, size: 20),
            filled: true,
            fillColor: const Color(0xFF232428),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 17,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF24262B)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: OsColors.blurple, width: 1.4),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }
}

class OsTextField extends StatelessWidget {
  const OsTextField({
    super.key,
    required this.controller,
    required this.label,
    this.obscureText = false,
  });

  final TextEditingController controller;
  final String label;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: OsColors.app,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.chat_bubble_outline, color: OsColors.icon, size: 38),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(color: OsColors.muted)),
        ],
      ),
    );
  }
}

class DropUploadOverlay extends StatelessWidget {
  const DropUploadOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xAA202225),
        border: Border.all(color: OsColors.green, width: 2),
      ),
      child: const Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Color(0xFF232327),
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.upload_file, color: OsColors.green, size: 26),
                SizedBox(width: 10),
                Text(
                  '松开以上传文件',
                  style: TextStyle(
                    color: OsColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

ScrollPhysics? get smoothWheelChildPhysics =>
    defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS
    ? null
    : const NeverScrollableScrollPhysics();

double smoothWheelNextPixels({
  required double current,
  required double target,
  required double elapsedSeconds,
}) {
  final alpha = 1 - math.exp(-elapsedSeconds / 0.045);
  return current + (target - current) * alpha;
}

class SmoothListView extends StatefulWidget {
  const SmoothListView({super.key, required this.children, this.padding});

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  State<SmoothListView> createState() => _SmoothListViewState();
}

class _SmoothListViewState extends State<SmoothListView> {
  final controller = ScrollController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SmoothWheelScroll(
      controller: controller,
      child: ListView(
        controller: controller,
        physics: smoothWheelChildPhysics,
        padding: widget.padding,
        children: widget.children,
      ),
    );
  }
}

class SmoothSingleChildScrollView extends StatefulWidget {
  const SmoothSingleChildScrollView({
    super.key,
    required this.child,
    this.padding,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  State<SmoothSingleChildScrollView> createState() =>
      _SmoothSingleChildScrollViewState();
}

class _SmoothSingleChildScrollViewState
    extends State<SmoothSingleChildScrollView> {
  final controller = ScrollController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SmoothWheelScroll(
      controller: controller,
      child: SingleChildScrollView(
        controller: controller,
        physics: smoothWheelChildPhysics,
        padding: widget.padding,
        child: widget.child,
      ),
    );
  }
}

class SmoothWheelScroll extends StatefulWidget {
  const SmoothWheelScroll({
    super.key,
    required this.controller,
    required this.child,
    this.reverse = false,
  });

  final ScrollController controller;
  final Widget child;
  final bool reverse;

  @override
  State<SmoothWheelScroll> createState() => _SmoothWheelScrollState();
}

class _SmoothWheelScrollState extends State<SmoothWheelScroll> {
  double? _targetPixels;
  late final Ticker _ticker;
  Duration? _lastTick;

  @override
  void initState() {
    super.initState();
    _ticker = Ticker(_tick);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      if (resolved is! PointerScrollEvent) return;
      final controller = widget.controller;
      if (!controller.hasClients) return;
      final position = controller.position;
      final rawDelta = resolved.scrollDelta.dy;
      final delta = widget.reverse ? -rawDelta : rawDelta;
      if (delta == 0) return;
      final base =
          _targetPixels?.clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ) ??
          position.pixels;
      final target = (base + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((target - position.pixels).abs() < 0.5) {
        resolved.respond(allowPlatformDefault: false);
        return;
      }
      _targetPixels = target;
      if (delta.abs() < 18) {
        controller.jumpTo(target);
        _targetPixels = null;
      } else {
        _startTicker();
      }
      resolved.respond(allowPlatformDefault: false);
    });
  }

  void _startTicker() {
    _lastTick = null;
    if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final controller = widget.controller;
    final target = _targetPixels;
    if (!controller.hasClients || target == null) {
      _ticker.stop();
      _lastTick = null;
      return;
    }
    final position = controller.position;
    final current = position.pixels;
    final clampedTarget = target
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    final distance = clampedTarget - current;
    if (distance.abs() < 0.5) {
      controller.jumpTo(clampedTarget);
      _targetPixels = null;
      _ticker.stop();
      _lastTick = null;
      return;
    }

    final previous = _lastTick;
    _lastTick = elapsed;
    final seconds = previous == null
        ? 1 / 120
        : (elapsed - previous).inMicroseconds / Duration.microsecondsPerSecond;
    final next = smoothWheelNextPixels(
      current: current,
      target: clampedTarget,
      elapsedSeconds: seconds,
    ).clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
    if ((next - current).abs() < 0.25) {
      controller.jumpTo(clampedTarget);
      _targetPixels = null;
      _ticker.stop();
      _lastTick = null;
      return;
    }
    controller.jumpTo(next);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(onPointerSignal: _handlePointerSignal, child: widget.child);
  }
}

class ChatMessageEntry extends StatelessWidget {
  const ChatMessageEntry({
    super.key,
    required this.sentAt,
    required this.previousSentAt,
    required this.child,
  });

  final DateTime? sentAt;
  final DateTime? previousSentAt;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (startsNewLocalDay(sentAt, previousSentAt))
          ChatDateDivider(date: sentAt!),
        child,
      ],
    );
  }
}

class ChatDateDivider extends StatelessWidget {
  const ChatDateDivider({super.key, required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          const Expanded(
            child: Divider(height: 1, thickness: 1, color: OsColors.dim),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              localDateLabel(date),
              style: const TextStyle(color: OsColors.dim, fontSize: 11),
            ),
          ),
          const Expanded(
            child: Divider(height: 1, thickness: 1, color: OsColors.dim),
          ),
        ],
      ),
    );
  }
}

class ChatMessageRemovalNotice extends StatelessWidget {
  const ChatMessageRemovalNotice({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Center(
      child: Text(
        text,
        style: const TextStyle(color: OsColors.dim, fontSize: 11),
      ),
    ),
  );
}

class ChatMessageRow extends StatelessWidget {
  const ChatMessageRow({
    super.key,
    required this.body,
    required this.attachment,
    this.attachmentDownloadsEnabled = true,
    required this.sentAt,
    required this.senderName,
    required this.mine,
    this.avatarFile,
    this.avatarRevision = 0,
    this.avatarUri,
    this.avatarToken,
    required this.ensureCached,
    required this.loadImagePreview,
    required this.loadAudioMetadata,
    required this.linkPreviewFallback,
    required this.linkPreviewFuture,
    required this.onOpen,
    required this.onSaveAs,
    required this.onOpenLink,
    required this.downloadTask,
    required this.onCancelDownload,
    required this.activeAudioFileId,
    required this.audioLoadingFileId,
    required this.audioPlaying,
    required this.audioPosition,
    required this.audioDuration,
    required this.onToggleAudio,
    required this.onSeekAudio,
    this.messageActionLabel,
    this.onMessageAction,
    this.onMessageContextMenu,
  });

  final String body;
  final ChatAttachment? attachment;
  final bool attachmentDownloadsEnabled;
  final DateTime? sentAt;
  final String senderName;
  final bool mine;
  final File? avatarFile;
  final int avatarRevision;
  final Uri? avatarUri;
  final String? avatarToken;
  final Future<File> Function(ChatAttachment attachment) ensureCached;
  final Future<CachedImagePreview> Function(ChatAttachment attachment)
  loadImagePreview;
  final Future<AudioAttachmentMetadata> Function(ChatAttachment attachment)
  loadAudioMetadata;
  final LinkPreview? linkPreviewFallback;
  final Future<LinkPreview?>? linkPreviewFuture;
  final Future<void> Function(ChatAttachment attachment) onOpen;
  final Future<void> Function(ChatAttachment attachment) onSaveAs;
  final Future<void> Function(String url) onOpenLink;
  final TransferTask? downloadTask;
  final void Function(ChatAttachment attachment) onCancelDownload;
  final String? activeAudioFileId;
  final String? audioLoadingFileId;
  final bool audioPlaying;
  final Duration audioPosition;
  final Duration audioDuration;
  final Future<void> Function(ChatAttachment attachment) onToggleAudio;
  final Future<void> Function(Duration position) onSeekAudio;
  final String? messageActionLabel;
  final VoidCallback? onMessageAction;
  final void Function(Offset position)? onMessageContextMenu;

  Future<void> _showTextBubbleContextMenu(
    BuildContext context,
    Offset position,
  ) async {
    final hasAction = messageActionLabel != null && onMessageAction != null;
    final selected = await showOsCompactContextMenu(context, position, [
      '复制',
      if (hasAction) messageActionLabel!,
    ]);
    if (selected == 0) {
      await Clipboard.setData(ClipboardData(text: body));
    } else if (selected == 1 && hasAction) {
      onMessageAction!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final avatar = ChatAvatar(
      name: senderName,
      mine: mine,
      avatarFile: avatarFile,
      avatarRevision: avatarRevision,
      avatarUri: avatarUri,
      avatarToken: avatarToken,
    );
    final currentAttachment = attachment;
    final imageAttachment =
        currentAttachment != null && currentAttachment.isImage;
    final audioAttachment =
        currentAttachment != null && currentAttachment.isAudio;
    final header = Row(
      mainAxisSize: MainAxisSize.min,
      textDirection: mine ? TextDirection.rtl : TextDirection.ltr,
      children: [
        Flexible(
          child: Text(
            senderName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: OsColors.text,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          shortTime(sentAt),
          style: const TextStyle(color: OsColors.dim, fontSize: 11),
        ),
      ],
    );
    final content = currentAttachment != null && !attachmentDownloadsEnabled
        ? Container(
            constraints: const BoxConstraints(maxWidth: 360),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: mine ? const Color(0xFF3E4559) : const Color(0xFF232327),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2B2B30)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline_rounded, color: OsColors.dim),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    '${currentAttachment.displayName}\n没有下载附件的权限',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: OsColors.muted, height: 1.35),
                  ),
                ),
              ],
            ),
          )
        : imageAttachment
        ? ImageAttachmentPreview(
            key: ValueKey(currentAttachment.fileId),
            attachment: currentAttachment,
            loadPreview: loadImagePreview,
            onOpen: () => onOpen(currentAttachment),
            onSaveAs: () => onSaveAs(currentAttachment),
            showDetails: false,
          )
        : audioAttachment
        ? AudioAttachmentCard(
            attachment: currentAttachment,
            metadataFuture: loadAudioMetadata(currentAttachment),
            active: activeAudioFileId == currentAttachment.fileId,
            loading: audioLoadingFileId == currentAttachment.fileId,
            playing:
                activeAudioFileId == currentAttachment.fileId && audioPlaying,
            position: activeAudioFileId == currentAttachment.fileId
                ? audioPosition
                : Duration.zero,
            duration: activeAudioFileId == currentAttachment.fileId
                ? audioDuration
                : Duration.zero,
            transferTask: downloadTask,
            onToggle: () => onToggleAudio(currentAttachment),
            onSeek: onSeekAudio,
            onSaveAs: () => onSaveAs(currentAttachment),
            onCancel: () => onCancelDownload(currentAttachment),
          )
        : Container(
            constraints: BoxConstraints(
              maxWidth: linkPreviewFallback == null ? 520 : 430,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: mine ? const Color(0xFF3E4559) : const Color(0xFF232327),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2B2B30)),
            ),
            child: currentAttachment == null
                ? Column(
                    crossAxisAlignment: mine
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MessageBodyText(
                        body: body,
                        mine: mine,
                        onOpenLink: onOpenLink,
                        messageActionLabel: messageActionLabel,
                        onMessageAction: onMessageAction,
                      ),
                      LinkPreviewSlot(
                        fallbackPreview: linkPreviewFallback,
                        previewFuture: linkPreviewFuture,
                        onOpen: onOpenLink,
                      ),
                    ],
                  )
                : AttachmentBubble(
                    attachment: currentAttachment,
                    ensureCached: ensureCached,
                    onOpen: () => onOpen(currentAttachment),
                    onSaveAs: () => onSaveAs(currentAttachment),
                    transferTask: downloadTask,
                    onCancel: () => onCancelDownload(currentAttachment),
                  ),
          );

    final bubbleContextMenu = currentAttachment == null
        ? (Offset position) =>
              unawaited(_showTextBubbleContextMenu(context, position))
        : onMessageContextMenu;
    final bubble = Flexible(
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: 5),
          GestureDetector(
            key: const ValueKey('chat-message-bubble-context-target'),
            behavior: HitTestBehavior.opaque,
            onSecondaryTapUp: bubbleContextMenu == null
                ? null
                : (details) => bubbleContextMenu(details.globalPosition),
            child: content,
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: mine
            ? [bubble, const SizedBox(width: 12), avatar]
            : [avatar, const SizedBox(width: 12), bubble],
      ),
    );
  }
}

class MessageBodyText extends StatelessWidget {
  const MessageBodyText({
    super.key,
    required this.body,
    required this.mine,
    required this.onOpenLink,
    this.messageActionLabel,
    this.onMessageAction,
  });

  final String body;
  final bool mine;
  final Future<void> Function(String url) onOpenLink;
  final String? messageActionLabel;
  final VoidCallback? onMessageAction;

  @override
  Widget build(BuildContext context) {
    const baseStyle = TextStyle(
      color: OsColors.text,
      fontSize: 14,
      height: 1.28,
    );
    const linkStyle = TextStyle(
      color: Color(0xFFB9D1FF),
      decoration: TextDecoration.underline,
      decorationColor: Color(0xFFB9D1FF),
      fontSize: 14,
      height: 1.28,
    );
    final matches = previewableUrlMatches(body).toList(growable: false);
    if (matches.isEmpty) {
      return _MessagePlainText(
        body,
        textAlign: mine ? TextAlign.right : TextAlign.left,
        style: baseStyle,
        messageActionLabel: messageActionLabel,
        onMessageAction: onMessageAction,
      );
    }

    var offset = 0;
    final spans = <InlineSpan>[];
    for (final match in matches) {
      if (match.start > offset) {
        spans.add(TextSpan(text: body.substring(offset, match.start)));
      }
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(onOpenLink(match.url)),
              child: Text(match.text, style: linkStyle),
            ),
          ),
        ),
      );
      offset = match.end;
    }
    if (offset < body.length) {
      spans.add(TextSpan(text: body.substring(offset)));
    }

    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
      textAlign: mine ? TextAlign.right : TextAlign.left,
    );
  }
}

class _MessagePlainText extends StatefulWidget {
  const _MessagePlainText(
    this.text, {
    required this.textAlign,
    required this.style,
    this.messageActionLabel,
    this.onMessageAction,
  });

  final String text;
  final TextAlign textAlign;
  final TextStyle style;
  final String? messageActionLabel;
  final VoidCallback? onMessageAction;

  @override
  State<_MessagePlainText> createState() => _MessagePlainTextState();
}

class _MessagePlainTextState extends State<_MessagePlainText> {
  late final TextEditingController _controller;
  TextSelection? _selectionBeforeSecondaryTap;
  var _restoringSelection = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.text)
      ..addListener(_restoreSelectionAfterSecondaryTap);
  }

  @override
  void didUpdateWidget(covariant _MessagePlainText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) _controller.text = widget.text;
  }

  @override
  void dispose() {
    _controller.removeListener(_restoreSelectionAfterSecondaryTap);
    _controller.dispose();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.buttons == kSecondaryMouseButton) {
      _selectionBeforeSecondaryTap = _controller.selection;
    }
  }

  void _handlePointerEnd(PointerEvent event) {
    if (_selectionBeforeSecondaryTap == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _selectionBeforeSecondaryTap = null;
    });
  }

  void _restoreSelectionAfterSecondaryTap() {
    final previous = _selectionBeforeSecondaryTap;
    if (previous != null &&
        !_restoringSelection &&
        _controller.selection != previous) {
      _restoringSelection = true;
      _controller.selection = previous;
      _restoringSelection = false;
    }
  }

  Widget _buildContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    final nativeCopy = editableTextState.contextMenuButtonItems
        .where((item) => item.type == ContextMenuButtonType.copy)
        .toList(growable: false);
    final items = <ContextMenuButtonItem>[
      if (nativeCopy.isNotEmpty)
        ...osLocalizedContextMenuItems(nativeCopy)
      else
        ContextMenuButtonItem(
          onPressed: () {
            editableTextState.hideToolbar();
            unawaited(Clipboard.setData(ClipboardData(text: widget.text)));
          },
          type: ContextMenuButtonType.copy,
          label: '复制',
        ),
      if (widget.messageActionLabel != null && widget.onMessageAction != null)
        ContextMenuButtonItem(
          onPressed: () {
            editableTextState.hideToolbar();
            widget.onMessageAction!();
          },
          label: widget.messageActionLabel,
        ),
    ];
    return OsCompactTextSelectionToolbar(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: items,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (useMobileWebLayout(
      isWeb: kIsWeb,
      width: MediaQuery.sizeOf(context).width,
    )) {
      return SelectableText(
        widget.text,
        textAlign: widget.textAlign,
        style: widget.style,
        contextMenuBuilder: _buildContextMenu,
      );
    }
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerEnd,
      onPointerCancel: _handlePointerEnd,
      child: IntrinsicWidth(
        child: TextField(
          controller: _controller,
          readOnly: true,
          showCursor: false,
          maxLines: null,
          textAlign: widget.textAlign,
          style: widget.style,
          decoration: null,
          contextMenuBuilder: _buildContextMenu,
        ),
      ),
    );
  }
}

class LinkPreviewSlot extends StatelessWidget {
  const LinkPreviewSlot({
    super.key,
    required this.fallbackPreview,
    required this.previewFuture,
    required this.onOpen,
  });

  final LinkPreview? fallbackPreview;
  final Future<LinkPreview?>? previewFuture;
  final Future<void> Function(String url) onOpen;

  @override
  Widget build(BuildContext context) {
    final future = previewFuture;
    final fallback = fallbackPreview;
    if (future == null && fallback == null) return const SizedBox.shrink();
    return FutureBuilder<LinkPreview?>(
      future: future,
      builder: (context, snapshot) {
        final preview = snapshot.connectionState == ConnectionState.done
            ? snapshot.data ?? fallback
            : fallback;
        if (snapshot.hasError || preview == null || !preview.hasContent) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: LinkPreviewCard(
            preview: preview,
            onTap: () => unawaited(onOpen(preview.url)),
          ),
        );
      },
    );
  }
}

class LinkPreviewCard extends StatelessWidget {
  const LinkPreviewCard({
    super.key,
    required this.preview,
    required this.onTap,
  });

  final LinkPreview preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final imageUrl = preview.imageUrl.trim();
    final title = linkPreviewTitle(preview);
    final description = linkPreviewDescription(preview);
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        margin: const EdgeInsets.only(top: 7),
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: const Color(0xFF4A536B),
          borderRadius: BorderRadius.circular(7),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: imageUrl.isNotEmpty ? 88 : 68,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: OsColors.blurple,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title.isNotEmpty)
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: OsColors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          height: 1.18,
                        ),
                      ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        description,
                        maxLines: imageUrl.isNotEmpty ? 3 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFD6DBE8),
                          fontSize: 12.5,
                          height: 1.22,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (imageUrl.isNotEmpty) ...[
              const SizedBox(width: 8),
              LinkPreviewImage(url: imageUrl),
            ],
          ],
        ),
      ),
    );
  }
}

class LinkPreviewImage extends StatefulWidget {
  const LinkPreviewImage({super.key, required this.url});

  final String url;

  @override
  State<LinkPreviewImage> createState() => _LinkPreviewImageState();
}

class _LinkPreviewImageState extends State<LinkPreviewImage> {
  bool failed = false;

  @override
  void didUpdateWidget(LinkPreviewImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      failed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (failed) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 88,
        height: 88,
        child: Image.network(
          widget.url,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => failed = true);
            });
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }
}

class AudioSeekSlider extends StatefulWidget {
  const AudioSeekSlider({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final Future<void> Function(Duration position) onSeek;

  @override
  State<AudioSeekSlider> createState() => _AudioSeekSliderState();
}

class _AudioSeekSliderState extends State<AudioSeekSlider> {
  double? dragValue;
  var dragGeneration = 0;

  Future<void> commit(double value, int generation) async {
    try {
      await widget.onSeek(Duration(milliseconds: value.round()));
    } finally {
      if (mounted && generation == dragGeneration) {
        setState(() => dragValue = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final maximum = widget.duration.inMilliseconds <= 0
        ? 1.0
        : widget.duration.inMilliseconds.toDouble();
    final value = (dragValue ?? widget.position.inMilliseconds.toDouble())
        .clamp(0.0, maximum);
    final enabled = widget.duration > Duration.zero;
    return Slider(
      min: 0,
      max: maximum,
      value: value,
      onChangeStart: enabled
          ? (value) {
              dragGeneration += 1;
              setState(() => dragValue = value);
            }
          : null,
      onChanged: enabled ? (value) => setState(() => dragValue = value) : null,
      onChangeEnd: enabled
          ? (value) => unawaited(commit(value, dragGeneration))
          : null,
    );
  }
}

class AudioAttachmentCard extends StatelessWidget {
  const AudioAttachmentCard({
    super.key,
    required this.attachment,
    required this.metadataFuture,
    required this.active,
    required this.loading,
    required this.playing,
    required this.position,
    required this.duration,
    required this.transferTask,
    required this.onToggle,
    required this.onSeek,
    required this.onSaveAs,
    required this.onCancel,
  });

  final ChatAttachment attachment;
  final Future<AudioAttachmentMetadata> metadataFuture;
  final bool active;
  final bool loading;
  final bool playing;
  final Duration position;
  final Duration duration;
  final TransferTask? transferTask;
  final VoidCallback onToggle;
  final Future<void> Function(Duration position) onSeek;
  final VoidCallback onSaveAs;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final task = transferTask;
    if (attachment.expired) {
      return const SizedBox(
        width: 320,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, color: OsColors.danger, size: 24),
            SizedBox(width: 10),
            Text('文件已过期', style: TextStyle(color: OsColors.muted)),
          ],
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 320, maxWidth: 430),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF232327),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF2B2B30)),
        ),
        child: FutureBuilder<AudioAttachmentMetadata>(
          future: metadataFuture,
          builder: (context, snapshot) {
            final metadata =
                snapshot.data ??
                AudioAttachmentMetadata(title: attachment.displayName);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    AudioCover(bytes: metadata.coverBytes),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            metadata.title.trim().isEmpty
                                ? attachment.displayName
                                : metadata.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: OsColors.text,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            metadata.artist.trim().isEmpty
                                ? '未知艺术家'
                                : metadata.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: OsColors.dim,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            readableBytes(attachment.sizeBytes),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: OsColors.dim,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '另存为',
                      onPressed: onSaveAs,
                      icon: const Icon(Icons.download, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    IconButton.filled(
                      tooltip: playing ? '暂停' : '播放',
                      style: IconButton.styleFrom(
                        backgroundColor: OsColors.blurple,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: loading ? null : onToggle,
                      icon: loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(playing ? Icons.pause : Icons.play_arrow),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      formatDuration(active ? position : Duration.zero),
                      style: const TextStyle(
                        color: OsColors.muted,
                        fontSize: 12,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12,
                          ),
                        ),
                        child: AudioSeekSlider(
                          position: active ? position : Duration.zero,
                          duration: active ? duration : Duration.zero,
                          onSeek: onSeek,
                        ),
                      ),
                    ),
                    Text(
                      formatDuration(duration),
                      style: const TextStyle(
                        color: OsColors.muted,
                        fontSize: 12,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                if (task != null) ...[
                  const SizedBox(height: 6),
                  TransferInlineProgress(task: task),
                  if (task.status == TransferStatus.running)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: onCancel,
                        icon: const Icon(Icons.close, size: 16),
                        label: const Text('取消'),
                      ),
                    )
                  else if (task.status == TransferStatus.failed)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: onSaveAs,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('重试'),
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class AudioCover extends StatelessWidget {
  const AudioCover({super.key, required this.bytes});

  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final coverBytes = bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 58,
        height: 58,
        color: const Color(0xFF31343A),
        child: coverBytes == null
            ? const Icon(Icons.music_note, color: OsColors.muted, size: 30)
            : Image.memory(
                coverBytes,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.music_note, color: OsColors.muted),
              ),
      ),
    );
  }
}

class AttachmentBubble extends StatelessWidget {
  const AttachmentBubble({
    super.key,
    required this.attachment,
    required this.ensureCached,
    required this.onOpen,
    required this.onSaveAs,
    required this.transferTask,
    required this.onCancel,
  });

  final ChatAttachment attachment;
  final Future<File> Function(ChatAttachment attachment) ensureCached;
  final VoidCallback onOpen;
  final VoidCallback onSaveAs;
  final TransferTask? transferTask;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final expiresAt = attachment.expiresAt;
    final task = transferTask;
    if (attachment.expired) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 260, maxWidth: 360),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, color: OsColors.danger, size: 24),
            SizedBox(width: 10),
            Text(
              '文件已过期',
              style: TextStyle(
                color: OsColors.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 360),
      child: InkWell(
        onTap: onOpen,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: const Color(0xFF31343A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.insert_drive_file,
                color: OsColors.muted,
                size: 24,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    attachment.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: OsColors.text,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      '文件',
                      readableBytes(attachment.sizeBytes),
                      if (attachment.direct && expiresAt != null)
                        '${shortTime(expiresAt)} 过期',
                    ].where((item) => item.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: OsColors.dim, fontSize: 12),
                  ),
                  if (task != null) ...[
                    const SizedBox(height: 6),
                    TransferInlineProgress(task: task),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (task?.status == TransferStatus.failed)
              IconButton(
                tooltip: '重试',
                onPressed: onOpen,
                icon: const Icon(Icons.refresh, size: 20),
              )
            else if (task?.status == TransferStatus.running)
              IconButton(
                tooltip: '取消',
                onPressed: onCancel,
                icon: const Icon(Icons.close, size: 20),
              )
            else
              IconButton(
                tooltip: '另存为',
                onPressed: onSaveAs,
                icon: const Icon(Icons.download, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}

class ImageAttachmentPreview extends StatefulWidget {
  const ImageAttachmentPreview({
    super.key,
    required this.attachment,
    required this.loadPreview,
    required this.onOpen,
    required this.onSaveAs,
    this.showDetails = true,
  });

  final ChatAttachment attachment;
  final Future<CachedImagePreview> Function(ChatAttachment attachment)
  loadPreview;
  final VoidCallback onOpen;
  final VoidCallback onSaveAs;
  final bool showDetails;

  @override
  State<ImageAttachmentPreview> createState() => _ImageAttachmentPreviewState();
}

const _maxImagePreviewWidth = 420.0;
const _maxImagePreviewHeight = 360.0;

class CachedImagePreview {
  const CachedImagePreview({this.file, this.bytes, required this.size});

  final File? file;
  final Uint8List? bytes;
  final Size size;
}

class ImageLightbox extends StatelessWidget {
  const ImageLightbox({
    super.key,
    required this.preview,
    required this.onDownload,
    required this.onClose,
  });

  final Future<CachedImagePreview> preview;
  final VoidCallback onDownload;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: Colors.transparent,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: FutureBuilder<CachedImagePreview>(
              future: preview,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  );
                }
                final bytes = snapshot.data?.bytes;
                if (snapshot.hasError || bytes == null) {
                  return const Center(
                    child: Text(
                      '图片预览失败',
                      style: TextStyle(color: OsColors.muted),
                    ),
                  );
                }
                return InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: SizedBox.expand(
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) => const Center(
                        child: Text(
                          '图片预览失败',
                          style: TextStyle(color: OsColors.muted),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xCC1F2025),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0x663B3D45)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '下载',
                    onPressed: onDownload,
                    icon: const Icon(Icons.download, color: OsColors.text),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: onClose,
                    icon: const Icon(Icons.close, color: OsColors.text),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<Size> _readImageSize(File file) async {
  return _readImageSizeBytes(await file.readAsBytes());
}

Future<Size> _readImageSizeBytes(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final size = Size(image.width.toDouble(), image.height.toDouble());
  image.dispose();
  return size;
}

Size _fitImageSize({
  required Size source,
  required double maxWidth,
  required double maxHeight,
}) {
  if (maxWidth <= 0 || maxHeight <= 0) {
    return Size.zero;
  }
  if (source.width <= 0 || source.height <= 0) {
    return Size(maxWidth, maxHeight);
  }
  final aspectRatio = source.width / source.height;
  var width = source.width;
  var height = source.height;

  if (width > maxWidth) {
    width = maxWidth;
    height = width / aspectRatio;
  }
  if (height > maxHeight) {
    height = maxHeight;
    width = height * aspectRatio;
  }
  return Size(width, height);
}

class _ImageAttachmentPreviewState extends State<ImageAttachmentPreview> {
  late Future<CachedImagePreview> _imageFuture;

  @override
  void initState() {
    super.initState();
    _imageFuture = _loadImage();
  }

  @override
  void didUpdateWidget(ImageAttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.fileId != widget.attachment.fileId) {
      _imageFuture = _loadImage();
    }
  }

  Future<CachedImagePreview> _loadImage() async {
    return widget.loadPreview(widget.attachment);
  }

  @override
  Widget build(BuildContext context) {
    final expiresAt = widget.attachment.expiresAt;
    if (widget.attachment.expired) {
      return const SizedBox(
        width: 260,
        height: 120,
        child: Center(
          child: Text('文件已过期', style: TextStyle(color: OsColors.muted)),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showDetails) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.attachment.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: OsColors.text,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '另存为',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onSaveAs,
                  icon: const Icon(Icons.download, size: 18),
                ),
              ],
            ),
            Text(
              [
                '图片',
                readableBytes(widget.attachment.sizeBytes),
                if (widget.attachment.direct && expiresAt != null)
                  '${shortTime(expiresAt)} 过期',
              ].where((item) => item.isNotEmpty).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: OsColors.dim, fontSize: 12),
            ),
            const SizedBox(height: 8),
          ],
          FutureBuilder<CachedImagePreview>(
            future: _imageFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox(
                  width: 260,
                  height: 150,
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              if (snapshot.hasError || !snapshot.hasData) {
                return ImagePreviewFailure(onSaveAs: widget.onSaveAs);
              }
              final image = snapshot.data!;
              return LayoutBuilder(
                builder: (context, constraints) {
                  final maxWidth = constraints.maxWidth.isFinite
                      ? constraints.maxWidth.clamp(0.0, _maxImagePreviewWidth)
                      : _maxImagePreviewWidth;
                  final displaySize = _fitImageSize(
                    source: image.size,
                    maxWidth: maxWidth,
                    maxHeight: _maxImagePreviewHeight,
                  );
                  final cacheWidth = imagePreviewCacheWidth(
                    isWeb: kIsWeb,
                    viewportWidth: MediaQuery.sizeOf(context).width,
                    sourceWidth: image.size.width,
                    displayWidth: displaySize.width,
                    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                  );
                  return Stack(
                    children: [
                      InkWell(
                        onTap: widget.onOpen,
                        mouseCursor: SystemMouseCursors.click,
                        borderRadius: BorderRadius.circular(8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          clipBehavior: Clip.antiAlias,
                          child: SizedBox(
                            width: displaySize.width,
                            height: displaySize.height,
                            child: image.bytes != null
                                ? Image.memory(
                                    image.bytes!,
                                    width: displaySize.width,
                                    height: displaySize.height,
                                    cacheWidth: cacheWidth,
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.medium,
                                    errorBuilder: (_, _, _) =>
                                        ImagePreviewFailure(
                                          onSaveAs: widget.onSaveAs,
                                        ),
                                  )
                                : Image.file(
                                    image.file!,
                                    width: displaySize.width,
                                    height: displaySize.height,
                                    cacheWidth: cacheWidth,
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.medium,
                                    errorBuilder: (_, _, _) =>
                                        ImagePreviewFailure(
                                          onSaveAs: widget.onSaveAs,
                                        ),
                                  ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0xCC1F2025),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: const Color(0x663B3D45)),
                          ),
                          child: IconButton(
                            tooltip: '另存为',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 34,
                              height: 34,
                            ),
                            onPressed: widget.onSaveAs,
                            icon: const Icon(
                              Icons.download,
                              size: 19,
                              color: OsColors.text,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class ImagePreviewFailure extends StatelessWidget {
  const ImagePreviewFailure({super.key, required this.onSaveAs});

  final VoidCallback onSaveAs;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 260,
      height: 120,
      decoration: BoxDecoration(
        color: const Color(0xFF31343A),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.broken_image, color: OsColors.dim, size: 26),
          const SizedBox(height: 8),
          const Text('图片预览失败', style: TextStyle(color: OsColors.muted)),
          TextButton.icon(
            onPressed: onSaveAs,
            icon: const Icon(Icons.download, size: 16),
            label: const Text('另存为'),
          ),
        ],
      ),
    );
  }
}

class UploadQueuePanel extends StatelessWidget {
  const UploadQueuePanel({
    super.key,
    required this.tasks,
    required this.onCancel,
    required this.onRetry,
  });

  final List<TransferTask> tasks;
  final ValueChanged<TransferTask> onCancel;
  final ValueChanged<TransferTask> onRetry;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: SmoothSingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final task in tasks)
              TransferProgressPanel(
                task: task,
                onCancel: () => onCancel(task),
                onRetry: () => onRetry(task),
              ),
          ],
        ),
      ),
    );
  }
}

class TransferProgressPanel extends StatelessWidget {
  const TransferProgressPanel({
    super.key,
    required this.task,
    required this.onCancel,
    required this.onRetry,
  });

  final TransferTask task;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = task.status == TransferStatus.failed;
    final queued = task.status == TransferStatus.queued;
    final finishing =
        !failed &&
        task.totalBytes > 0 &&
        task.transferredBytes >= task.totalBytes;
    final subtitle = failed
        ? task.error ?? '上传失败'
        : queued
        ? '等待上传'
        : finishing
        ? '正在完成上传'
        : [
            '正在上传',
            if (task.totalBytes > 0)
              '${readableBytes(task.transferredBytes)} / ${readableBytes(task.totalBytes)}',
          ].join(' · ');
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF232327),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2B2B30)),
      ),
      child: Row(
        children: [
          Icon(
            task.image ? Icons.image : Icons.insert_drive_file,
            color: failed ? OsColors.danger : OsColors.green,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  task.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: OsColors.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: OsColors.dim, fontSize: 12),
                ),
                if (!failed && !queued) ...[
                  const SizedBox(height: 6),
                  TransferProgressBar(
                    value: task.progress,
                    color: OsColors.green,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (failed)
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
            )
          else
            IconButton(
              tooltip: '取消',
              onPressed: onCancel,
              icon: const Icon(Icons.close, size: 18),
            ),
        ],
      ),
    );
  }
}

class TransferInlineProgress extends StatelessWidget {
  const TransferInlineProgress({super.key, required this.task});

  final TransferTask task;

  @override
  Widget build(BuildContext context) {
    final failed = task.status == TransferStatus.failed;
    final progress = task.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TransferProgressBar(
          value: failed ? 1 : progress,
          color: failed ? OsColors.danger : OsColors.green,
        ),
        const SizedBox(height: 3),
        Text(
          failed
              ? '下载失败，可重试'
              : task.totalBytes > 0
              ? '下载中 ${readableBytes(task.transferredBytes)} / ${readableBytes(task.totalBytes)}'
              : '下载中',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: failed ? OsColors.danger : OsColors.dim,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class TransferProgressBar extends StatelessWidget {
  const TransferProgressBar({
    super.key,
    required this.value,
    required this.color,
  });

  final double? value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final clamped = value?.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 4,
        color: const Color(0xFF34373D),
        child: clamped == null
            ? const LinearProgressIndicator(
                minHeight: 4,
                backgroundColor: Color(0xFF34373D),
                color: OsColors.green,
              )
            : Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: clamped,
                  child: ColoredBox(
                    color: color,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
      ),
    );
  }
}

class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    required this.name,
    required this.mine,
    this.avatarFile,
    this.avatarRevision = 0,
    this.avatarUri,
    this.avatarToken,
  });

  final String name;
  final bool mine;
  final File? avatarFile;
  final int avatarRevision;
  final Uri? avatarUri;
  final String? avatarToken;

  @override
  Widget build(BuildContext context) {
    return OsUserAvatar(
      displayName: name,
      size: 36,
      avatarFile: avatarFile,
      avatarRevision: avatarRevision,
      avatarUri: avatarUri,
      avatarToken: avatarToken,
      backgroundColor: mine ? OsColors.blurple : const Color(0xFFA55CD2),
    );
  }
}

class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.enabled,
    this.readOnly = false,
    this.addEnabled,
    this.hintText,
    required this.disabledHintText,
    required this.onAdd,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool readOnly;
  final bool? addEnabled;
  final String? hintText;
  final String disabledHintText;
  final VoidCallback onAdd;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: OsColors.divider)),
      ),
      child: TextField(
        controller: controller,
        enabled: enabled,
        readOnly: readOnly,
        contextMenuBuilder: osEditableTextContextMenuBuilder,
        minLines: 1,
        maxLines: 4,
        textInputAction: TextInputAction.send,
        onEditingComplete: () {},
        onSubmitted: readOnly ? null : (_) => onSend(),
        decoration: InputDecoration(
          hintText: enabled ? hintText : disabledHintText,
          filled: true,
          fillColor: const Color(0xFF232327),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 13,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF2B2B30)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF2B2B30)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: OsColors.rowHover),
          ),
          prefixIcon: IconButton(
            tooltip: '添加文件',
            onPressed: (addEnabled ?? enabled) ? onAdd : null,
            icon: const Icon(Icons.add_circle, size: 22),
          ),
          suffixIcon: IconButton(
            tooltip: '发送',
            onPressed: enabled && !readOnly ? onSend : null,
            icon: const Icon(Icons.send, size: 20),
          ),
        ),
      ),
    );
  }
}

String shortTime(DateTime? value) {
  if (value == null) return '';
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}

bool startsNewLocalDay(DateTime? value, DateTime? previous) {
  if (value == null || previous == null) return false;
  final local = value.toLocal();
  final previousLocal = previous.toLocal();
  return local.year != previousLocal.year ||
      local.month != previousLocal.month ||
      local.day != previousLocal.day;
}

String localDateLabel(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}年${two(local.month)}月${two(local.day)}日';
}

String formatDuration(Duration value) {
  if (value.isNegative) value = Duration.zero;
  final totalSeconds = value.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return '$minutes:${two(seconds)}';
}

class ErrorBox extends StatelessWidget {
  const ErrorBox({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF5C2B2B),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              message,
              style: const TextStyle(color: Color(0xFFFFD7D7)),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 12),
            OutlinedButton.icon(
              key: const ValueKey('error-box-action'),
              onPressed: onAction,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFFE6E6),
                side: const BorderSide(color: Color(0x99FFD7D7)),
                backgroundColor: const Color(0x33231919),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              icon: const Icon(Icons.settings_outlined, size: 17),
              label: Text(
                actionLabel!,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class NoWrapText extends StatelessWidget {
  const NoWrapText(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.fade,
    );
  }
}

class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count, this.compact = false});

  final int count;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final label = count > 99 ? '99+' : '$count';
    final minSize = compact ? 18.0 : 22.0;
    return Container(
      constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: OsColors.danger,
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [
          BoxShadow(
            color: Color(0x55000000),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          color: Colors.white,
          fontSize: compact ? 10 : 12,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}

class NewMessagesPill extends StatelessWidget {
  const NewMessagesPill({super.key, required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF2C2F39),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: OsColors.blurple),
            boxShadow: const [
              BoxShadow(
                color: Color(0x55000000),
                blurRadius: 8,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Text(
            '有 $count 条新消息 ↓',
            style: const TextStyle(
              color: Color(0xFFC9D2FF),
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class ServerBubble extends StatefulWidget {
  const ServerBubble({
    super.key,
    required this.label,
    required this.selected,
    this.onTap,
    this.tooltip,
    this.color,
    this.foregroundColor,
    this.badgeCount = 0,
    this.onSecondaryTapDown,
    this.hoverColor,
    this.imageUri,
    this.caption,
  });
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final String? tooltip;
  final Color? color;
  final Color? foregroundColor;
  final int badgeCount;
  final GestureTapDownCallback? onSecondaryTapDown;
  final Color? hoverColor;
  final Uri? imageUri;
  final String? caption;

  @override
  State<ServerBubble> createState() => _ServerBubbleState();
}

class _ServerBubbleState extends State<ServerBubble> {
  bool hovering = false;

  bool get interactive =>
      widget.onTap != null || widget.onSecondaryTapDown != null;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Tooltip(
          message: widget.tooltip ?? widget.caption ?? widget.label,
          child: MouseRegion(
            onEnter: interactive && widget.hoverColor != null
                ? (_) => setState(() => hovering = true)
                : null,
            onExit: interactive && widget.hoverColor != null
                ? (_) => setState(() => hovering = false)
                : null,
            child: InkWell(
              onTap: widget.onTap,
              onSecondaryTapDown: widget.onSecondaryTapDown,
              mouseCursor: interactive
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              borderRadius: BorderRadius.circular(24),
              child: SizedBox(
                width: 64,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: hovering && widget.hoverColor != null
                                  ? widget.hoverColor
                                  : widget.color ??
                                        (widget.selected
                                            ? OsColors.blurple
                                            : OsColors.content),
                              shape: BoxShape.circle,
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: widget.imageUri == null
                                ? Text(
                                    widget.label,
                                    style: TextStyle(
                                      color: widget.foregroundColor,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  )
                                : Image.network(
                                    widget.imageUri.toString(),
                                    width: 48,
                                    height: 48,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Center(
                                      child: Text(
                                        widget.label,
                                        style: TextStyle(
                                          color: widget.foregroundColor,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                          if (widget.badgeCount > 0)
                            Positioned(
                              right: -3,
                              top: -4,
                              child: UnreadBadge(
                                count: widget.badgeCount,
                                compact: true,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (widget.caption != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        widget.caption!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: widget.selected ? OsColors.text : OsColors.dim,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HeaderIconButton extends StatelessWidget {
  const HeaderIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
        icon: Icon(icon, size: 20, color: OsColors.muted),
      ),
    );
  }
}

class ServerHeader extends StatelessWidget {
  const ServerHeader({
    super.key,
    required this.serverName,
    required this.menuOpen,
    required this.onMenuPressed,
  });

  final String serverName;
  final bool menuOpen;
  final GestureTapUpCallback onMenuPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.only(left: 16, right: 10),
      decoration: const BoxDecoration(
        color: OsColors.sidebar,
        border: Border(bottom: BorderSide(color: OsColors.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              serverName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: OsColors.text,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
          ),
          if (!kIsWeb)
            Tooltip(
              message: '服务器菜单',
              child: Material(
                color: menuOpen ? OsColors.rowSelected : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  onTapUp: onMenuPressed,
                  mouseCursor: SystemMouseCursors.click,
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: Icon(Icons.menu, color: OsColors.text, size: 22),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class DiscordTab extends StatelessWidget {
  const DiscordTab({
    super.key,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? OsColors.rowHover : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? OsColors.text : OsColors.muted,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class SidebarNavTile extends StatelessWidget {
  const SidebarNavTile({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? OsColors.rowSelected : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          onTap: onTap,
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 42,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Icon(
                  icon,
                  size: 22,
                  color: selected ? OsColors.text : OsColors.dim,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? OsColors.text : OsColors.muted,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AudioDeviceDropdown extends StatelessWidget {
  const AudioDeviceDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.devices,
    required this.emptyLabel,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<rtc.MediaDeviceInfo> devices;
  final String emptyLabel;
  final ValueChanged<String?> onChanged;

  Future<void> _showOptions(
    BuildContext context,
    List<({String label, String value})> options,
  ) async {
    final fieldBox = context.findRenderObject() as RenderBox;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final topLeft = fieldBox.localToGlobal(
      Offset(0, fieldBox.size.height + 6),
      ancestor: overlayBox,
    );
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(topLeft.dx, topLeft.dy, fieldBox.size.width, 0),
      Offset.zero & overlayBox.size,
    );
    final selected = await showMenu<String>(
      context: context,
      position: position,
      constraints: BoxConstraints.tightFor(width: fieldBox.size.width),
      color: OsColors.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: OsColors.panelBorder),
      ),
      items: [
        for (final option in options)
          PopupMenuItem<String>(
            key: ValueKey('audio-device-option-${option.value}'),
            value: option.value,
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            mouseCursor: SystemMouseCursors.click,
            child: AudioDeviceMenuOption(
              label: option.label,
              selected: option.value == value,
            ),
          ),
      ],
    );
    if (!context.mounted || selected == null) return;
    onChanged(selected);
  }

  @override
  Widget build(BuildContext context) {
    final options = <({String label, String value})>[
      (value: '', label: emptyLabel),
      ...devices.map(
        (device) => (
          value: device.deviceId,
          label: device.label.trim().isEmpty ? '未命名设备' : device.label,
        ),
      ),
    ];
    final selectedLabel = options
        .where((option) => option.value == value)
        .map((option) => option.label)
        .firstOrNull;
    final transparentMenuInkTheme = Theme.of(context).copyWith(
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
    );
    return Theme(
      data: transparentMenuInkTheme,
      child: Builder(
        builder: (fieldContext) => Material(
          color: OsColors.field,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: OsColors.panelBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('audio-device-dropdown-$label'),
            onTap: () => _showOptions(fieldContext, options),
            mouseCursor: SystemMouseCursors.click,
            hoverColor: OsColors.rowHover,
            splashColor: OsColors.blurpleSoft,
            child: SizedBox(
              height: 64,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 15),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: OsColors.dim,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            selectedLabel ?? emptyLabel,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: OsColors.text,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: OsColors.muted,
                          size: 22,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AudioDeviceMenuOption extends StatefulWidget {
  const AudioDeviceMenuOption({
    super.key,
    required this.label,
    required this.selected,
  });

  final String label;
  final bool selected;

  @override
  State<AudioDeviceMenuOption> createState() => _AudioDeviceMenuOptionState();
}

class _AudioDeviceMenuOptionState extends State<AudioDeviceMenuOption> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: widget.selected
              ? OsColors.blurpleSoft
              : hovered
              ? OsColors.rowHover
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: widget.selected ? OsColors.text : OsColors.muted,
                  fontSize: 14,
                  fontWeight: widget.selected
                      ? FontWeight.w700
                      : FontWeight.w600,
                ),
              ),
            ),
            if (widget.selected) ...[
              const SizedBox(width: 10),
              const Icon(
                Icons.check_rounded,
                size: 18,
                color: OsColors.blurple,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum AudioVolumePopoverKind { input, output }

class MobileChannelCard extends StatelessWidget {
  const MobileChannelCard({
    super.key,
    required this.channel,
    required this.selected,
    required this.unreadCount,
    required this.mentionCount,
    required this.members,
    required this.voiceStatesByUserId,
    required this.api,
    required this.avatarToken,
    required this.onOpen,
    required this.onDoubleTap,
    this.onLongPressStart,
  });

  final Channel channel;
  final bool selected;
  final int unreadCount;
  final int mentionCount;
  final List<PresenceUser> members;
  final Map<String, VoiceState> voiceStatesByUserId;
  final OpenSpeakApi? api;
  final String? avatarToken;
  final VoidCallback onOpen;
  final VoidCallback onDoubleTap;
  final GestureLongPressStartCallback? onLongPressStart;

  @override
  Widget build(BuildContext context) {
    final hasUnread = unreadCount > 0 || mentionCount > 0;
    final visibleMembers = members.take(2).toList();
    final memberNames = visibleMembers
        .map(
          (member) => member.displayName.trim().isEmpty
              ? member.userId
              : member.displayName.trim(),
        )
        .join('、');
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: GestureDetector(
        onLongPressStart: onLongPressStart,
        child: Material(
          color: selected ? OsColors.rowSelected : OsColors.rowHover,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: onDoubleTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 58),
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected ? OsColors.blurple : OsColors.panelBorder,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.tag,
                        color: selected || hasUnread
                            ? OsColors.text
                            : OsColors.dim,
                        size: 21,
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected || hasUnread
                                ? OsColors.text
                                : OsColors.muted,
                            fontSize: 15,
                            fontWeight: selected || hasUnread
                                ? FontWeight.w800
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          IconButton(
                            key: ValueKey('mobile-channel-open-${channel.id}'),
                            tooltip: '进入频道聊天',
                            onPressed: onOpen,
                            padding: EdgeInsets.zero,
                            alignment: Alignment.center,
                            style: IconButton.styleFrom(
                              backgroundColor: OsColors.sidebarBottom,
                              foregroundColor: OsColors.dim,
                              side: const BorderSide(
                                color: OsColors.panelBorder,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              fixedSize: const Size(40, 40),
                              minimumSize: const Size(40, 40),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: const Icon(
                              Icons.chevron_right_rounded,
                              size: 28,
                            ),
                          ),
                          if (hasUnread)
                            Positioned(
                              left: -7,
                              top: -5,
                              child: IgnorePointer(
                                child: UnreadBadge(
                                  count: unreadCount > 0
                                      ? unreadCount
                                      : mentionCount,
                                  compact: true,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                  if (visibleMembers.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const SizedBox(width: 30),
                        for (final member in visibleMembers)
                          Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: ChannelMemberSpeakingAvatar(
                              displayName: member.displayName.trim().isEmpty
                                  ? member.userId
                                  : member.displayName.trim(),
                              online: member.online,
                              voiceState: voiceStatesByUserId[member.userId],
                              avatarUri: member.avatarVersion > 0
                                  ? api?.userAvatarUri(
                                      member.userId,
                                      member.avatarVersion,
                                      small: true,
                                    )
                                  : null,
                              avatarToken: avatarToken,
                            ),
                          ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            members.length > visibleMembers.length
                                ? '$memberNames 等 ${members.length} 人在线'
                                : '$memberNames 在线',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: OsColors.dim,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MobileDirectUserTile extends StatelessWidget {
  const MobileDirectUserTile({
    super.key,
    required this.user,
    required this.voiceState,
    required this.channelName,
    required this.unreadCount,
    required this.avatarUri,
    required this.avatarToken,
    required this.onTap,
  });

  final PresenceUser user;
  final VoiceState? voiceState;
  final String? channelName;
  final int unreadCount;
  final Uri? avatarUri;
  final String? avatarToken;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final displayName = user.displayName.trim().isEmpty
        ? user.userId
        : user.displayName.trim();
    return Material(
      color: OsColors.rowHover,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 68),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: OsColors.panelBorder),
          ),
          child: Row(
            children: [
              ChannelMemberSpeakingAvatar(
                displayName: displayName,
                online: user.online,
                voiceState: voiceState,
                avatarUri: avatarUri,
                avatarToken: avatarToken,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: OsColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      channelName == null ? '在线' : '在 #$channelName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: OsColors.dim,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              UnreadBadge(count: unreadCount, compact: true),
              const SizedBox(width: 7),
              const Icon(
                Icons.chevron_right_rounded,
                color: OsColors.dim,
                size: 24,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MobileVoiceActionCard extends StatelessWidget {
  const MobileVoiceActionCard({
    super.key,
    required this.label,
    this.icon,
    this.iconWidget,
    required this.onTap,
    this.active = false,
    this.enabled = true,
  }) : assert(icon != null || iconWidget != null);

  final String label;
  final IconData? icon;
  final Widget? iconWidget;
  final VoidCallback onTap;
  final bool active;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final foreground = !enabled
        ? OsColors.icon
        : active
        ? const Color(0xFF929CFF)
        : OsColors.muted;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Material(
        color: active ? OsColors.blurpleSoft : OsColors.panelRaised,
        borderRadius: BorderRadius.circular(15),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: active ? OsColors.blurple : OsColors.panelBorder,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                iconWidget ?? Icon(icon, color: foreground, size: 25),
                const SizedBox(height: 7),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CurrentUserBar extends StatefulWidget {
  const CurrentUserBar({
    super.key,
    required this.connected,
    required this.displayName,
    this.avatarFile,
    this.avatarRevision = 0,
    this.avatarUri,
    this.avatarToken,
    required this.online,
    required this.muted,
    this.canSpeak = true,
    this.canShareScreen = false,
    this.screenSharing = false,
    this.screenShareBusy = false,
    this.screenShareUnavailableReason,
    required this.listenOff,
    this.noiseSuppressionEnabled = true,
    required this.inputVolume,
    required this.outputVolume,
    required this.onMute,
    required this.onListenOff,
    this.onNoiseSuppressionToggle,
    required this.onInputVolumeChanged,
    required this.onOutputVolumeChanged,
    this.onScreenShare,
    required this.onSettings,
    this.upstreamPacketLoss,
    this.downstreamPacketLoss,
    this.latencyMs,
    this.latencyJitterMs,
  });

  final bool connected;
  final String displayName;
  final File? avatarFile;
  final int avatarRevision;
  final Uri? avatarUri;
  final String? avatarToken;
  final bool online;
  final bool muted;
  final bool canSpeak;
  final bool canShareScreen;
  final bool screenSharing;
  final bool screenShareBusy;
  final String? screenShareUnavailableReason;
  final bool listenOff;
  final bool noiseSuppressionEnabled;
  final double inputVolume;
  final double outputVolume;
  final double? upstreamPacketLoss;
  final double? downstreamPacketLoss;
  final double? latencyMs;
  final double? latencyJitterMs;
  final VoidCallback onMute;
  final VoidCallback onListenOff;
  final VoidCallback? onNoiseSuppressionToggle;
  final ValueChanged<double> onInputVolumeChanged;
  final ValueChanged<double> onOutputVolumeChanged;
  final VoidCallback? onScreenShare;
  final VoidCallback onSettings;

  @override
  State<CurrentUserBar> createState() => _CurrentUserBarState();
}

class _CurrentUserBarState extends State<CurrentUserBar> {
  final LayerLink _networkStatsLink = LayerLink();
  final LayerLink _inputVolumeLink = LayerLink();
  final LayerLink _outputVolumeLink = LayerLink();
  OverlayEntry? _volumeOverlay;
  OverlayEntry? _networkStatsOverlay;
  AudioVolumePopoverKind? _openVolumeKind;
  Timer? _volumeHideTimer;

  @override
  void didUpdateWidget(CurrentUserBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.connected) {
      _hideVolumePopover();
      _hideNetworkStats();
    } else if (_openVolumeKind != null &&
        (oldWidget.inputVolume != widget.inputVolume ||
            oldWidget.outputVolume != widget.outputVolume ||
            oldWidget.muted != widget.muted ||
            oldWidget.listenOff != widget.listenOff)) {
      _volumeOverlay?.markNeedsBuild();
    }
    if (oldWidget.canSpeak &&
        !widget.canSpeak &&
        _openVolumeKind == AudioVolumePopoverKind.input) {
      _removeVolumePopover(notify: false);
    }
    if (oldWidget.upstreamPacketLoss != widget.upstreamPacketLoss ||
        oldWidget.downstreamPacketLoss != widget.downstreamPacketLoss ||
        oldWidget.latencyMs != widget.latencyMs ||
        oldWidget.latencyJitterMs != widget.latencyJitterMs) {
      _networkStatsOverlay?.markNeedsBuild();
    }
  }

  @override
  void dispose() {
    _volumeHideTimer?.cancel();
    _removeVolumePopover(notify: false);
    _removeNetworkStats(notify: false);
    super.dispose();
  }

  void _showVolumePopover(AudioVolumePopoverKind kind) {
    if (!widget.connected ||
        (kind == AudioVolumePopoverKind.input && !widget.canSpeak)) {
      return;
    }
    _cancelVolumePopoverHide();
    if (_openVolumeKind == kind && _volumeOverlay != null) return;
    _hideNetworkStats();
    _hideVolumePopover();
    _openVolumeKind = kind;
    _volumeOverlay = OverlayEntry(
      builder: (context) {
        final activeKind = _openVolumeKind;
        if (activeKind == null) return const SizedBox.shrink();
        final link = activeKind == AudioVolumePopoverKind.input
            ? _inputVolumeLink
            : _outputVolumeLink;
        final value = activeKind == AudioVolumePopoverKind.input
            ? (widget.muted ? 0.0 : widget.inputVolume)
            : (widget.listenOff ? 0.0 : widget.outputVolume);
        final label = activeKind == AudioVolumePopoverKind.input
            ? '麦克风音量'
            : '扬声器音量';
        return CompositedTransformFollower(
          link: link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, -8),
          child: UnconstrainedBox(
            alignment: Alignment.bottomCenter,
            child: MouseRegion(
              onEnter: (_) => _cancelVolumePopoverHide(),
              onExit: (_) => _scheduleVolumePopoverHide(),
              child: Material(
                color: Colors.transparent,
                child: AudioVolumePopover(
                  label: label,
                  value: value,
                  onChanged: activeKind == AudioVolumePopoverKind.input
                      ? widget.onInputVolumeChanged
                      : widget.onOutputVolumeChanged,
                ),
              ),
            ),
          ),
        );
      },
    );
    Overlay.of(context).insert(_volumeOverlay!);
    setState(() {});
  }

  void _hideVolumePopover() {
    _volumeHideTimer?.cancel();
    _volumeHideTimer = null;
    _removeVolumePopover();
  }

  void _scheduleVolumePopoverHide() {
    _volumeHideTimer?.cancel();
    _volumeHideTimer = Timer(const Duration(milliseconds: 300), () {
      _volumeHideTimer = null;
      if (mounted) _hideVolumePopover();
    });
  }

  void _cancelVolumePopoverHide() {
    _volumeHideTimer?.cancel();
    _volumeHideTimer = null;
  }

  void _removeVolumePopover({bool notify = true}) {
    _volumeOverlay?.remove();
    _volumeOverlay = null;
    _openVolumeKind = null;
    if (notify && mounted) setState(() {});
  }

  void _toggleNetworkStats() {
    if (_networkStatsOverlay != null) {
      _hideNetworkStats();
      return;
    }
    if (!widget.connected) return;
    _hideVolumePopover();
    _networkStatsOverlay = OverlayEntry(
      builder: (context) => CompositedTransformFollower(
        link: _networkStatsLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: const Offset(-5, -8),
        child: UnconstrainedBox(
          alignment: Alignment.bottomLeft,
          child: TapRegion(
            onTapOutside: (_) => _hideNetworkStats(),
            child: Material(
              color: Colors.transparent,
              child: NetworkStatsCard(
                upstreamPacketLoss: widget.upstreamPacketLoss,
                downstreamPacketLoss: widget.downstreamPacketLoss,
                latencyMs: widget.latencyMs,
                latencyJitterMs: widget.latencyJitterMs,
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_networkStatsOverlay!);
    setState(() {});
  }

  void _hideNetworkStats() {
    _removeNetworkStats();
  }

  void _removeNetworkStats({bool notify = true}) {
    _networkStatsOverlay?.remove();
    _networkStatsOverlay = null;
    if (notify && mounted) setState(() {});
  }

  Widget _volumeIconButton({
    required AudioVolumePopoverKind kind,
    required LayerLink link,
    required String tooltip,
    required IconData icon,
    required bool active,
    required VoidCallback? onPressed,
  }) {
    return CompositedTransformTarget(
      link: link,
      child: MouseRegion(
        onEnter: (_) => _showVolumePopover(kind),
        onExit: (_) => _scheduleVolumePopoverHide(),
        child: StatusBarIconButton(
          tooltip: tooltip,
          icon: icon,
          active: active,
          selected: _openVolumeKind == kind,
          onPressed: onPressed,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cardTop = widget.connected ? 45.0 : 79.0;
    final cardHeight = widget.connected ? 77.0 : 43.0;
    const userBarWidth = 239.0;
    const cardLeft = 6.0;
    const cardWidth = 227.0;
    const statusIconTop = 51.0;
    const statusIconSlot = 28.0;
    const networkIconSize = 20.0;
    const audioIconSize = 18.0;
    const audioIconGroupWidth = statusIconSlot * (kIsWeb ? 2 : 4);
    const settingsIconLeft = 201.0;
    const speakerVisualRight =
        settingsIconLeft + (statusIconSlot + audioIconSize) / 2;
    const mirroredStatusVisualLeft = userBarWidth - speakerVisualRight;
    const statusIconGroupLeft =
        mirroredStatusVisualLeft - (statusIconSlot - networkIconSize) / 2;
    return SizedBox(
      width: userBarWidth,
      height: 132,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: cardLeft,
            top: cardTop,
            width: cardWidth,
            height: cardHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: OsColors.sidebarBottom,
                borderRadius: BorderRadius.circular(9),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 5,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
            ),
          ),
          if (widget.connected) ...[
            Positioned(
              left: statusIconGroupLeft,
              top: statusIconTop,
              child: Row(
                children: [
                  CompositedTransformTarget(
                    link: _networkStatsLink,
                    child: NetworkQualityButton(
                      latencyMs: widget.latencyMs,
                      latencyJitterMs: widget.latencyJitterMs,
                      upstreamPacketLoss: widget.upstreamPacketLoss,
                      downstreamPacketLoss: widget.downstreamPacketLoss,
                      selected: _networkStatsOverlay != null,
                      onPressed: _toggleNetworkStats,
                    ),
                  ),
                  SizedBox(
                    width: statusIconSlot,
                    height: statusIconSlot,
                    child: StatusBarIconButton(
                      tooltip: widget.screenSharing
                          ? '停止分享屏幕'
                          : widget.screenShareBusy
                          ? '正在切换屏幕共享'
                          : widget.screenShareUnavailableReason ??
                                (widget.canShareScreen
                                    ? '分享屏幕'
                                    : '请先进入语音频道或检查屏幕共享权限'),
                      icon: widget.screenSharing
                          ? Icons.stop_screen_share_rounded
                          : Icons.screen_share,
                      iconSize: 20,
                      active: widget.screenSharing || widget.canShareScreen,
                      activeColor: widget.screenSharing
                          ? OsColors.green
                          : Colors.white,
                      onPressed:
                          !widget.screenShareBusy &&
                              (widget.screenSharing || widget.canShareScreen)
                          ? widget.onScreenShare
                          : null,
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: settingsIconLeft + statusIconSlot - audioIconGroupWidth,
              top: statusIconTop,
              child: Row(
                children: [
                  if (!kIsWeb)
                    StatusBarIconButton(
                      key: const ValueKey('noise-suppression-toggle'),
                      tooltip: widget.noiseSuppressionEnabled ? '关闭降噪' : '开启降噪',
                      iconWidget: Opacity(
                        opacity: widget.noiseSuppressionEnabled ? 1 : 0.4,
                        child: Image.asset(
                          'assets/images/noise_suppression.png',
                          key: const ValueKey('noise-suppression-icon'),
                          width: 52,
                          height: 26,
                          fit: BoxFit.contain,
                        ),
                      ),
                      width: 56,
                      onPressed: widget.onNoiseSuppressionToggle,
                    ),
                  _volumeIconButton(
                    kind: AudioVolumePopoverKind.input,
                    link: _inputVolumeLink,
                    tooltip: !widget.canSpeak
                        ? '没有发送语音权限'
                        : widget.muted
                        ? '取消静音'
                        : '静音',
                    icon: !widget.canSpeak || widget.muted
                        ? Icons.mic_off
                        : Icons.mic,
                    active: widget.canSpeak && !widget.muted,
                    onPressed: widget.canSpeak ? widget.onMute : null,
                  ),
                  _volumeIconButton(
                    kind: AudioVolumePopoverKind.output,
                    link: _outputVolumeLink,
                    tooltip: widget.listenOff ? '开启收听' : '关闭收听',
                    icon: widget.listenOff ? Icons.volume_off : Icons.volume_up,
                    active: !widget.listenOff,
                    onPressed: widget.onListenOff,
                  ),
                ],
              ),
            ),
          ],
          Positioned(
            left: 14,
            top: 87,
            child: OsUserAvatar(
              displayName: widget.displayName,
              size: 29,
              avatarFile: widget.avatarFile,
              avatarRevision: widget.avatarRevision,
              avatarUri: widget.avatarUri,
              avatarToken: widget.avatarToken,
              backgroundColor: const Color(0xFFA55CD2),
            ),
          ),
          Positioned(
            left: 52,
            top: 87,
            width: 150,
            height: 29,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                key: const ValueKey('current-user-display-name'),
                widget.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: OsColors.text,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          Positioned(
            left: settingsIconLeft,
            top: 89,
            child: StatusBarIconButton(
              tooltip: '设置',
              icon: Icons.settings,
              onPressed: widget.onSettings,
            ),
          ),
        ],
      ),
    );
  }
}

class StatusBarIconButton extends StatelessWidget {
  const StatusBarIconButton({
    super.key,
    required this.tooltip,
    this.icon,
    this.iconWidget,
    required this.onPressed,
    this.active = false,
    this.selected = false,
    this.activeColor = Colors.white,
    this.width = 28,
    this.iconSize = 18,
  }) : assert(icon != null || iconWidget != null);

  final String tooltip;
  final IconData? icon;
  final Widget? iconWidget;
  final VoidCallback? onPressed;
  final bool active;
  final bool selected;
  final Color activeColor;
  final double width;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: selected ? OsColors.rowSelected : Colors.transparent,
          minimumSize: Size(width, 28),
          fixedSize: Size(width, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        constraints: BoxConstraints.tightFor(width: width, height: 28),
        mouseCursor: onPressed == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onPressed: onPressed,
        icon:
            iconWidget ??
            Icon(
              icon,
              size: iconSize,
              color: active ? activeColor : OsColors.dim,
            ),
      ),
    );
  }
}

class _ScreenShareSourceDialog extends StatefulWidget {
  const _ScreenShareSourceDialog();

  @override
  State<_ScreenShareSourceDialog> createState() =>
      _ScreenShareSourceDialogState();
}

class _ScreenShareSourceDialogState extends State<_ScreenShareSourceDialog> {
  static const sourceTypes = [rtc.SourceType.Screen, rtc.SourceType.Window];

  final sources = <String, rtc.DesktopCapturerSource>{};
  final subscriptions = <StreamSubscription<rtc.DesktopCapturerSource>>[];
  rtc.SourceType sourceType = rtc.SourceType.Screen;
  rtc.DesktopCapturerSource? selectedSource;
  Timer? refreshTimer;
  String? loadError;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    subscriptions
      ..add(rtc.desktopCapturer.onAdded.stream.listen(_upsertSource))
      ..add(rtc.desktopCapturer.onRemoved.stream.listen(_removeSource))
      ..add(rtc.desktopCapturer.onNameChanged.stream.listen(_upsertSource))
      ..add(
        rtc.desktopCapturer.onThumbnailChanged.stream.listen(_upsertSource),
      );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadSources());
    });
  }

  List<rtc.DesktopCapturerSource> get visibleSources {
    final visible = sources.values
        .where((source) => source.type == sourceType)
        .toList();
    visible.sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
    return visible;
  }

  void _selectFirstVisible() {
    final visible = visibleSources;
    selectedSource = visible.isEmpty ? null : visible.first;
  }

  void _upsertSource(rtc.DesktopCapturerSource source) {
    if (!mounted) return;
    setState(() {
      sources[source.id] = source;
      if (selectedSource == null && source.type == sourceType) {
        selectedSource = source;
      }
    });
  }

  void _removeSource(rtc.DesktopCapturerSource source) {
    if (!mounted) return;
    setState(() {
      sources.remove(source.id);
      if (selectedSource?.id == source.id) _selectFirstVisible();
    });
  }

  Future<void> _loadSources() async {
    if (mounted) {
      setState(() {
        loading = true;
        loadError = null;
      });
    }
    try {
      final loaded = await rtc.desktopCapturer.getSources(
        types: sourceTypes,
        thumbnailSize: rtc.ThumbnailSize(480, 270),
      );
      if (!mounted) return;
      setState(() {
        sources
          ..clear()
          ..addEntries(loaded.map((source) => MapEntry(source.id, source)));
        if (selectedSource == null ||
            !sources.containsKey(selectedSource!.id) ||
            selectedSource!.type != sourceType) {
          _selectFirstVisible();
        }
        loading = false;
      });
      refreshTimer ??= Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(_refreshSources()),
      );
    } catch (exception, stackTrace) {
      ClientLog.error('voice.screen.sources', exception, stackTrace);
      if (!mounted) return;
      setState(() {
        loading = false;
        loadError = '无法读取可分享的屏幕或窗口';
      });
    }
  }

  Future<void> _refreshSources() async {
    try {
      await rtc.desktopCapturer.updateSources(types: sourceTypes);
    } catch (exception, stackTrace) {
      ClientLog.error('voice.screen.sources.refresh', exception, stackTrace);
    }
  }

  void _selectType(rtc.SourceType value) {
    if (sourceType == value) return;
    setState(() {
      sourceType = value;
      _selectFirstVisible();
    });
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = visibleSources;
    final sourceLabel = sourceType == rtc.SourceType.Screen ? '整个屏幕' : '窗口';
    return OsSettingsDialog(
      icon: Icons.screen_share_rounded,
      eyebrow: '屏幕共享',
      title: '选择要分享的内容',
      subtitle: '选择一个屏幕或应用窗口，确认后立即开始分享。',
      maxWidth: 900,
      leadingActions: [
        OsSecondaryButton(label: '取消', onPressed: () => Navigator.pop(context)),
      ],
      actions: [
        if (selectedSource != null)
          OsPrimaryButton(
            label: '开始分享',
            icon: Icons.screen_share_rounded,
            onPressed: () => Navigator.pop(context, selectedSource),
          ),
      ],
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 190,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF222429),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: OsColors.panelBorder),
            ),
            child: SmoothListView(
              padding: EdgeInsets.zero,
              children: [
                const OsSettingsNavSection('分享来源'),
                OsSettingsNavEntry(
                  icon: Icons.desktop_windows_rounded,
                  label: '整个屏幕',
                  selected: sourceType == rtc.SourceType.Screen,
                  onTap: () => _selectType(rtc.SourceType.Screen),
                ),
                OsSettingsNavEntry(
                  icon: Icons.web_asset_rounded,
                  label: '窗口',
                  selected: sourceType == rtc.SourceType.Window,
                  onTap: () => _selectType(rtc.SourceType.Window),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: OsSettingsPage(
              icon: sourceType == rtc.SourceType.Screen
                  ? Icons.desktop_windows_rounded
                  : Icons.web_asset_rounded,
              title: sourceLabel,
              subtitle: loading ? '正在读取可分享内容…' : '找到 ${visible.length} 项',
              child: loading
                  ? const SizedBox(
                      height: 280,
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : loadError != null
                  ? SizedBox(
                      height: 280,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              color: OsColors.danger,
                              size: 30,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              loadError!,
                              style: const TextStyle(color: OsColors.muted),
                            ),
                            const SizedBox(height: 8),
                            OsSecondaryButton(
                              label: '重新加载',
                              icon: Icons.refresh_rounded,
                              onPressed: () => unawaited(_loadSources()),
                            ),
                          ],
                        ),
                      ),
                    )
                  : visible.isEmpty
                  ? SizedBox(
                      height: 280,
                      child: Center(
                        child: Text(
                          sourceType == rtc.SourceType.Screen
                              ? '没有找到可分享的屏幕'
                              : '没有找到可分享的窗口',
                          style: const TextStyle(color: OsColors.dim),
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        const spacing = 12.0;
                        final columns = (constraints.maxWidth / 250)
                            .floor()
                            .clamp(1, 4);
                        final cardWidth =
                            (constraints.maxWidth - spacing * (columns - 1)) /
                            columns;
                        return Wrap(
                          spacing: spacing,
                          runSpacing: spacing,
                          children: [
                            for (final source in visible)
                              SizedBox(
                                width: cardWidth,
                                height: math.max(150, cardWidth / 1.42),
                                child: _ScreenShareSourceTile(
                                  source: source,
                                  selected: selectedSource?.id == source.id,
                                  onTap: () =>
                                      setState(() => selectedSource = source),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScreenShareSourceTile extends StatelessWidget {
  const _ScreenShareSourceTile({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final rtc.DesktopCapturerSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final thumbnail = source.thumbnail;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: selected ? OsColors.blurpleSoft : OsColors.panelRaised,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? OsColors.blurple : OsColors.panelBorder,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ColoredBox(
                  color: const Color(0xFF111216),
                  child: thumbnail?.isNotEmpty == true
                      ? Image.memory(
                          thumbnail!,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.medium,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.hide_image_outlined,
                            color: OsColors.dim,
                            size: 30,
                          ),
                        )
                      : const Icon(
                          Icons.desktop_windows_outlined,
                          color: OsColors.dim,
                          size: 34,
                        ),
                ),
              ),
              Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Icon(
                      source.type == rtc.SourceType.Screen
                          ? Icons.desktop_windows_rounded
                          : Icons.web_asset_rounded,
                      size: 16,
                      color: selected ? OsColors.blurple : OsColors.dim,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? OsColors.text : OsColors.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (selected)
                      const Icon(
                        Icons.check_circle_rounded,
                        size: 17,
                        color: OsColors.blurple,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ScreenShareViewerActions extends StatelessWidget {
  const ScreenShareViewerActions({
    super.key,
    required this.collapsed,
    required this.onToggleCollapsed,
    required this.onMaximize,
  });

  final bool collapsed;
  final VoidCallback onToggleCollapsed;
  final VoidCallback onMaximize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusBarIconButton(
          key: const ValueKey('screen-share-collapse'),
          tooltip: collapsed ? '展开' : '折叠',
          icon: collapsed
              ? Icons.keyboard_arrow_down_rounded
              : Icons.keyboard_arrow_up_rounded,
          active: true,
          onPressed: onToggleCollapsed,
        ),
        StatusBarIconButton(
          key: const ValueKey('screen-share-expand'),
          tooltip: '最大化窗口',
          icon: Icons.fullscreen_rounded,
          active: true,
          onPressed: onMaximize,
        ),
      ],
    );
  }
}

class ScreenShareHeader extends StatelessWidget {
  const ScreenShareHeader({
    super.key,
    required this.title,
    required this.actions,
  });

  final String title;
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _screenShareHeaderHeight,
      padding: const EdgeInsets.only(left: 13, right: 8),
      color: OsColors.panelRaised,
      child: Row(
        children: [
          const Icon(
            Icons.screen_share_rounded,
            size: 18,
            color: OsColors.green,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: OsColors.text,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          actions,
        ],
      ),
    );
  }
}

const _screenShareHeaderHeight = 38.0;
const _screenShareStageTopInset = 14.0;
const _screenShareStageHorizontalInset = 16.0;
const _screenShareStageBorderWidth = 1.0;

Widget screenShareOverlay({
  required Widget chat,
  required Widget stage,
  required double stageWidth,
  double? stageHeight,
}) => Stack(
  children: [
    Positioned.fill(child: chat),
    Positioned(
      top: 0,
      right: 0,
      width: stageWidth,
      height: stageHeight,
      child: stage,
    ),
  ],
);

double screenShareStagePanelWidth({
  required double maxWidth,
  required double maxHeight,
  required double aspectRatio,
}) {
  final availableWidth = math
      .max(0.0, maxWidth - _screenShareStageHorizontalInset * 2)
      .toDouble();
  if (!aspectRatio.isFinite || aspectRatio <= 0) return availableWidth;
  final videoHeight = math
      .max(
        0.0,
        maxHeight -
            _screenShareStageTopInset -
            _screenShareHeaderHeight -
            _screenShareStageBorderWidth * 2,
      )
      .toDouble();
  return math
      .min(
        availableWidth,
        videoHeight * aspectRatio + _screenShareStageBorderWidth * 2,
      )
      .toDouble();
}

class ScreenShareStage extends StatelessWidget {
  const ScreenShareStage({
    super.key,
    required this.share,
    required this.collapsed,
    required this.onToggleCollapsed,
    required this.onMaximize,
  });

  final VoiceScreenShare share;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;
  final VoidCallback onMaximize;

  @override
  Widget build(BuildContext context) {
    final name = share.displayName.trim().isEmpty
        ? share.userId
        : share.displayName;
    final panel = Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111216),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: OsColors.panelBorder,
          width: _screenShareStageBorderWidth,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: collapsed ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenShareHeader(
            title: '$name 正在分享屏幕',
            actions: ScreenShareViewerActions(
              collapsed: collapsed,
              onToggleCollapsed: onToggleCollapsed,
              onMaximize: onMaximize,
            ),
          ),
          if (!collapsed)
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: lk.VideoTrackRenderer(
                  share.track,
                  fit: lk.VideoViewFit.contain,
                ),
              ),
            ),
        ],
      ),
    );
    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          _screenShareStageHorizontalInset,
          _screenShareStageTopInset,
          _screenShareStageHorizontalInset,
          0,
        ),
        child: panel,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final panelWidth = screenShareStagePanelWidth(
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
          aspectRatio: share.aspectRatio,
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            _screenShareStageHorizontalInset,
            _screenShareStageTopInset,
            _screenShareStageHorizontalInset,
            0,
          ),
          child: Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: panelWidth,
              height: math.max(
                0.0,
                constraints.maxHeight - _screenShareStageTopInset,
              ),
              child: panel,
            ),
          ),
        );
      },
    );
  }
}

class ScreenShareWindow extends StatelessWidget {
  const ScreenShareWindow({super.key, required this.controller});

  final VoiceSessionController controller;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF111216),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: OsColors.panelBorder),
            boxShadow: const [
              BoxShadow(
                color: Color(0x99000000),
                blurRadius: 36,
                offset: Offset(0, 18),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                final share = controller.activeScreenShare;
                final name = share == null
                    ? ''
                    : share.displayName.trim().isEmpty
                    ? share.userId
                    : share.displayName;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ScreenShareHeader(
                      title: share == null ? '屏幕共享' : '$name 正在分享屏幕',
                      actions: StatusBarIconButton(
                        key: const ValueKey('screen-share-window-return'),
                        tooltip: '还原窗口',
                        icon: Icons.fullscreen_exit_rounded,
                        active: true,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    Expanded(
                      child: share == null
                          ? const Center(
                              child: Text(
                                '屏幕共享已结束',
                                style: TextStyle(
                                  color: OsColors.muted,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          : ColoredBox(
                              color: Colors.black,
                              child: lk.VideoTrackRenderer(
                                share.track,
                                fit: lk.VideoViewFit.contain,
                              ),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class NetworkQualityButton extends StatelessWidget {
  const NetworkQualityButton({
    super.key,
    required this.latencyMs,
    required this.latencyJitterMs,
    required this.upstreamPacketLoss,
    required this.downstreamPacketLoss,
    required this.selected,
    required this.onPressed,
  });

  final double? latencyMs;
  final double? latencyJitterMs;
  final double? upstreamPacketLoss;
  final double? downstreamPacketLoss;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final quality = networkQualityForStats(
      latencyMs: latencyMs,
      latencyJitterMs: latencyJitterMs,
      upstreamPacketLoss: upstreamPacketLoss,
      downstreamPacketLoss: downstreamPacketLoss,
    );
    final icon = switch (quality.bars) {
      1 => Icons.signal_cellular_alt_1_bar,
      2 => Icons.signal_cellular_alt_2_bar,
      _ => Icons.signal_cellular_alt,
    };
    return Tooltip(
      message: '网络状态',
      child: InkResponse(
        onTap: onPressed,
        mouseCursor: SystemMouseCursors.click,
        radius: 16,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: selected ? OsColors.rowSelected : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 20,
            color: quality.bars == 0 ? OsColors.icon : quality.color,
          ),
        ),
      ),
    );
  }
}

class NetworkQuality {
  const NetworkQuality({required this.bars, required this.color});

  final int bars;
  final Color color;
}

NetworkQuality networkQualityForStats({
  required double? latencyMs,
  required double? latencyJitterMs,
  required double? upstreamPacketLoss,
  required double? downstreamPacketLoss,
}) {
  if (latencyMs == null) {
    return const NetworkQuality(bars: 0, color: OsColors.icon);
  }
  final jitter = latencyJitterMs ?? 0;
  final worstPacketLoss = math.max(
    upstreamPacketLoss ?? 0,
    downstreamPacketLoss ?? 0,
  );
  if (latencyMs > 200 || jitter > 30 || worstPacketLoss > 3) {
    return const NetworkQuality(bars: 1, color: OsColors.danger);
  }
  if (latencyMs > 100 || jitter > 10 || worstPacketLoss >= 1) {
    return const NetworkQuality(bars: 2, color: Color(0xFFF0A020));
  }
  return const NetworkQuality(bars: 3, color: OsColors.green);
}

class NetworkStatsCard extends StatelessWidget {
  const NetworkStatsCard({
    super.key,
    required this.upstreamPacketLoss,
    required this.downstreamPacketLoss,
    required this.latencyMs,
    required this.latencyJitterMs,
  });

  final double? upstreamPacketLoss;
  final double? downstreamPacketLoss;
  final double? latencyMs;
  final double? latencyJitterMs;

  String _loss(double? value) =>
      value == null ? '--' : '${value.toStringAsFixed(1)}%';

  String _latency(double? value, double? jitter) => value == null
      ? '--'
      : '${value.round()} ms ± ${(jitter ?? 0).toStringAsFixed(1)} ms';

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 227,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: OsColors.sidebarBottom,
        borderRadius: BorderRadius.circular(9),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 5,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _row('上行丢包', _loss(upstreamPacketLoss)),
          const SizedBox(height: 6),
          _row('下行丢包', _loss(downstreamPacketLoss)),
          const SizedBox(height: 6),
          _row(
            '延迟',
            _latency(latencyMs, latencyJitterMs),
            compactPlusMinus: true,
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool compactPlusMinus = false}) {
    final plusMinusIndex = compactPlusMinus ? value.indexOf('±') : -1;
    final valueWidget = plusMinusIndex < 0
        ? Text(
            value,
            style: const TextStyle(
              color: OsColors.text,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          )
        : Text.rich(
            TextSpan(
              style: const TextStyle(
                color: OsColors.text,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
              children: [
                TextSpan(text: value.substring(0, plusMinusIndex)),
                const TextSpan(text: '±', style: TextStyle(fontSize: 9)),
                TextSpan(text: value.substring(plusMinusIndex + 1)),
              ],
            ),
          );
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: OsColors.muted, fontSize: 11),
          ),
        ),
        valueWidget,
      ],
    );
  }
}

class AudioVolumePopover extends StatelessWidget {
  const AudioVolumePopover({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final percent = (value.clamp(0.0, 1.0) * 100).round();
    return Semantics(
      label: '$label $percent%',
      slider: true,
      value: '$percent%',
      child: Container(
        width: 44,
        height: 116,
        decoration: BoxDecoration(
          color: const Color(0xFF2F3136),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: const Color(0xFF3A3D42)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 10,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: VerticalVolumeSlider(value: value, onChanged: onChanged),
      ),
    );
  }
}

class VerticalVolumeSlider extends StatelessWidget {
  const VerticalVolumeSlider({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;

  static const double _trackTop = 20;
  static const double _trackBottom = 92;

  void _updateValue(Offset localPosition) {
    final raw =
        1 - ((localPosition.dy - _trackTop) / (_trackBottom - _trackTop));
    onChanged(raw.clamp(0.0, 1.0).toDouble());
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _updateValue(details.localPosition),
      onVerticalDragStart: (details) => _updateValue(details.localPosition),
      onVerticalDragUpdate: (details) => _updateValue(details.localPosition),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: CustomPaint(
          painter: _VerticalVolumeSliderPainter(
            value.clamp(0.0, 1.0).toDouble(),
          ),
        ),
      ),
    );
  }
}

class _VerticalVolumeSliderPainter extends CustomPainter {
  const _VerticalVolumeSliderPainter(this.value);

  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    const trackWidth = 6.0;
    const thumbRadius = 9.0;
    final centerX = size.width / 2;
    final top = VerticalVolumeSlider._trackTop;
    final bottom = VerticalVolumeSlider._trackBottom;
    final thumbY = bottom - (bottom - top) * value;
    final trackPaint = Paint()
      ..color = const Color(0xFF202225)
      ..strokeWidth = trackWidth
      ..strokeCap = StrokeCap.round;
    final activePaint = Paint()
      ..color = OsColors.green
      ..strokeWidth = trackWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(centerX, top), Offset(centerX, bottom), trackPaint);
    canvas.drawLine(
      Offset(centerX, thumbY),
      Offset(centerX, bottom),
      activePaint,
    );
    canvas.drawCircle(
      Offset(centerX, thumbY),
      thumbRadius + 2,
      Paint()..color = const Color(0xFF2F3136),
    );
    canvas.drawCircle(
      Offset(centerX, thumbY),
      thumbRadius,
      Paint()..color = OsColors.text,
    );
    canvas.drawCircle(
      Offset(centerX, thumbY),
      thumbRadius - 3,
      Paint()..color = OsColors.green,
    );
  }

  @override
  bool shouldRepaint(covariant _VerticalVolumeSliderPainter oldDelegate) {
    return oldDelegate.value != value;
  }
}

class _ImmediateChannelInkWell extends StatefulWidget {
  const _ImmediateChannelInkWell({
    required this.onTap,
    required this.onDoubleTap,
    required this.onSecondaryTapDown,
    required this.child,
  });

  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final GestureTapDownCallback onSecondaryTapDown;
  final Widget child;

  @override
  State<_ImmediateChannelInkWell> createState() =>
      _ImmediateChannelInkWellState();
}

class _ImmediateChannelInkWellState extends State<_ImmediateChannelInkWell> {
  Offset? currentPrimaryDownPosition;
  bool currentDoubleTapCandidate = false;
  Offset? lastPrimaryDownPosition;
  bool tapSeriesMinTimeElapsed = false;
  Timer? tapSeriesMinTimer;
  Timer? tapSeriesTimer;

  void handlePointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) return;
    widget.onTap();
    currentPrimaryDownPosition = event.position;
    currentDoubleTapCandidate = isDoubleTapCandidate(event.position);
    if (currentDoubleTapCandidate) {
      tapSeriesTimer?.cancel();
      tapSeriesTimer = null;
    }
  }

  bool isDoubleTapCandidate(Offset position) =>
      lastPrimaryDownPosition != null &&
      tapSeriesMinTimeElapsed &&
      (position - lastPrimaryDownPosition!).distance <= kDoubleTapSlop;

  void handleTap() {
    final currentPosition = currentPrimaryDownPosition;
    if (currentPosition == null) return;
    final doubleTap = currentDoubleTapCandidate;
    currentPrimaryDownPosition = null;
    currentDoubleTapCandidate = false;
    clearTapSeries();
    if (doubleTap) {
      widget.onDoubleTap();
    } else {
      lastPrimaryDownPosition = currentPosition;
      tapSeriesMinTimer = Timer(
        kDoubleTapMinTime,
        () => tapSeriesMinTimeElapsed = true,
      );
      tapSeriesTimer = Timer(kDoubleTapTimeout, clearTapSeries);
    }
  }

  void handleTapCancel() {
    currentPrimaryDownPosition = null;
    currentDoubleTapCandidate = false;
    clearTapSeries();
  }

  void clearTapSeries() {
    tapSeriesMinTimer?.cancel();
    tapSeriesMinTimer = null;
    tapSeriesTimer?.cancel();
    tapSeriesTimer = null;
    tapSeriesMinTimeElapsed = false;
    lastPrimaryDownPosition = null;
  }

  @override
  void dispose() {
    clearTapSeries();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    onTap: widget.onTap,
    child: Listener(
      onPointerDown: handlePointerDown,
      child: InkWell(
        excludeFromSemantics: true,
        enableFeedback: false,
        onTap: handleTap,
        onTapCancel: handleTapCancel,
        onSecondaryTapDown: widget.onSecondaryTapDown,
        child: widget.child,
      ),
    ),
  );
}

class ChannelTile extends StatelessWidget {
  const ChannelTile({
    super.key,
    required this.channel,
    required this.selected,
    required this.unreadCount,
    required this.mentionCount,
    required this.members,
    required this.directUnreadCounts,
    required this.voiceStatesByUserId,
    required this.currentUserId,
    required this.currentUserMicrophoneUnavailable,
    required this.currentUserSpeakerUnavailable,
    this.reorderIndex,
    this.api,
    this.avatarToken,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSecondaryTapDown,
    required this.onMemberTap,
    required this.onMemberSecondaryTapDown,
    this.canMoveMembers = false,
    this.onMemberDropped,
  });
  final Channel channel;
  final bool selected;
  final int unreadCount;
  final int mentionCount;
  final List<PresenceUser> members;
  final Map<String, int> directUnreadCounts;
  final Map<String, VoiceState> voiceStatesByUserId;
  final String? currentUserId;
  final bool currentUserMicrophoneUnavailable;
  final bool currentUserSpeakerUnavailable;
  final int? reorderIndex;
  final OpenSpeakApi? api;
  final String? avatarToken;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final GestureTapDownCallback onSecondaryTapDown;
  final ValueChanged<PresenceUser> onMemberTap;
  final void Function(PresenceUser, TapDownDetails) onMemberSecondaryTapDown;
  final bool canMoveMembers;
  final ValueChanged<PresenceUser>? onMemberDropped;

  @override
  Widget build(BuildContext context) {
    final hasUnread = unreadCount > 0 || mentionCount > 0;
    final unreadBadgeCount = unreadCount > 0 ? unreadCount : mentionCount;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Material(
            color: selected ? OsColors.rowSelected : OsColors.rowHover,
            borderRadius: BorderRadius.circular(4),
            clipBehavior: Clip.antiAlias,
            child: _ImmediateChannelInkWell(
              onTap: onTap,
              onDoubleTap: onDoubleTap,
              onSecondaryTapDown: onSecondaryTapDown,
              child: SizedBox(
                height: 38,
                child: Stack(
                  children: [
                    if (hasUnread)
                      const Positioned(
                        left: 0,
                        top: 6,
                        bottom: 6,
                        child: ColoredBox(
                          color: OsColors.blurple,
                          child: SizedBox(width: 3),
                        ),
                      ),
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.only(
                        left: 16,
                        right: reorderIndex != null
                            ? (hasUnread ? 68 : 42)
                            : (hasUnread ? 44 : 16),
                      ),
                      minLeadingWidth: 16,
                      leading: Icon(
                        Icons.tag,
                        size: 17,
                        color: hasUnread ? OsColors.text : OsColors.dim,
                      ),
                      title: Text(
                        channel.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected || hasUnread
                              ? OsColors.text
                              : OsColors.muted,
                          fontWeight: selected || hasUnread
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (hasUnread)
                      Positioned(
                        right: reorderIndex == null ? 8 : 34,
                        top: 5,
                        child: UnreadBadge(
                          count: unreadBadgeCount,
                          compact: true,
                        ),
                      ),
                    if (reorderIndex != null)
                      Positioned(
                        right: 6,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: ReorderableDragStartListener(
                            index: reorderIndex!,
                            child: const MouseRegion(
                              cursor: SystemMouseCursors.grab,
                              child: Icon(
                                Icons.drag_indicator_rounded,
                                size: 20,
                                color: OsColors.dim,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        for (final member in members)
          ChannelMemberSubTile(
            user: member,
            voiceState: voiceStatesByUserId[member.userId],
            microphoneUnavailable:
                member.userId == currentUserId &&
                currentUserMicrophoneUnavailable,
            speakerUnavailable:
                member.userId == currentUserId && currentUserSpeakerUnavailable,
            unreadCount: directUnreadCounts[member.userId] ?? 0,
            api: api,
            avatarToken: avatarToken,
            onTap: () => onMemberTap(member),
            onSecondaryTapDown: (details) =>
                onMemberSecondaryTapDown(member, details),
            draggable: canMoveMembers && member.userId != currentUserId,
          ),
      ],
    );
    return DragTarget<PresenceUser>(
      onWillAcceptWithDetails: (details) =>
          canMoveMembers &&
          details.data.userId != currentUserId &&
          details.data.currentChannelId != channel.id,
      onAcceptWithDetails: (details) => onMemberDropped?.call(details.data),
      builder: (context, candidates, _) => DecoratedBox(
        decoration: BoxDecoration(
          border: candidates.isEmpty
              ? null
              : Border.all(color: OsColors.blurple, width: 2),
          borderRadius: BorderRadius.circular(6),
        ),
        child: content,
      ),
    );
  }
}

class ChannelMemberSubTile extends StatelessWidget {
  const ChannelMemberSubTile({
    super.key,
    required this.user,
    required this.voiceState,
    this.microphoneUnavailable = false,
    this.speakerUnavailable = false,
    required this.unreadCount,
    this.api,
    this.avatarToken,
    required this.onTap,
    this.onSecondaryTapDown,
    this.draggable = false,
  });

  final PresenceUser user;
  final VoiceState? voiceState;
  final bool microphoneUnavailable;
  final bool speakerUnavailable;
  final int unreadCount;
  final OpenSpeakApi? api;
  final String? avatarToken;
  final VoidCallback onTap;
  final GestureTapDownCallback? onSecondaryTapDown;
  final bool draggable;

  @override
  Widget build(BuildContext context) {
    final displayName = user.displayName.trim().isNotEmpty
        ? user.displayName.trim()
        : user.userId;
    final online = user.online;

    final tile = Padding(
      padding: const EdgeInsets.only(top: 1, bottom: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onSecondaryTapDown: onSecondaryTapDown,
          mouseCursor: draggable
              ? SystemMouseCursors.grab
              : SystemMouseCursors.click,
          hoverColor: OsColors.rowSelected,
          splashColor: Colors.transparent,
          highlightColor: OsColors.rowSelected,
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ChannelMemberSpeakingAvatar(
                      displayName: displayName,
                      online: online,
                      voiceState: voiceState,
                      avatarUri: user.avatarVersion > 0
                          ? api?.userAvatarUri(
                              user.userId,
                              user.avatarVersion,
                              small: true,
                            )
                          : null,
                      avatarToken: avatarToken,
                    ),
                    Positioned(
                      right: -5,
                      top: -4,
                      child: UnreadBadge(count: unreadCount, compact: true),
                    ),
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: ChannelMemberVoiceBadge(
                        voiceState: voiceState,
                        microphoneUnavailable: microphoneUnavailable,
                        speakerUnavailable: speakerUnavailable,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: online ? OsColors.text : OsColors.dim,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (voiceState?.screenSharing == true) ...[
                  Tooltip(
                    message: '正在分享屏幕',
                    child: Semantics(
                      label: '正在分享屏幕',
                      child: const Icon(
                        key: ValueKey('channel-member-screen-share-badge'),
                        Icons.screen_share_rounded,
                        size: 20,
                        color: OsColors.green,
                      ),
                    ),
                  ),
                  if (user.role == 'owner' || user.role == 'admin')
                    const SizedBox(width: 6),
                ],
                ChannelMemberRoleBadge(role: user.role),
                const SizedBox(width: 10),
              ],
            ),
          ),
        ),
      ),
    );
    if (!draggable) return tile;
    return Draggable<PresenceUser>(
      data: user,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: OsColors.rowSelected,
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 208,
          height: 44,
          child: Row(
            children: [
              const SizedBox(width: 16),
              ChannelMemberSpeakingAvatar(
                displayName: displayName,
                online: online,
                voiceState: voiceState,
                avatarUri: user.avatarVersion > 0
                    ? api?.userAvatarUri(
                        user.userId,
                        user.avatarVersion,
                        small: true,
                      )
                    : null,
                avatarToken: avatarToken,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: OsColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: tile),
      child: tile,
    );
  }
}

class ChannelMemberRoleBadge extends StatelessWidget {
  const ChannelMemberRoleBadge({super.key, required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label, key) = switch (role) {
      'owner' => (
        Icons.bookmark_rounded,
        const Color(0xFFFFC928),
        '服主',
        const ValueKey('channel-member-owner-badge'),
      ),
      'admin' => (
        Icons.stars_rounded,
        const Color(0xFF3297F5),
        '管理员',
        const ValueKey('channel-member-admin-badge'),
      ),
      _ => (null, null, null, null),
    };
    if (icon == null || color == null || label == null || key == null) {
      return const SizedBox.shrink();
    }
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: Icon(key: key, icon, size: 20, color: color),
      ),
    );
  }
}

class ChannelMemberVoiceBadge extends StatelessWidget {
  const ChannelMemberVoiceBadge({
    super.key,
    required this.voiceState,
    this.microphoneUnavailable = false,
    this.speakerUnavailable = false,
  });

  final VoiceState? voiceState;
  final bool microphoneUnavailable;
  final bool speakerUnavailable;

  @override
  Widget build(BuildContext context) {
    if (microphoneUnavailable || speakerUnavailable) {
      return Row(
        key: const ValueKey('channel-member-device-unavailable-badge'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (microphoneUnavailable)
            _icon(Icons.mic_off, color: OsColors.danger, label: '未检测到麦克风'),
          if (speakerUnavailable)
            _icon(Icons.volume_off, color: OsColors.danger, label: '未检测到扬声器'),
        ],
      );
    }
    final state = voiceState;
    if (state?.deafened == true) {
      return _icon(Icons.volume_off);
    }
    if (state?.muted == true) {
      return _icon(Icons.mic_off);
    }
    return const SizedBox.shrink();
  }

  Widget _icon(IconData icon, {Color color = OsColors.dim, String? label}) {
    final badge = SizedBox(
      width: 11,
      height: 11,
      child: OverflowBox(
        minWidth: 16,
        maxWidth: 16,
        minHeight: 16,
        maxHeight: 16,
        child: Container(
          decoration: BoxDecoration(
            color: OsColors.sidebar,
            shape: BoxShape.circle,
            border: Border.all(color: OsColors.sidebar, width: 2),
          ),
          child: Icon(icon, size: 11, color: color),
        ),
      ),
    );
    return Semantics(
      label: label,
      child: SizedBox(
        key: const ValueKey('channel-member-voice-badge'),
        child: badge,
      ),
    );
  }
}

class ChannelMemberSpeakingAvatar extends StatefulWidget {
  const ChannelMemberSpeakingAvatar({
    super.key,
    required this.displayName,
    required this.online,
    required this.voiceState,
    this.avatarUri,
    this.avatarToken,
  });

  final String displayName;
  final bool online;
  final VoiceState? voiceState;
  final Uri? avatarUri;
  final String? avatarToken;

  @override
  State<ChannelMemberSpeakingAvatar> createState() =>
      _ChannelMemberSpeakingAvatarState();
}

class _ChannelMemberSpeakingAvatarState
    extends State<ChannelMemberSpeakingAvatar> {
  static const speakingReleaseDelay = Duration(milliseconds: 200);
  Timer? hideTimer;
  late bool showSpeaking;

  bool get speaking =>
      widget.voiceState?.speaking == true &&
      widget.voiceState?.muted != true &&
      widget.voiceState?.deafened != true;

  bool get voiceBlocked =>
      widget.voiceState?.muted == true || widget.voiceState?.deafened == true;

  @override
  void initState() {
    super.initState();
    showSpeaking = speaking;
  }

  @override
  void didUpdateWidget(covariant ChannelMemberSpeakingAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (voiceBlocked) {
      hideTimer?.cancel();
      if (showSpeaking) setState(() => showSpeaking = false);
      return;
    }
    if (speaking) {
      hideTimer?.cancel();
      if (!showSpeaking) setState(() => showSpeaking = true);
      return;
    }
    if (!showSpeaking || hideTimer?.isActive == true) return;
    hideTimer = Timer(speakingReleaseDelay, () {
      if (!mounted || speaking) return;
      setState(() => showSpeaking = false);
    });
  }

  @override
  void dispose() {
    hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      key: ValueKey(
        showSpeaking
            ? 'channel-member-speaking-avatar-active'
            : 'channel-member-speaking-avatar-idle',
      ),
      duration: showSpeaking
          ? Duration.zero
          : const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: showSpeaking ? OsColors.green : Colors.transparent,
          width: 2,
        ),
      ),
      child: OsUserAvatar(
        displayName: widget.displayName,
        size: 30,
        avatarUri: widget.avatarUri,
        avatarToken: widget.avatarToken,
        backgroundColor: widget.online
            ? OsColors.blurple
            : const Color(0xFF36393F),
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.online});
  final bool online;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: online ? OsColors.green : const Color(0xFF747F8D),
        shape: BoxShape.circle,
      ),
    );
  }
}

class SectionDividerTitle extends StatelessWidget {
  const SectionDividerTitle({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Flexible(child: Container(height: 1, color: OsColors.rowHover)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                text.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: sectionStyle,
              ),
            ),
          ),
          Flexible(child: Container(height: 1, color: OsColors.rowHover)),
        ],
      ),
    );
  }
}

class DiscordEmptyRow extends StatelessWidget {
  const DiscordEmptyRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return DiscordListRow(
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: OsColors.rowHover,
        child: Icon(icon, color: OsColors.dim),
      ),
      title: title,
      subtitle: subtitle,
    );
  }
}

class DiscordVoiceRow extends StatelessWidget {
  const DiscordVoiceRow({super.key, required this.state});
  final VoiceState state;

  @override
  Widget build(BuildContext context) {
    final name = state.displayName.isEmpty ? state.userId : state.displayName;
    return DiscordListRow(
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: state.speaking ? OsColors.green : OsColors.blurple,
            child: Text(
              initials(name).substring(0, 1),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: StatusDot(online: state.speaking),
          ),
        ],
      ),
      title: name,
      subtitle:
          "麦克风${state.muted ? '关闭' : '开启'} · 收听${state.deafened ? '关闭' : '开启'}",
      trailing: Icon(
        state.muted ? Icons.mic_off : Icons.mic,
        color: OsColors.muted,
        size: 20,
      ),
    );
  }
}

class DiscordPresenceRow extends StatelessWidget {
  const DiscordPresenceRow({super.key, required this.user});
  final PresenceUser user;

  @override
  Widget build(BuildContext context) {
    final name = user.displayName.isEmpty ? user.userId : user.displayName;
    return DiscordListRow(
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: OsColors.blurple,
            child: Text(
              initials(name).substring(0, 1),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          const Positioned(right: 0, bottom: 0, child: StatusDot(online: true)),
        ],
      ),
      title: name,
      subtitle: '${user.devices.length} device(s)',
    );
  }
}

class DiscordEventRow extends StatelessWidget {
  const DiscordEventRow({super.key, required this.event});
  final RealtimeEvent event;

  @override
  Widget build(BuildContext context) {
    return DiscordListRow(
      leading: const CircleAvatar(
        radius: 20,
        backgroundColor: OsColors.rowHover,
        child: Icon(Icons.bolt, color: Color(0xFFF0B232)),
      ),
      title: event.type,
      subtitle: '实时事件',
    );
  }
}

class DiscordNoticeRow extends StatelessWidget {
  const DiscordNoticeRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.iconColor = OsColors.muted,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return DiscordListRow(
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: OsColors.rowHover,
        child: Icon(icon, color: iconColor),
      ),
      title: title,
      subtitle: subtitle,
      trailing: trailing,
    );
  }
}

class DiscordListRow extends StatelessWidget {
  const DiscordListRow({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {},
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: OsColors.rowHover)),
          ),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: OsColors.text,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: OsColors.muted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

class VoiceControlButton extends StatelessWidget {
  const VoiceControlButton({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: NoWrapText(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? Colors.white : OsColors.muted,
        backgroundColor: selected ? OsColors.green : Colors.transparent,
        side: BorderSide(color: selected ? OsColors.green : OsColors.rowHover),
        minimumSize: const Size(104, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    );
  }
}

class StateCard extends StatelessWidget {
  const StateCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 168,
      height: 86,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF3F4147)),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFFB5BAC1)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFB5BAC1),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DecoratedPanel extends StatelessWidget {
  const DecoratedPanel({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF3F4147)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: sectionStyle),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class VoiceStateRow extends StatelessWidget {
  const VoiceStateRow({super.key, required this.state});
  final VoiceState state;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: StatusDot(online: state.speaking),
      title: Text(state.displayName.isEmpty ? state.userId : state.displayName),
      subtitle: Text(
        "麦克风${state.muted ? '关闭' : '开启'} · 收听${state.deafened ? '关闭' : '开启'}",
        style: const TextStyle(color: Color(0xFFB5BAC1)),
      ),
      trailing: Icon(state.muted ? Icons.mic_off : Icons.mic, size: 18),
    );
  }
}

class EventRow extends StatelessWidget {
  const EventRow({super.key, required this.event});
  final RealtimeEvent event;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          const Icon(Icons.bolt, size: 16, color: Color(0xFFF0B232)),
          const SizedBox(width: 8),
          Expanded(child: Text(event.type, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

class MemberSection extends StatelessWidget {
  const MemberSection({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Text(title, style: sectionStyle),
        ),
        ...children,
      ],
    );
  }
}

class PresenceUserTile extends StatelessWidget {
  const PresenceUserTile({super.key, required this.user});
  final PresenceUser user;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: const StatusDot(online: true),
      title: Text(
        user.displayName.isEmpty ? user.userId : user.displayName,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${user.devices.length} device(s)',
        style: const TextStyle(color: Color(0xFFB5BAC1)),
      ),
    );
  }
}

class ChannelMemberTile extends StatelessWidget {
  const ChannelMemberTile({super.key, required this.member});
  final ChannelMember member;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.person, size: 18, color: Color(0xFFB5BAC1)),
      title: Text(member.userId, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        member.role,
        style: const TextStyle(color: Color(0xFFB5BAC1)),
      ),
    );
  }
}

class EmptyText extends StatelessWidget {
  const EmptyText(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Text(text, style: const TextStyle(color: Color(0xFF949BA4))),
    );
  }
}
