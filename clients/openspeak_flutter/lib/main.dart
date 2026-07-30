import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart' show CupertinoPage;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show BrowserContextMenu, Clipboard, ClipboardData;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:path_provider/path_provider.dart';
import 'add_server_dialog.dart';
import 'attachment_cache_service.dart';
import 'attachment_download_service.dart';
import 'attachment_transfer_controller.dart';
import 'attachment_upload_service.dart';
import 'audio_attachment_metadata.dart';
import 'audio_device_monitor.dart';
import 'audio_playback_controller.dart';
import 'browser_actions.dart';
import 'channel_key_controller.dart';
import 'channel_message_store.dart';
import 'chat_attachment_widgets.dart';
import 'chat_message_widgets.dart';
import 'client_audio_preferences.dart';
import 'client_audio_settings.dart';
import 'client_link_preview.dart';
import 'client_log.dart';
import 'client_session_store.dart';
import 'clipboard_image.dart';
import 'device_identity_service.dart';
import 'direct_message.dart';
import 'local_profile_service.dart';
import 'microphone_activation.dart';
import 'openspeak_api.dart';
import 'os_avatar.dart';
import 'os_context_menu.dart';
import 'os_settings_shell.dart';
import 'os_theme.dart';
import 'owner_identity_service.dart';
import 'platform_open.dart';
import 'realtime_connection_controller.dart';
import 'responsive_layout.dart';
import 'saved_server_connection.dart';
import 'screen_share.dart';
import 'server_navigation_widgets.dart';
import 'server_settings.dart';
import 'smooth_scroll.dart';
import 'sound_effects.dart';
import 'unread_state_controller.dart';
import 'voice_controls.dart';
import 'voice_session_controller.dart';

export 'channel_key_controller.dart' show mediaEncryptionScope;
export 'direct_message.dart' show directEncryptionScope;

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
const unsupportedBrowserScreenShareMessage = '当前手机浏览器不支持屏幕共享';

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

bool realtimeReconnectTargetIsCurrent({
  required int expectedConnectionGeneration,
  required int currentConnectionGeneration,
  required String expectedServerId,
  required String? currentServerId,
  required String? expectedSavedConnectionId,
  required String? currentSavedConnectionId,
}) =>
    expectedConnectionGeneration == currentConnectionGeneration &&
    expectedServerId == currentServerId &&
    expectedSavedConnectionId == currentSavedConnectionId;

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
  final channelScrollController = ScrollController();
  final mobileChannelScrollController = ScrollController();
  final mobileNavigatorKey = GlobalKey<NavigatorState>();
  final messageController = TextEditingController();
  final messageScrollController = ScrollController();
  final attachmentCache = AttachmentCacheService();
  late final AttachmentDownloadService attachmentDownloads;
  late final AttachmentUploadService attachmentUploads;
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
  int guardedActionCount = 0;
  bool get loading => guardedActionCount > 0;
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
  final channelMessageStore = ChannelMessageStore();
  late final ChannelKeyController channelKeyController;
  late final DirectMessageKeyController directMessageKeys;
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
  int realtimeReconnectAttempt = 0;
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
    channelKeyController = ChannelKeyController(deviceIdentity);
    directMessageKeys = DirectMessageKeyController(deviceIdentity);
    attachmentDownloads = AttachmentDownloadService(
      attachmentCache,
      deviceIdentity,
    );
    attachmentUploads = AttachmentUploadService(deviceIdentity);
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
    channelScrollController.dispose();
    mobileChannelScrollController.dispose();
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
      });
      await showWebRtcWarningIfNeeded();
      if (!isActiveConnectionGeneration(generation)) return;
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
      channelKeyController.clear();
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
      error = null;
    });
    await audioPlayback.stop();
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
      channelKeyController.clear();
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

  Future<void> loadChannel(
    Channel channel, {
    bool join = false,
    bool awaitHistory = true,
  }) async {
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
      final messageLoad = runGuarded(
        () => loadChannelMessages(channel: channel),
      );
      if (awaitHistory) {
        await messageLoad;
      } else {
        unawaited(messageLoad);
      }
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
    final reconnectConnectionGeneration =
        expectedConnectionGeneration ?? connectionGeneration;
    final reconnectServerId = server.id;
    final reconnectSavedConnectionId = selectedConnection?.id;
    bool reconnectTargetIsCurrent() =>
        mounted &&
        realtimeReconnectTargetIsCurrent(
          expectedConnectionGeneration: reconnectConnectionGeneration,
          currentConnectionGeneration: connectionGeneration,
          expectedServerId: reconnectServerId,
          currentServerId: selectedServer?.id,
          expectedSavedConnectionId: reconnectSavedConnectionId,
          currentSavedConnectionId: selectedConnection?.id,
        );
    return realtimeConnection.connect(
      open: () => client.openWebSocket(auth.token, dev.id, server.id),
      canActivate: reconnectTargetIsCurrent,
      handleEvent: handleRealtimeEvent,
      onError: (exception, stackTrace) {
        ClientLog.error('realtime.websocket', exception, stackTrace);
        if (reconnectTargetIsCurrent()) {
          setState(() => error = 'WebSocket disconnected: $exception');
        }
      },
      onDisconnected: (generation, closeCode, closeReason) {
        if (!mounted) return;
        ClientLog.write(
          'realtime.websocket',
          'closed code=$closeCode reason=${closeReason ?? ''}',
        );
        unawaited(
          reconnectWebSocketAfterDrop(
            generation,
            expectedConnectionGeneration: reconnectConnectionGeneration,
            expectedServerId: reconnectServerId,
            expectedSavedConnectionId: reconnectSavedConnectionId,
          ),
        );
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

  Future<void> reconnectWebSocketAfterDrop(
    int socketGeneration, {
    required int expectedConnectionGeneration,
    required String expectedServerId,
    required String? expectedSavedConnectionId,
  }) async {
    bool reconnectTargetIsCurrent() =>
        mounted &&
        realtimeReconnectTargetIsCurrent(
          expectedConnectionGeneration: expectedConnectionGeneration,
          currentConnectionGeneration: connectionGeneration,
          expectedServerId: expectedServerId,
          currentServerId: selectedServer?.id,
          expectedSavedConnectionId: expectedSavedConnectionId,
          currentSavedConnectionId: selectedConnection?.id,
        );
    if (!reconnectTargetIsCurrent()) return;
    final attempt = ++realtimeReconnectAttempt;
    bool targetIsCurrent() =>
        attempt == realtimeReconnectAttempt && reconnectTargetIsCurrent();
    bool canRetry() =>
        targetIsCurrent() &&
        realtimeConnection.isCurrent(socketGeneration) &&
        !realtimeConnection.connected;
    var delay = const Duration(milliseconds: 500);
    while (canRetry()) {
      await Future<void>.delayed(delay);
      if (!canRetry()) return;
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
          expectedConnectionGeneration,
        );
        return;
      } on OpenSpeakException catch (exception, stackTrace) {
        if (!targetIsCurrent()) return;
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
        if (!targetIsCurrent()) return;
        ClientLog.error('realtime.restore', exception, stackTrace);
        if (!realtimeConnection.isCurrent(socketGeneration)) {
          await realtimeConnection.closeForRetry();
        } else {
          try {
            await client.listServers(auth.token);
          } on OpenSpeakException catch (probeError) {
            if (probeError.statusCode == HttpStatus.unauthorized ||
                probeError.statusCode == HttpStatus.forbidden ||
                probeError.code == 'https_required' ||
                probeError.code == 'http_required') {
              if (!targetIsCurrent()) return;
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
      if (!canRetry()) return;
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

  void resetChannelKeyCoordination() {
    channelEnvelopeRefreshTimer?.cancel();
    channelEnvelopeRefreshTimer = null;
    channelKeyController.resetCoordination();
  }

  void handleChannelEnvelopeCreated(RealtimeEvent event, {bool media = false}) {
    final epochId = event.payload['epoch_id'] as String? ?? '';
    if (event.channelId.isEmpty || epochId.isEmpty) return;
    channelKeyController.handleEnvelopeCreated(
      event.channelId,
      epochId,
      media: media,
    );
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
    final client = api;
    final auth = session;
    final identity = e2eeDeviceIdentity;
    if (client == null || auth == null || identity == null) {
      throw OpenSpeakException('当前设备没有端到端加密密钥');
    }
    return channelKeyController.ensureKey(
      api: client,
      token: auth.token,
      identity: identity,
      channelId: channel.id,
      epochId: epochId,
      media: media,
    );
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
      await channelKeyController.handleKeyRequest(
        api: client,
        token: auth.token,
        identity: identity,
        channelId: channel.id,
        media: media,
      );
    } catch (exception, stackTrace) {
      ClientLog.error('e2ee.key_request', exception, stackTrace);
    }
  }

  Future<void> handleChannelEpochChanged(RealtimeEvent event) async {
    final channel = channels
        .where((item) => item.id == event.channelId)
        .firstOrNull;
    if (channel == null) return;
    channelKeyController.clearChannel(channel.id);
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
          channelKeyController.clearChannel(channel.id);
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

  Future<PreparedDirectEncryption> prepareDirectEncryption(
    String peerUserId,
  ) async {
    final client = api;
    final auth = session;
    final server = selectedServer;
    final identity = e2eeDeviceIdentity;
    if (client == null || auth == null || server == null || identity == null) {
      throw OpenSpeakException('私聊加密设备尚未就绪');
    }
    return directMessageKeys.prepare(
      api: client,
      token: auth.token,
      serverId: server.id,
      currentUserId: auth.user.id,
      peerUserId: peerUserId,
      identity: identity,
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
        final key = await directMessageKeys.unwrapAndCache(
          identity: e2eeDeviceIdentity,
          event: event,
        );
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

  Future<void> handleClipboardImagePaste(ClipboardImageData image) async {
    if (!mounted || image.bytes.isEmpty) return;
    final direct = chatScope == ChatScope.direct;
    final channel = selectedChannel;
    final peer = selectedDirectUser();
    final targetId = direct ? peer?.userId : channel?.id;
    final permission = direct
        ? 'direct.send_image'
        : 'channel.messages.send_image';
    if (targetId == null || !hasServerPermission(permission)) return;
    final destination = direct
        ? '私聊 ${displayNameForUser(peer!.userId)}'
        : '# ${channel!.name}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF232327),
        title: const Text('发送剪贴板图片？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 220,
                width: double.infinity,
                child: Image.memory(
                  image.bytes,
                  fit: BoxFit.contain,
                  cacheWidth:
                      (480 * MediaQuery.devicePixelRatioOf(dialogContext))
                          .round(),
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(Icons.broken_image_outlined, size: 48),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('发送到 $destination'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final targetUnchanged = direct
        ? chatScope == ChatScope.direct &&
              selectedDirectUser()?.userId == targetId
        : chatScope == ChatScope.channel && selectedChannel?.id == targetId;
    if (!targetUnchanged || !hasServerPermission(permission)) {
      setState(() => error = '聊天目标或发送权限已变化，请重新粘贴');
      return;
    }

    final mimeType = image.mimeType.trim().isEmpty
        ? 'image/png'
        : image.mimeType;
    final name =
        'clipboard-${DateTime.now().microsecondsSinceEpoch}.'
        '${clipboardImageFileExtension(mimeType)}';
    File? temporaryFile;
    try {
      final XFile file;
      if (kIsWeb) {
        file = XFile.fromData(image.bytes, name: name, mimeType: mimeType);
      } else {
        temporaryFile = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'openspeak-$name',
        );
        await temporaryFile.writeAsBytes(image.bytes, flush: true);
        file = XFile(temporaryFile.path, name: name, mimeType: mimeType);
      }
      if (!mounted) {
        await temporaryFile?.delete();
        return;
      }
      enqueueAttachmentUploads(
        [file],
        direct: direct,
        targetId: targetId,
        temporary: temporaryFile != null,
      );
    } catch (exception) {
      try {
        await temporaryFile?.delete();
      } catch (_) {}
      if (mounted) setState(() => error = '读取剪贴板图片失败: $exception');
    }
  }

  void enqueueAttachmentUploads(
    List<XFile> files, {
    required bool direct,
    required String targetId,
    bool temporary = false,
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
            temporary: temporary,
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
      if (mode == 'e2ee' &&
          !channels.any((channel) => channel.id == task.targetId)) {
        throw OpenSpeakException('频道不存在');
      }
      result = await attachmentUploads.uploadChannel(
        api: client,
        token: auth.token,
        channelId: task.targetId,
        file: file,
        fileLength: fileLength,
        image: task.image,
        encryptionMode: mode,
        identity: e2eeDeviceIdentity,
        channelKeys: channelKeyController,
        onProgress: (sent, total) => updateTransferProgress(task, sent, total),
        cancelToken: task.cancelToken,
      );
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
        temporary: task.temporary,
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
    try {
      final mode = selectedServer?.encryptionMode ?? 'none';
      directFile = await attachmentUploads.uploadDirect(
        api: client,
        token: auth.token,
        serverId: selectedServer?.id ?? '',
        currentUserId: auth.user.id,
        peerUserId: task.targetId,
        file: file,
        fileLength: fileLength,
        encryptionMode: mode,
        identity: e2eeDeviceIdentity,
        directMessageKeys: directMessageKeys,
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
    }
    if (!kIsWeb) {
      await seedUploadedAttachmentCache(
        file: File(file.path),
        fileId: directFile.id,
        originalName: directFile.originalName,
        sizeBytes: fileLength,
        temporary: task.temporary,
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
    bool temporary = false,
  }) async {
    if (fileId.isEmpty) return;
    registerLocalAttachmentSource(fileId, file, expectedSizeBytes: sizeBytes);
    final seed = attachmentCache.seedFromLocalFile(
      fileId: fileId,
      originalName: originalName,
      source: file,
      expectedSizeBytes: sizeBytes,
    );
    if (!temporary) {
      unawaited(seed.catchError((_) => File('')));
      return;
    }
    try {
      final cached = await seed;
      registerLocalAttachmentSource(
        fileId,
        cached,
        expectedSizeBytes: sizeBytes,
      );
    } catch (_) {
      attachmentTransfers.localSources.remove(fileId);
    }
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
    try {
      return await attachmentDownloads.ensureCached(
        api: api,
        token: auth.token,
        attachment: attachment,
        localSource: attachmentTransfers.localSources[attachment.fileId],
        loadKey: () => loadAttachmentKey(attachment),
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

  Future<SecretKey?> loadAttachmentKey(ChatAttachment attachment) async {
    if (attachment.direct) {
      return directMessageKeys.keyFor(attachment.epochId);
    }
    final channel = channels
        .where((item) => item.id == attachment.channelId)
        .firstOrNull;
    return channel == null
        ? null
        : ensureChannelKey(channel, epochId: attachment.epochId);
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
    return attachmentDownloads.downloadBytes(
      api: client,
      token: auth.token,
      attachment: attachment,
      loadKey: () => loadAttachmentKey(attachment),
      onProgress: onProgress,
      cancelToken: cancelToken,
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
            size: await readImageSizeBytes(bytes),
          );
        }
        final file = await ensureAttachmentCached(attachment);
        final size = await readImageSize(file);
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
    final channel = !attachment.encrypted || attachment.direct
        ? null
        : channels.where((item) => item.id == attachment.channelId).firstOrNull;
    if (client == null ||
        auth == null ||
        (attachment.encrypted && !attachment.direct && channel == null)) {
      throw OpenSpeakException(attachment.encrypted ? '无法读取加密附件' : '未连接服务器');
    }
    return attachmentDownloads.readRange(
      api: client,
      token: auth.token,
      attachment: attachment,
      start: start,
      endInclusive: endInclusive,
      loadKey: () => loadAttachmentKey(attachment),
      rangeClient: rangeClient,
    );
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

    final result = await showDialog<ServerSettingsDialogResult>(
      context: context,
      barrierColor: const Color(0xC7000000),
      builder: (_) => OsServerSettingsDialog(
        api: client,
        authToken: auth.token,
        serverId: server.id,
        serverName: serverName,
        server: settingsServer,
        channels: channels,
        mediaNodes: mediaNodes,
        fileNodes: fileNodes,
        permissionSettings: permissionSettings,
        currentMessageRetractWindowMinutes: messageRetractWindowMinutes,
        webSettings: webSettings,
        ownerStatus: ownerStatus,
        isOwner: isOwner,
        canEditProfile: canEditProfile,
        allowedPages: allowedPages,
        initialPage: initialPage,
        cachedServerAvatar: cachedServerAvatar,
      ),
    );
    if (result == null) return;
    switch (result.action) {
      case 'save-overview':
        await applyServerProfile(
          result.serverName,
          avatarFile: result.avatarFile,
        );
      case 'save-general':
        final retentionDays = int.tryParse(result.historyRetentionDays);
        if (retentionDays == null || result.defaultChannelId == null) {
          if (mounted) setState(() => error = '请填写有效的历史保留天数和默认频道');
          return;
        }
        await runGuarded(() async {
          final password = result.password;
          final updated = await client.updateServerGeneralSettings(
            auth.token,
            server.id,
            historyRetentionDays: retentionDays,
            defaultChannelId: result.defaultChannelId!,
            serverPassword: !result.clearServerPassword && password.isNotEmpty
                ? password
                : null,
            clearServerPassword: result.clearServerPassword,
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
              result.screenShareBitrates[(resolution, fps)]!,
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
          if (result.attachmentMode == 'external') {
            selectedFileNode = fileNodes
                .where((node) => node.id == result.selectedFileNodeId)
                .firstOrNull;
            nextFileNodeUrl = externalFileNodeUrl(
              host: result.fileNodeHost,
              port: result.fileNodePort,
              path: result.fileNodePath,
            );
            if ((selectedFileNode == null || !selectedFileNode.secretSet) &&
                result.fileNodeSecret.isEmpty) {
              throw OpenSpeakException('首次配置外部附件节点需要填写节点密钥');
            }
          }
          if (result.screenRelayMode == 'external') {
            final existing = mediaNodes
                .where((node) => node.id == result.selectedMediaNodeId)
                .firstOrNull;
            nextMediaNodeUrl = externalLiveKitUrl(
              host: result.mediaNodeHost,
              port: result.mediaNodePort,
              path: result.mediaNodePath,
            );
            if (result.mediaNodeKey.trim().isEmpty) {
              throw OpenSpeakException('请填写 LiveKit API Key');
            }
            if (existing == null && result.mediaNodeSecret.isEmpty) {
              throw OpenSpeakException('新建外部屏幕共享节点需要填写 API Secret');
            }
          }
          var transportClient = client;
          final identifier = result.tlsIdentifier.trim();
          if (result.encryptionMode == 'none' &&
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
            if (pending.confirmationToken.isEmpty || pending.plainUrl.isEmpty) {
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
              result.encryptionMode != 'none' &&
              (settingsServer.tlsStatus != 'active' ||
                  settingsServer.tlsCertificateType !=
                      result.tlsCertificateType ||
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
              certificateType: result.tlsCertificateType,
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
              encryptionMode: result.encryptionMode,
              voiceAudioBitrateKbps: result.voiceAudioBitrateKbps,
              screenShareBitrateLimits: screenShareBitrateLimits,
            );
          } else {
            updated = await client.updateServerVoiceTransport(
              auth.token,
              server.id,
              encryptionMode: result.encryptionMode,
              voiceAudioBitrateKbps: result.voiceAudioBitrateKbps,
              screenShareBitrateLimits: screenShareBitrateLimits,
            );
          }
          await applyScreenRelaySettings(
            transportClient,
            auth,
            server,
            nodes: mediaNodes,
            external: result.screenRelayMode == 'external',
            selectedNodeId: result.selectedMediaNodeId,
            name: result.mediaNodeName,
            liveKitUrl: nextMediaNodeUrl ?? '',
            apiKey: result.mediaNodeKey.trim(),
            apiSecret: result.mediaNodeSecret,
          );
          var attachmentFileNodeId = result.selectedFileNodeId;
          if (result.attachmentMode == 'external') {
            final node = selectedFileNode == null
                ? await transportClient.createFileNode(
                    auth.token,
                    server.id,
                    name: '外部附件节点',
                    baseUrl: nextFileNodeUrl!,
                    secret: result.fileNodeSecret,
                  )
                : await transportClient.updateFileNode(
                    auth.token,
                    server.id,
                    selectedFileNode.id,
                    baseUrl: nextFileNodeUrl!,
                    secret: result.fileNodeSecret.isEmpty
                        ? null
                        : result.fileNodeSecret,
                    enabled: true,
                  );
            attachmentFileNodeId = node.id;
          }
          updated = await transportClient.setExternalAttachments(
            auth.token,
            server.id,
            enabled: result.attachmentMode == 'external',
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
            admin: result.adminPermissions,
            user: result.userPermissions,
            messageRetractWindowMinutes: result.messageRetractWindowMinutes,
          );
          await refreshServerState();
        });
      case 'save-web':
        await runGuarded(() async {
          await client.updateWebSettings(
            auth.token,
            server.id,
            enabled: result.webEnabled,
            customPathEnabled: result.webCustomPathEnabled,
            path: result.webPath.trim(),
          );
          if (mounted) {
            setState(() => error = null);
          }
        });
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
          builder: (_) => const ScreenShareSourceDialog(),
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
    if (!mounted) return;
    setState(() {
      guardedActionCount += 1;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) {
        setState(() => guardedActionCount -= 1);
      } else {
        guardedActionCount -= 1;
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
    return SafeArea(
      child: NavigatorPopHandler<void>(
        onPopWithResult: (_) {
          final navigator = mobileNavigatorKey.currentState;
          if (navigator != null) unawaited(navigator.maybePop());
        },
        child: Navigator(
          key: mobileNavigatorKey,
          pages: <Page<dynamic>>[
            CupertinoPage<void>(
              key: const ValueKey('mobile-home'),
              child: ColoredBox(
                color: OsColors.content,
                child: Column(
                  children: [
                    Expanded(
                      child: RepaintBoundary(
                        child: mobileTabIndex == 0
                            ? buildMobileChannelList()
                            : buildMobileDirectList(),
                      ),
                    ),
                    RepaintBoundary(child: buildMobileVoiceStatusBar()),
                    RepaintBoundary(child: buildMobileNavigationBar()),
                  ],
                ),
              ),
            ),
            if (mobileChatOpen)
              CupertinoPage<void>(
                key: const ValueKey('mobile-chat'),
                child: ColoredBox(
                  color: OsColors.content,
                  child: RepaintBoundary(
                    child: buildMainPane(onBack: closeMobileChat),
                  ),
                ),
              ),
          ],
          onDidRemovePage: (page) {
            if (page.key == const ValueKey('mobile-chat') &&
                mobileChatOpen &&
                mounted) {
              setState(() => mobileChatOpen = false);
            }
          },
        ),
      ),
    );
  }

  void closeMobileChat() {
    final navigator = mobileNavigatorKey.currentState;
    if (navigator == null) {
      if (mobileChatOpen) {
        setState(() => mobileChatOpen = false);
      }
      return;
    }
    unawaited(navigator.maybePop());
  }

  Widget buildAudioNowPlayingControl({required bool compact}) {
    final attachment = audioPlayback.selectedAttachment;
    if (attachment == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(left: compact ? 8 : 12),
      child: AudioNowPlayingControl(
        key: const ValueKey('audio-now-playing-control'),
        attachment: attachment,
        metadataFuture: loadAudioMetadata(attachment),
        loading: audioPlayback.loadingFileId == attachment.fileId,
        playing:
            audioPlayback.activeFileId == attachment.fileId &&
            audioPlayback.playing,
        position: audioPlayback.position,
        duration: audioPlayback.duration,
        compact: compact,
        onToggle: () => unawaited(toggleAudioAttachment(attachment)),
      ),
    );
  }

  Widget buildMobileServerHeader() {
    final server = selectedServer;
    if (server == null) return const SizedBox.shrink();
    return Container(
      height: 58,
      padding: const EdgeInsets.only(left: 14, right: 16),
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
          buildAudioNowPlayingControl(compact: true),
        ],
      ),
    );
  }

  Future<void> openMobileChannel(Channel channel, {bool join = false}) async {
    await loadChannel(channel, join: join, awaitHistory: false);
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
                : SmoothWheelScroll(
                    controller: mobileChannelScrollController,
                    child: ListView.builder(
                      controller: mobileChannelScrollController,
                      physics: smoothWheelChildPhysics,
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
                  showAvatar: kIsWeb,
                  avatarUri: selectedServer!.avatarVersion > 0
                      ? api?.serverAvatarUri(
                          selectedServer!.id,
                          selectedServer!.avatarVersion,
                          small: true,
                        )
                      : null,
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
    final canSendImage = chatScope == ChatScope.channel
        ? hasServerPermission('channel.messages.send_image')
        : hasServerPermission('direct.send_image');
    final canSendAttachment = chatScope == ChatScope.channel
        ? canSendImage || hasServerPermission('channel.messages.send_file')
        : canSendImage || hasServerPermission('direct.send_file');
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
                buildAudioNowPlayingControl(compact: onBack != null),
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
                    screenShareStageHorizontalInset * 2;
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
            onPasteImage: canSendImage ? handleClipboardImagePaste : null,
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
