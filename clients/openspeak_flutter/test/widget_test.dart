import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:openspeak_flutter/browser_actions.dart';
import 'package:openspeak_flutter/client_log.dart';
import 'package:openspeak_flutter/device_identity_service.dart';
import 'package:openspeak_flutter/main.dart';
import 'package:openspeak_flutter/microphone_activation.dart';
import 'package:openspeak_flutter/openspeak_api.dart';
import 'package:openspeak_flutter/sound_effects.dart';
import 'package:openspeak_flutter/voice_session_controller.dart';

void main() {
  test('browser WebRTC probe accepts a supported environment', () {
    expect(browserSupportsWebRtc(), isTrue);
  });

  test('mobile layout applies only to Web widths below 720', () {
    expect(useMobileWebLayout(isWeb: true, width: 719), isTrue);
    expect(useMobileWebLayout(isWeb: true, width: 720), isFalse);
    expect(useMobileWebLayout(isWeb: false, width: 320), isFalse);
  });

  test('mobile Web chat uses the default list cache extent', () {
    expect(messageListCacheExtent(isWeb: true, width: 719), isNull);
    expect(messageListCacheExtent(isWeb: true, width: 720), 900);
    expect(messageListCacheExtent(isWeb: false, width: 390), 900);
  });

  test(
    'mobile Web image previews decode only to their display pixel width',
    () {
      expect(
        imagePreviewCacheWidth(
          isWeb: true,
          viewportWidth: 390,
          sourceWidth: 4000,
          displayWidth: 360,
          devicePixelRatio: 3,
        ),
        1080,
      );
      expect(
        imagePreviewCacheWidth(
          isWeb: true,
          viewportWidth: 390,
          sourceWidth: 640,
          displayWidth: 360,
          devicePixelRatio: 3,
        ),
        640,
      );
      expect(
        imagePreviewCacheWidth(
          isWeb: true,
          viewportWidth: 720,
          sourceWidth: 4000,
          displayWidth: 360,
          devicePixelRatio: 3,
        ),
        isNull,
      );
    },
  );

  testWidgets('mobile Web plain messages avoid intrinsic text layout', (
    tester,
  ) async {
    if (!kIsWeb) return;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: MessageBodyText(
              body: '可选择的消息',
              mine: false,
              onOpenLink: (_) async {},
            ),
          ),
        ),
      ),
    );

    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(IntrinsicWidth), findsNothing);
    expect(
      tester
          .widget<SelectableText>(find.byType(SelectableText))
          .contextMenuBuilder,
      isNotNull,
    );
  });

  testWidgets('mobile channel card separates chat and voice gestures', (
    tester,
  ) async {
    var opens = 0;
    var joins = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileChannelCard(
            channel: Channel(id: 'one', name: '1', sortOrder: 0),
            selected: false,
            unreadCount: 2,
            mentionCount: 0,
            members: const [],
            voiceStatesByUserId: const {},
            api: null,
            avatarToken: null,
            onOpen: () => opens += 1,
            onDoubleTap: () => joins += 1,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(MobileChannelCard));
    await tester.pumpAndSettle();
    expect(opens, 0);
    expect(joins, 0);
    final openButton = find.byKey(const ValueKey('mobile-channel-open-one'));
    expect(
      find.descendant(
        of: find.byType(MobileChannelCard),
        matching: find.byType(InkWell),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: openButton, matching: find.byType(InkWell)),
      findsOneWidget,
    );

    final openIcon = find.descendant(
      of: openButton,
      matching: find.byIcon(Icons.chevron_right_rounded),
    );
    expect(tester.getSize(openButton), const Size.square(40));
    expect(tester.getSize(openIcon), const Size.square(28));
    expect(tester.getCenter(openIcon), tester.getCenter(openButton));
    expect(
      tester
          .getRect(find.byType(UnreadBadge))
          .overlaps(tester.getRect(openButton)),
      isTrue,
    );
    await tester.tap(openButton);
    await tester.pump();
    expect(opens, 1);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byType(MobileChannelCard));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(MobileChannelCard));
    await tester.pump();
    expect(opens, 1);
    expect(joins, 1);
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('all sound effects are bundled as WAV files', (_) async {
    for (final effect in SoundEffect.values) {
      final bytes = await rootBundle.load('assets/${effect.asset}');
      expect(bytes.lengthInBytes, greaterThan(44), reason: effect.name);
      expect(bytes.buffer.asUint8List(bytes.offsetInBytes, 4), [
        0x52,
        0x49,
        0x46,
        0x46,
      ], reason: effect.name);
    }
  });

  testWidgets('muted speech reminder delays, repeats, and resets', (
    tester,
  ) async {
    var warnings = 0;
    final reminder = MutedSpeechReminder(() => warnings += 1);

    reminder.update(muted: true, listenOff: false, active: true);
    await tester.pump(const Duration(milliseconds: 1499));
    expect(warnings, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(warnings, 1);
    await tester.pump(const Duration(seconds: 10));
    expect(warnings, 2);

    reminder.update(muted: true, listenOff: false, active: false);
    await tester.pump(const Duration(seconds: 2));
    reminder.update(muted: true, listenOff: false, active: true);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(warnings, 3);

    reminder.update(muted: true, listenOff: true, active: true);
    await tester.pump(const Duration(seconds: 12));
    expect(warnings, 3);
    reminder.dispose();
  });

  test('client diagnostics are written to a local log file', () async {
    final directory = await Directory.systemTemp.createTemp('openspeak-log-');
    try {
      await ClientLog.initialize(directory: directory);
      ClientLog.write('test', 'hotplug checkpoint');

      final contents = await File(ClientLog.path!).readAsString();
      expect(contents, contains('[test] hotplug checkpoint'));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('editing a secure server preserves HTTPS and port 443', () {
    expect(serverPortFromUrl('https://voice.example.com'), '443');
    expect(
      serverBaseUrl(host: 'voice.example.com', port: '443', scheme: 'https'),
      'https://voice.example.com:443',
    );
    expect(
      serverBaseUrl(host: 'voice.example.com', port: '443'),
      'https://voice.example.com:443',
    );
    expect(
      serverBaseUrl(host: 'https://voice.example.com', port: '443'),
      'https://voice.example.com:443',
    );
    expect(serverPortFromUrl('https://voice.example.com:27412'), '27412');
  });

  test('legacy 443 connections fall back to plaintext discovery only', () {
    expect(
      legacyPlainDiscoveryBase(Uri.parse('https://voice.example.com')),
      Uri.parse('http://voice.example.com:27410'),
    );
    expect(
      legacyPlainDiscoveryBase(Uri.parse('https://voice.example.com:27410')),
      Uri.parse('http://voice.example.com:27410'),
    );
    expect(
      legacyPlainDiscoveryBase(Uri.parse('https://voice.example.com:27412')),
      isNull,
    );
  });

  test('the public discovery port always starts with plaintext HTTP', () {
    expect(
      serverConnectionUrl(
        host: 'https://voice.example.com',
        port: 27410,
        previousScheme: 'https',
      ),
      'http://voice.example.com:27410',
    );
    expect(
      serverConnectionUrl(
        host: 'voice.example.com',
        port: 27412,
        previousScheme: 'https',
      ),
      'https://voice.example.com:27412',
    );
  });

  test('external file node address uses HTTPS with any valid port', () {
    expect(
      externalFileNodeUrl(host: '203.0.113.10', port: '443'),
      'https://203.0.113.10:443/files',
    );
    expect(
      externalFileNodeUrl(host: 'files.example.com', port: '8443'),
      'https://files.example.com:8443/files',
    );
    expect(
      externalFileNodeUrl(host: 'files.example.com', port: '27420'),
      'https://files.example.com:27420/files',
    );
  });

  test('external LiveKit address uses WSS with the entered port', () {
    expect(
      externalLiveKitUrl(host: '203.0.113.10', port: '27412'),
      'wss://203.0.113.10:27412',
    );
    expect(
      externalLiveKitUrl(
        host: 'screen.example.com',
        port: '8443',
        path: '/rtc',
      ),
      'wss://screen.example.com:8443/rtc',
    );
    expect(
      () => externalLiveKitUrl(host: 'screen.example.com', port: 'invalid'),
      throwsA(isA<OpenSpeakException>()),
    );
  });

  test('server avatar cache downloads only when the version changes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'openspeak-server-avatar-',
    );
    var downloads = 0;
    Future<List<int>> download() async {
      downloads += 1;
      return [downloads, 2, 3];
    }

    try {
      final oldThumbnail = File(
        '${directory.path}${Platform.pathSeparator}srv_test-1.avatar',
      );
      await oldThumbnail.writeAsBytes([9, 9, 9]);
      final first = await ensureServerAvatarCached(
        cacheDir: directory,
        serverId: 'srv_test',
        avatarVersion: 1,
        download: download,
      );
      expect(first.path, endsWith('srv_test-1.original'));
      expect(await oldThumbnail.exists(), isFalse);
      final same = await ensureServerAvatarCached(
        cacheDir: directory,
        serverId: 'srv_test',
        avatarVersion: 1,
        download: download,
      );
      expect(same.path, first.path);
      expect(downloads, 1);

      final changed = await ensureServerAvatarCached(
        cacheDir: directory,
        serverId: 'srv_test',
        avatarVersion: 2,
        download: download,
      );
      expect(downloads, 2);
      expect(await first.exists(), isFalse);
      expect(await changed.readAsBytes(), [2, 2, 3]);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('external attachment fallback only accepts temporary failures', () {
    expect(
      externalAttachmentCanFallback(
        const SocketException('down'),
        sizeBytes: 2,
        localMaxBytes: 2,
      ),
      isTrue,
    );
    expect(
      externalAttachmentCanFallback(
        OpenSpeakException('unavailable', statusCode: 503),
        sizeBytes: 2,
        localMaxBytes: 2,
      ),
      isTrue,
    );
    expect(
      externalAttachmentCanFallback(
        OpenSpeakException('unavailable', statusCode: 503),
        sizeBytes: 3,
        localMaxBytes: 2,
      ),
      isFalse,
    );
    expect(
      externalAttachmentCanFallback(
        OpenSpeakException('too large', statusCode: 413),
        sizeBytes: 2,
        localMaxBytes: 2,
      ),
      isFalse,
    );
    expect(
      externalAttachmentCanFallback(
        const FileSystemException('read failed'),
        sizeBytes: 2,
        localMaxBytes: 2,
      ),
      isFalse,
    );
    expect(legacyLocalAttachmentMaxBytes('image'), 128 * 1024 * 1024);
    expect(legacyLocalAttachmentMaxBytes('file'), 512 * 1024 * 1024);
    expect(
      AttachmentUploadPlan.fromJson({
        'external': true,
        'local_max_bytes': 2 * 1024 * 1024 * 1024,
      }).localMaxBytes,
      2 * 1024 * 1024 * 1024,
    );
  });

  test('desktop audio device monitoring is event-driven', () {
    expect(audioDevicePollInterval(TargetPlatform.macOS), Duration.zero);
    expect(audioDevicePollInterval(TargetPlatform.windows), Duration.zero);
  });

  test('persisted unread state ignores invalid counters', () {
    expect(positiveIntMapFromJson({'channel': 2, 'zero': 0, 'bad': '3'}), {
      'channel': 2,
    });
  });

  testWidgets('upload queue shows every queued file', (tester) async {
    final tasks = [
      TransferTask.upload(
        file: XFile('/tmp/first.png'),
        direct: false,
        targetId: 'channel',
        image: true,
      ),
      TransferTask.upload(
        file: XFile('/tmp/second.txt'),
        direct: false,
        targetId: 'channel',
        image: false,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UploadQueuePanel(
            tasks: tasks,
            onCancel: (_) {},
            onRetry: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('first.png'), findsOneWidget);
    expect(find.text('second.txt'), findsOneWidget);
    expect(find.text('等待上传'), findsNWidgets(2));
  });

  test('direct messages only expose retract for the sender', () {
    expect(
      directMessageContextAction(mine: true, pending: false),
      ChannelMessageContextAction.retract,
    );
    expect(directMessageContextAction(mine: false, pending: false), isNull);
    expect(directMessageContextAction(mine: true, pending: true), isNull);
  });

  test('direct E2EE scope is symmetric and metadata stays encrypted', () {
    expect(
      directEncryptionScope('srv', 'user_b', 'user_a'),
      directEncryptionScope('srv', 'user_a', 'user_b'),
    );
    final message = DirectMessage.fromEvent(
      RealtimeEvent(
        type: 'direct.message_created',
        serverId: 'srv',
        channelId: '',
        fromUser: 'user_a',
        toUser: 'user_b',
        payload: {
          'id': 'dm_0123456789abcdef01234567',
          'kind': 'file',
          'body': 'fil_cipher',
          'file_id': 'fil_cipher',
          'original_name': 'private.zip',
          'content_type': 'application/zip',
          'size_bytes': 23,
          'ciphertext_size_bytes': 67,
          'encryption_mode': 'e2ee',
          'nonce': 'AAAAAAAAAAA',
          'attachment_format': attachmentEncryptionFormatV1,
        },
        sentAt: DateTime.utc(2026, 7, 17),
      ),
    );
    expect(message.encryptionMode, 'e2ee');
    expect(message.sizeBytes, 23);
    expect(message.ciphertextSizeBytes, 67);
    expect(message.nonce, 'AAAAAAAAAAA');
  });

  test('media E2EE uses a separate envelope scope', () {
    expect(mediaEncryptionScope('chn_test'), 'media:chn_test');
    expect(mediaEncryptionScope('chn_test'), isNot('chn_test'));
  });

  test('retracted direct messages keep their sender and time', () {
    final sentAt = DateTime.utc(2026, 7, 15, 12);
    final removed = DirectMessage(
      id: 'dm_test',
      fromUserId: 'sender',
      toUserId: 'recipient',
      kind: 'text',
      body: 'secret',
      fileId: '',
      originalName: '',
      contentType: '',
      sizeBytes: 0,
      expiresAt: null,
      sentAt: sentAt,
    ).retracted();

    expect(removed.kind, 'removed');
    expect(removed.body, isEmpty);
    expect(removed.fromUserId, 'sender');
    expect(removed.sentAt, sentAt);
  });

  test('invalid server password has a useful client message', () {
    expect(
      apiExceptionMessage(HttpStatus.unauthorized, {
        'error': 'invalid_server_password',
        'message': 'invalid server password',
      }, ''),
      '服务器密码错误，请右键编辑服务器并更新密码',
    );
  });

  test('only web login prompts for an invalid server password', () {
    final invalidPassword = OpenSpeakException(
      'invalid password',
      statusCode: HttpStatus.unauthorized,
      code: 'invalid_server_password',
    );

    expect(webLoginNeedsPasswordPrompt(invalidPassword, isWeb: true), isTrue);
    expect(webLoginNeedsPasswordPrompt(invalidPassword, isWeb: false), isFalse);
    expect(
      webLoginNeedsPasswordPrompt(OpenSpeakException('offline'), isWeb: true),
      isFalse,
    );
  });

  test('API connect retry is limited to the first socket failure', () {
    final error = const SocketException('timed out');

    expect(apiConnectShouldRetry(error, 0), isTrue);
    expect(apiConnectShouldRetry(http.ClientException('offline'), 0), isTrue);
    expect(apiConnectShouldRetry(error, 1), isFalse);
    expect(apiConnectShouldRetry(StateError('response failed'), 0), isFalse);
  });

  test('HTTPS upgrade response exposes the secure server URL', () {
    final error = apiException(HttpStatus.upgradeRequired, {
      'error': 'https_required',
      'message': 'HTTPS required',
      'secure_url': 'https://voice.example.com',
    }, '');
    expect(error.code, 'https_required');
    expect(error.secureUrl, 'https://voice.example.com');
  });

  test('HTTP downgrade response exposes the plaintext server URL', () {
    final error = apiException(HttpStatus.upgradeRequired, {
      'error': 'http_required',
      'message': 'HTTP required',
      'plain_url': 'http://voice.example.com:27410',
    }, '');
    expect(error.code, 'http_required');
    expect(error.plainUrl, 'http://voice.example.com:27410');
  });

  test('API adopts only a valid canonical server base address', () {
    final secureRetry = canonicalServerBaseUri(
      Uri.parse('http://voice.example.com:27410'),
      {'error': 'https_required', 'secure_url': 'https://voice.example.com'},
    );
    final plainRetry = canonicalServerBaseUri(
      Uri.parse('https://voice.example.com'),
      {'error': 'http_required', 'plain_url': 'http://voice.example.com:27410'},
    );

    expect(secureRetry, Uri.parse('https://voice.example.com'));
    expect(plainRetry, Uri.parse('http://voice.example.com:27410'));
    expect(
      canonicalServerBaseUri(Uri.parse('http://voice.example.com'), {
        'error': 'https_required',
        'secure_url': 'http://voice.example.com',
      }),
      isNull,
    );
    expect(
      canonicalServerBaseUri(Uri.parse('https://voice.example.com'), {
        'error': 'http_required',
        'plain_url': 'https://voice.example.com',
      }),
      isNull,
    );
    expect(
      canonicalServerBaseUri(Uri.parse('http://voice.example.com'), {
        'error': 'http_required',
        'plain_url': 'http://attacker.example.com',
      }),
      isNull,
    );
  });

  test('TLS certificate health changes at the 24 hour boundary', () {
    final now = DateTime.utc(2026, 7, 17, 0);
    expect(
      tlsCertificateHealth(now.add(const Duration(hours: 25)), now: now),
      TlsCertificateHealth.valid,
    );
    expect(
      tlsCertificateHealth(now.add(const Duration(hours: 23)), now: now),
      TlsCertificateHealth.expiring,
    );
    expect(
      tlsCertificateHealth(now.subtract(const Duration(seconds: 1)), now: now),
      TlsCertificateHealth.expired,
    );
  });

  test('channel message actions follow sender and manage permission', () {
    expect(
      channelMessageContextAction(
        mine: true,
        canManageOthers: false,
        pending: false,
      ),
      ChannelMessageContextAction.retract,
    );
    expect(
      channelMessageContextAction(
        mine: false,
        canManageOthers: true,
        pending: false,
      ),
      ChannelMessageContextAction.delete,
    );
    expect(
      channelMessageContextAction(
        mine: false,
        canManageOthers: false,
        pending: false,
      ),
      isNull,
    );
    expect(
      channelMessageContextAction(
        mine: true,
        canManageOthers: true,
        pending: true,
      ),
      isNull,
    );
    expect(
      channelMessageContextAction(
        mine: true,
        canManageOthers: false,
        pending: false,
        canRetractOwn: false,
      ),
      isNull,
    );
    expect(
      channelMessageContextAction(
        mine: true,
        canManageOthers: true,
        pending: false,
        canRetractOwn: false,
      ),
      ChannelMessageContextAction.delete,
    );
  });

  test('voice audio publishing disables DTX only on Web', () {
    final desktop = voiceAudioPublishOptions(64, isWeb: false);
    final web = voiceAudioPublishOptions(64, isWeb: true);
    expect(desktop.encoding?.maxBitrate, 64000);
    expect(desktop.dtx, isTrue);
    expect(web.dtx, isFalse);
    expect(web.red, isTrue);
  });

  test('stored Web auth sessions expire without storing the password', () {
    final expiresAt = DateTime.utc(2026, 7, 23, 12);
    final session = AuthSession(
      token: 'jwt',
      user: User(id: 'user', displayName: 'User'),
      expiresAt: expiresAt,
    );
    final encoded = jsonEncode(session);

    expect(encoded, isNot(contains('password')));
    expect(
      AuthSession.fromStorage(
        encoded,
        now: expiresAt.subtract(const Duration(seconds: 1)),
      )?.token,
      'jwt',
    );
    expect(AuthSession.fromStorage(encoded, now: expiresAt), isNull);
    expect(AuthSession.fromStorage('not-json'), isNull);
  });

  test('voice auto-subscription stays disabled while listen-off is active', () {
    expect(voiceShouldAutoSubscribe(listenOff: false), isTrue);
    expect(voiceShouldAutoSubscribe(listenOff: true), isFalse);
    expect(
      voiceShouldAutoSubscribe(listenOff: false, e2eeRequired: true),
      isFalse,
    );
    expect(
      voiceShouldAutoSubscribe(listenOff: false, persistentRoom: true),
      isFalse,
    );
    expect(
      voiceTrackEncryptionAccepted(
        e2eeRequired: true,
        encryptionType: lk.EncryptionType.kNone,
      ),
      isFalse,
    );
    expect(
      voiceTrackEncryptionAccepted(
        e2eeRequired: true,
        encryptionType: lk.EncryptionType.kGcm,
      ),
      isTrue,
    );
  });

  test(
    'Web joins listen-only only when microphone capture finds no device',
    () {
      expect(
        webMicrophoneCaptureCanFallBackToListenOnly(
          'Unable to getUserMedia: NotFoundError: Requested device not found',
          isWeb: true,
        ),
        isTrue,
      );
      expect(
        webMicrophoneCaptureCanFallBackToListenOnly(
          'Unable to getUserMedia: NotAllowedError: Permission denied',
          isWeb: true,
        ),
        isFalse,
      );
      expect(
        webMicrophoneCaptureCanFallBackToListenOnly(
          'Unable to getUserMedia: NotFoundError: Requested device not found',
          isWeb: false,
        ),
        isFalse,
      );
    },
  );

  test('listen-only mode does not keep a microphone track', () {
    expect(
      voiceShouldKeepMicrophoneTrack(
        canPublish: true,
        listenOff: false,
        microphoneUnavailable: false,
      ),
      isTrue,
    );
    expect(
      voiceShouldKeepMicrophoneTrack(
        canPublish: true,
        listenOff: false,
        microphoneUnavailable: true,
      ),
      isFalse,
    );
    expect(
      voiceShouldKeepMicrophoneTrack(
        canPublish: false,
        listenOff: false,
        microphoneUnavailable: false,
      ),
      isFalse,
    );
    expect(
      voiceShouldKeepMicrophoneTrack(
        canPublish: true,
        listenOff: true,
        microphoneUnavailable: false,
      ),
      isFalse,
    );
  });

  test('persistent voice room routes only current channel participants', () {
    const members = {'local', 'same-channel'};
    expect(
      voiceParticipantInCurrentChannel(
        persistentRoom: true,
        channelMemberUserIds: members,
        userId: 'same-channel',
      ),
      isTrue,
    );
    expect(
      voiceParticipantInCurrentChannel(
        persistentRoom: true,
        channelMemberUserIds: members,
        userId: 'other-channel',
      ),
      isFalse,
    );
    expect(
      voiceParticipantInCurrentChannel(
        persistentRoom: false,
        channelMemberUserIds: const {},
        userId: 'other-channel',
      ),
      isTrue,
    );
  });

  test('persistent voice routing uses joined voice states', () {
    final snapshot = PresenceSnapshot(
      serverId: 'server',
      users: [
        PresenceUser(
          userId: 'text-only',
          displayName: '只看文字',
          role: 'user',
          online: true,
          devices: const [],
          currentChannelId: 'channel-a',
        ),
      ],
      voiceStates: [
        VoiceState(
          serverId: 'server',
          userId: 'voice-member',
          displayName: '语音成员',
          channelId: 'channel-a',
          muted: false,
          deafened: false,
          speaking: false,
        ),
        VoiceState(
          serverId: 'server',
          userId: 'other-channel',
          displayName: '其他频道',
          channelId: 'channel-b',
          muted: false,
          deafened: false,
          speaking: false,
        ),
      ],
    );

    expect(
      voiceChannelMemberUserIds(snapshot, 'channel-a', includeUserId: 'local'),
      {'local', 'voice-member'},
    );
  });

  test('microphone sender routing waits for room reconnection', () {
    expect(
      microphoneSenderRoutingAllowed(reconnecting: false, roomConnected: true),
      isTrue,
    );
    expect(
      microphoneSenderRoutingAllowed(reconnecting: true, roomConnected: true),
      isFalse,
    );
    expect(
      microphoneSenderRoutingAllowed(reconnecting: false, roomConnected: false),
      isFalse,
    );
    expect(
      microphoneSenderRoutingAllowed(
        reconnecting: false,
        roomConnected: true,
        roomConnecting: true,
      ),
      isFalse,
    );
  });

  test('persistent room channel switching waits for connection', () {
    expect(
      persistentRoomChannelSwitchAllowed(persistentRoom: true, connected: true),
      isTrue,
    );
    expect(
      persistentRoomChannelSwitchAllowed(
        persistentRoom: true,
        connected: false,
      ),
      isFalse,
    );
    expect(
      persistentRoomChannelSwitchAllowed(
        persistentRoom: false,
        connected: true,
      ),
      isFalse,
    );
  });

  test('failed persistent channel switching falls back to reconnect', () async {
    final calls = <String>[];
    final failure = StateError('switch failed');

    await switchVoiceChannelWithReconnectFallback(
      switchWithoutReconnect: () async => calls.add('switch'),
      reconnect: (_, _) async => calls.add('unexpected reconnect'),
    );
    expect(calls, ['switch']);

    calls.clear();
    await switchVoiceChannelWithReconnectFallback(
      switchWithoutReconnect: () async {
        calls.add('switch');
        throw failure;
      },
      reconnect: (error, _) async {
        expect(identical(error, failure), isTrue);
        calls.add('reconnect');
      },
    );

    expect(calls, ['switch', 'reconnect']);
  });

  test('microphone restart waits for an active room connection', () {
    expect(
      microphoneCaptureRestartShouldDefer(
        roomConnecting: true,
        restartRequested: true,
      ),
      isTrue,
    );
    expect(
      microphoneCaptureRestartShouldDefer(
        roomConnecting: false,
        restartRequested: true,
      ),
      isFalse,
    );
    expect(
      microphoneCaptureRestartShouldDefer(
        roomConnecting: true,
        restartRequested: false,
      ),
      isFalse,
    );
  });

  test(
    'voice room cleanup still disposes after leave signaling fails',
    () async {
      final calls = <String>[];

      await closeVoiceRoom(
        sendLeave: () async {
          calls.add('leave');
          throw StateError('socket closed');
        },
        dispose: () async => calls.add('dispose'),
      );

      expect(calls, ['leave', 'dispose']);
    },
  );

  test(
    'voice room cleanup cancels the room before waiting for routing',
    () async {
      final routing = Completer<void>();
      final disposed = Completer<void>();
      var cleanupCompleted = false;

      final cleanup = closeVoiceRoom(
        sendLeave: () async {},
        dispose: () async => disposed.complete(),
        routingDone: routing.future,
      ).whenComplete(() => cleanupCompleted = true);

      await disposed.future;
      expect(cleanupCompleted, isFalse);
      routing.complete();
      await cleanup;
      expect(cleanupCompleted, isTrue);
    },
  );

  test('rapid channel joins let only the latest request continue', () async {
    final queue = LatestChannelJoinQueue();
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final calls = <String>[];

    final firstGeneration = queue.begin();
    final first = queue.run(firstGeneration, () async {
      calls.add('first');
      firstStarted.complete();
      await releaseFirst.future;
    });
    await firstStarted.future;

    final secondGeneration = queue.begin();
    final second = queue.run(secondGeneration, () async {
      calls.add('second');
    });
    releaseFirst.complete();

    expect(await first, isFalse);
    expect(await second, isTrue);
    expect(calls, ['first', 'second']);
  });

  test('authoritative channel changes only move an active voice session', () {
    expect(
      shouldFollowAuthoritativeVoiceChannel(
        joined: true,
        authoritativeChannelId: 'channel-b',
        localChannelId: 'channel-a',
        switchingTargetId: null,
      ),
      isTrue,
    );
    for (final values in const [
      (false, 'channel-b', 'channel-a', null),
      (true, 'channel-a', 'channel-a', null),
      (true, 'channel-b', 'channel-a', 'channel-b'),
      (true, null, 'channel-a', null),
    ]) {
      expect(
        shouldFollowAuthoritativeVoiceChannel(
          joined: values.$1,
          authoritativeChannelId: values.$2,
          localChannelId: values.$3,
          switchingTargetId: values.$4,
        ),
        isFalse,
      );
    }
  });

  test('new voice join request invalidates an older pending join', () async {
    final controller = VoiceSessionController();
    addTearDown(controller.dispose);
    final first = controller.beginJoinRequest();
    final second = controller.beginJoinRequest();

    expect(controller.isJoinRequestCurrent(first), isFalse);
    expect(controller.isJoinRequestCurrent(second), isTrue);
    await controller.join(
      api: OpenSpeakApi('http://127.0.0.1:27410'),
      authToken: 'unused',
      serverId: 'server',
      channelId: 'old-channel',
      requestGeneration: first,
    );
    expect(controller.snapshot.connecting, isFalse);
    expect(controller.isJoinRequestCurrent(second), isTrue);
  });

  test('voice state recovery distinguishes websocket wait and rejoin', () {
    expect(
      voiceStateSyncShouldRetry(
        OpenSpeakException(
          'HTTP 409: open a server WebSocket connection',
          statusCode: 409,
          code: 'websocket_required',
        ),
      ),
      isTrue,
    );
    expect(
      voiceStateSyncShouldRetry(
        OpenSpeakException(
          'HTTP 409: enter the channel before updating its voice state',
          statusCode: 409,
          code: 'current_channel_required',
        ),
      ),
      isFalse,
    );
    expect(
      voiceStateSyncShouldRejoinChannel(
        OpenSpeakException(
          'HTTP 409: enter the channel before updating its voice state',
          statusCode: 409,
          code: 'current_channel_required',
        ),
      ),
      isTrue,
    );
  });

  test('LiveKit reconnects use capped exponential backoff', () {
    expect(liveKitReconnectDelay(0), const Duration(seconds: 1));
    expect(liveKitReconnectDelay(1), const Duration(seconds: 2));
    expect(liveKitReconnectDelay(5), const Duration(seconds: 30));
    expect(liveKitReconnectDelay(99), const Duration(seconds: 30));
  });

  test('web retries only the missed LiveKit join response timeout', () {
    const timeout =
        'LiveKit Exception: Timed out waiting for SignalJoinResponseEvent';
    expect(
      webLiveKitJoinResponseCanRetry(Exception(timeout), isWeb: true),
      isTrue,
    );
    expect(
      webLiveKitJoinResponseCanRetry(Exception(timeout), isWeb: false),
      isFalse,
    );
    expect(
      webLiveKitJoinResponseCanRetry(Exception('Unauthorized'), isWeb: true),
      isFalse,
    );
  });

  test('room events do not finalize an explicit voice join early', () {
    expect(voiceRoomEventShouldFinalizeSession(connecting: true), isFalse);
    expect(voiceRoomEventShouldFinalizeSession(connecting: false), isTrue);
  });

  test('voice join errors identify the failing phase', () {
    expect(
      voiceJoinFailureStatus(
        liveKitConnected: false,
        syncingVoiceState: false,
        failedUrl: 'wss://voice.example',
      ),
      'LiveKit 连接失败: wss://voice.example',
    );
    expect(
      voiceJoinFailureStatus(liveKitConnected: true, syncingVoiceState: false),
      '语音初始化失败',
    );
    expect(
      voiceJoinFailureStatus(liveKitConnected: true, syncingVoiceState: true),
      '语音状态同步失败',
    );
  });

  test('voice E2EE requires a 32-byte key for the token epoch', () {
    final token = VoiceToken.fromJson({
      'e2ee_required': true,
      'e2ee_epoch_id': 'epc_current',
      'e2ee_key_index': 1,
      'e2ee_key_active': false,
      'media_key_slots': true,
    });
    expect(token.e2eeKeyIndex, 1);
    expect(token.e2eeKeyActive, isFalse);
    expect(token.mediaKeySlots, isTrue);
    final activated = token.copyWith(e2eeKeyActive: true);
    expect(activated.e2eeKeyIndex, 1);
    expect(activated.e2eeKeyActive, isTrue);
    expect(
      voiceE2EEConfigurationValid(
        token: token,
        key: Uint8List(32),
        deviceId: 'dev_current',
        epochId: 'epc_current',
      ),
      isTrue,
    );
    expect(
      voiceE2EEConfigurationValid(
        token: token,
        key: Uint8List(31),
        deviceId: 'dev_current',
        epochId: 'epc_current',
      ),
      isFalse,
    );
    expect(
      voiceE2EEConfigurationValid(
        token: VoiceToken.fromJson({
          'e2ee_required': true,
          'e2ee_epoch_id': 'epc_current',
          'e2ee_key_index': 2,
        }),
        key: Uint8List(32),
        deviceId: 'dev_current',
        epochId: 'epc_current',
      ),
      isFalse,
    );
    expect(
      voiceE2EEConfigurationValid(
        token: token,
        key: Uint8List(32),
        deviceId: 'dev_current',
        epochId: 'epc_stale',
      ),
      isFalse,
    );
    expect(
      voiceE2EEConfigurationValid(
        token: VoiceToken.fromJson({'e2ee_required': false}),
        key: Uint8List(32),
        deviceId: 'dev_current',
        epochId: 'epc_current',
      ),
      isFalse,
    );
    expect(
      voiceE2EEKeyProviderOptions().discardFrameWhenCryptorNotReady,
      isTrue,
    );
    final participantToken = VoiceToken.fromJson({
      'e2ee_required': true,
      'e2ee_epoch_id': 'epc_current',
      'room_scope': 'server',
      'e2ee_participant_keys': true,
    });
    expect(voiceE2EEUsesParticipantKeys(participantToken), isTrue);
    expect(
      voiceE2EEConfigurationValid(
        token: participantToken,
        key: Uint8List(32),
        deviceId: 'dev_current',
        epochId: 'epc_current',
      ),
      isTrue,
    );
    expect(
      voiceE2EEConfigurationValid(
        token: VoiceToken.fromJson({
          'e2ee_required': true,
          'e2ee_epoch_id': 'epc_current',
          'room_scope': 'server',
        }),
        key: Uint8List(32),
        deviceId: 'dev_current',
        epochId: 'epc_current',
      ),
      isFalse,
    );
    expect(voiceE2EEKeyProviderOptions(sharedKey: false).sharedKey, isFalse);
  });

  test('screen-share routing metadata survives API parsing', () {
    final token = ScreenShareToken.fromJson({
      'url': 'wss://screen.example',
      'token': 'jwt',
      'room': 'openspeak_screen_srv_1_chn_1',
      'channel_id': 'chn_1',
      'publisher_user_id': 'usr_1',
      'media_node_id': 'med_1',
      'e2ee_required': true,
      'e2ee_epoch_id': 'epc_1',
      'e2ee_key_index': 1,
      'e2ee_key_active': true,
      'can_publish': false,
      'max_bitrate_mbps': 25,
    });
    final state = VoiceState.fromJson({
      'server_id': 'srv_1',
      'user_id': 'usr_1',
      'channel_id': 'chn_1',
      'screen_sharing': true,
      'screen_share_media_node_id': 'med_1',
    });
    final node = MediaNode.fromJson({
      'id': 'med_local',
      'is_local': true,
      'api_secret_set': true,
    });

    expect(token.url, 'wss://screen.example');
    expect(token.maxBitrateMbps, 25);
    expect(token.publisherUserId, 'usr_1');
    expect(token.mediaNodeId, 'med_1');
    expect(token.canPublish, isFalse);
    expect(state.screenShareMediaNodeId, token.mediaNodeId);
    expect(node.isLocal, isTrue);
    expect(node.apiSecretSet, isTrue);
    expect(
      ScreenShareToken.fromJson({'max_bitrate_mbps': 201}).maxBitrateMbps,
      0,
    );
  });

  test('ordinary realtime reconnect preserves the voice room', () {
    final plainToken = VoiceToken.fromJson({'e2ee_required': false});
    final e2eeToken = VoiceToken.fromJson({
      'e2ee_required': true,
      'e2ee_epoch_id': 'epc_current',
    });

    expect(
      realtimeReconnectRequiresVoiceRestart(
        e2eeServer: false,
        currentToken: plainToken,
        currentMediaEpochId: '',
      ),
      isFalse,
    );
    expect(
      realtimeReconnectRequiresVoiceRestart(
        e2eeServer: true,
        currentToken: e2eeToken,
        currentMediaEpochId: 'epc_current',
      ),
      isFalse,
    );
    expect(
      realtimeReconnectRequiresVoiceRestart(
        e2eeServer: true,
        currentToken: e2eeToken,
        currentMediaEpochId: 'epc_rotated',
      ),
      isTrue,
    );
    expect(
      realtimeReconnectRequiresVoiceRestart(
        e2eeServer: true,
        currentToken: null,
        currentMediaEpochId: 'epc_current',
      ),
      isTrue,
    );
    expect(
      realtimeReconnectRequiresVoiceRestart(
        e2eeServer: true,
        currentToken: e2eeToken,
        currentMediaEpochId: 'epc_current',
        currentMediaKeyIndex: 1,
        mediaKeySlots: true,
      ),
      isTrue,
    );

    final persistentToken = VoiceToken.fromJson({
      'room': 'openspeak-server-srv_1',
      'room_scope': 'server',
      'e2ee_required': true,
      'e2ee_epoch_id': 'epc_current',
      'e2ee_participant_keys': true,
    });
    final channelToken = VoiceToken.fromJson({
      'room': 'openspeak-srv_1-chn_1',
      'room_scope': 'channel',
      'e2ee_required': true,
      'e2ee_epoch_id': 'epc_current',
    });
    expect(
      realtimeReconnectRequiresVoiceRestart(
        e2eeServer: true,
        currentToken: channelToken,
        currentMediaEpochId: persistentToken.e2eeEpochId,
        refreshedToken: persistentToken,
      ),
      isTrue,
    );
  });

  test('participant key install plan keeps the active slot latest', () {
    expect(
      voiceE2EEParticipantKeyInstallPlan(
        participantIds: const ['usr_remote', '', 'usr_remote'],
        localUserId: 'usr_local',
        keyIndex: 1,
        mirror: true,
      ),
      const [
        (participantId: 'usr_remote', keyIndex: 0),
        (participantId: 'usr_remote', keyIndex: 1),
        (participantId: 'usr_local', keyIndex: 0),
        (participantId: 'usr_local', keyIndex: 1),
      ],
    );
  });

  test('media E2EE state exposes the pending key slot', () {
    final state = ChannelE2EEState.fromJson({
      'epoch': {
        'id': 'epc_next',
        'channel_id': 'chn_general',
        'epoch_number': 2,
      },
      'devices': <Map<String, dynamic>>[],
      'media_key_index': 1,
      'media_key_active': false,
      'media_key_slots': true,
    });
    expect(state.epoch.id, 'epc_next');
    expect(state.mediaKeyIndex, 1);
    expect(state.mediaKeyActive, isFalse);
    expect(state.mediaKeySlots, isTrue);
  });

  test('hotplug restarts the published capture only at the send gate', () {
    expect(
      microphoneCaptureRestartShouldRun(
        restartPending: true,
        shouldTransmit: false,
      ),
      isFalse,
    );
    expect(
      microphoneCaptureRestartShouldRun(
        restartPending: true,
        shouldTransmit: true,
      ),
      isTrue,
    );
    expect(
      microphoneCaptureRestartShouldRun(
        restartPending: false,
        shouldTransmit: true,
      ),
      isFalse,
    );
  });

  test('hotplug detaches the published sender only on Windows', () {
    expect(
      microphoneCaptureRestartShouldDetachSender(TargetPlatform.windows),
      isTrue,
    );
    expect(
      microphoneCaptureRestartShouldDetachSender(TargetPlatform.macOS),
      isFalse,
    );
    expect(
      microphoneCaptureRestartShouldDetachSender(
        TargetPlatform.windows,
        isWeb: true,
      ),
      isFalse,
    );
  });

  test('Windows hotplug forces sender reattachment after capture restart', () {
    expect(
      microphoneSenderReplacementShouldRun(force: false, alreadyAttached: true),
      isFalse,
    );
    expect(
      microphoneSenderReplacementShouldRun(force: true, alreadyAttached: true),
      isTrue,
    );
  });

  test('Web keeps its microphone sender attached while the gate is closed', () {
    expect(
      microphoneSenderShouldStayAttached(isWeb: true, shouldTransmit: false),
      isTrue,
    );
    expect(
      microphoneSenderShouldStayAttached(isWeb: false, shouldTransmit: false),
      isFalse,
    );
    expect(
      microphoneSenderShouldStayAttached(isWeb: false, shouldTransmit: true),
      isTrue,
    );
  });

  test('microphone PCM monitoring uses only supported LiveKit platforms', () {
    expect(microphonePcmMonitorSupported(TargetPlatform.macOS), isTrue);
    expect(microphonePcmMonitorSupported(TargetPlatform.iOS), isTrue);
    expect(microphonePcmMonitorSupported(TargetPlatform.android), isTrue);
    expect(microphonePcmMonitorSupported(TargetPlatform.windows), isFalse);
    expect(microphonePcmMonitorSupported(TargetPlatform.linux), isFalse);
    expect(
      microphonePcmMonitorSupported(TargetPlatform.windows, isWeb: true),
      isTrue,
    );
  });

  test('Windows uses the local event-driven microphone level callback', () {
    expect(windowsMicrophoneLevelSupported(TargetPlatform.windows), isTrue);
    expect(windowsMicrophoneLevelSupported(TargetPlatform.macOS), isFalse);
    expect(
      windowsMicrophoneLevelSupported(TargetPlatform.windows, isWeb: true),
      isFalse,
    );
  });

  test('Windows microphone level source follows sender attachment', () {
    expect(
      windowsMicrophoneLevelUsesWebRtc(
        fastConnecting: false,
        transmitting: false,
      ),
      isFalse,
    );
    expect(
      windowsMicrophoneLevelUsesWebRtc(
        fastConnecting: false,
        transmitting: true,
      ),
      isTrue,
    );
    expect(
      windowsMicrophoneLevelUsesWebRtc(
        fastConnecting: true,
        transmitting: false,
      ),
      isTrue,
    );
  });

  test(
    'Windows microphone activity starts immediately above its idle floor',
    () {
      final detector = WindowsMicrophoneActivityDetector();
      expect(detector.update(0.0002), isFalse);
      expect(detector.update(0.00021), isFalse);
      expect(detector.update(0.00045), isTrue);
      expect(detector.update(0.00015), isFalse);
    },
  );

  test(
    'Windows microphone activity keeps quiet speech above digital silence',
    () {
      final detector = WindowsMicrophoneActivityDetector();
      expect(detector.update(0), isFalse);
      expect(detector.update(0.00012), isTrue);
      detector.reset();
      expect(detector.noiseFloorRms, 0);
      expect(detector.update(0.004), isTrue);
    },
  );

  test('microphone activation defaults and gates are deterministic', () {
    expect(
      MicrophoneActivationModeValue.parse(null),
      MicrophoneActivationMode.continuous,
    );
    for (final mode in MicrophoneActivationMode.values) {
      expect(
        microphoneActivationModeForPlatform(mode, isWeb: true),
        MicrophoneActivationMode.continuous,
      );
      expect(microphoneActivationModeForPlatform(mode, isWeb: false), mode);
    }
    expect(
      microphoneActivationGateOpen(
        mode: MicrophoneActivationMode.pushToTalk,
        pushToTalkPressed: false,
        thresholdOpen: true,
      ),
      isFalse,
    );
    expect(
      microphoneActivationGateOpen(
        mode: MicrophoneActivationMode.voiceThreshold,
        pushToTalkPressed: true,
        thresholdOpen: false,
      ),
      isFalse,
    );
    expect(
      microphoneActivationGateOpen(
        mode: MicrophoneActivationMode.continuous,
        pushToTalkPressed: false,
        thresholdOpen: false,
      ),
      isTrue,
    );
    expect(microphoneThresholdDb(0), -50);
    expect(microphoneThresholdDb(0.5), 0);
    expect(microphoneThresholdDb(1), 50);
    expect(microphoneThresholdLabel(0), '-50 dB');
    expect(microphoneThresholdLabel(0.75), '+25 dB');
    expect(microphoneThresholdRms(0), lessThan(microphoneThresholdRms(1)));
  });

  test(
    'push-to-talk labels show physical key names instead of HID numbers',
    () {
      expect(hotkeyLabelFromUsbHidUsage(0x00070018, 0), 'U');
      expect(
        hotkeyBindingLabel(
          const MicrophoneHotkeyBinding(
            usbHidUsage: 0x00070018,
            modifiers: 0,
            label: '按键 458776',
          ),
        ),
        'U',
      );
    },
  );

  test('standalone microphone preview computes RMS from native PCM frames', () {
    final bytes = Uint8List(8);
    final data = ByteData.sublistView(bytes);
    for (var offset = 0; offset < bytes.length; offset += 2) {
      data.setInt16(offset, 16384, Endian.little);
    }
    final rms = microphonePcmRms(
      lk.AudioFrame(
        sampleRate: 24000,
        channels: 1,
        data: bytes,
        format: lk.AudioFormat.Int16,
      ),
    );

    expect(rms, closeTo(0.5, 0.0001));
    expect(microphoneLevelFromRms(rms), greaterThan(0));
  });

  test(
    'audio device monitor refreshes from native device change events',
    () async {
      Function(dynamic)? deviceChangeListener;
      var devices = <rtc.MediaDeviceInfo>[
        rtc.MediaDeviceInfo(
          deviceId: 'built-in-input',
          label: '内置麦克风',
          kind: 'audioinput',
        ),
      ];
      final monitor = AudioDeviceMonitor(
        enumerateDevices: () async => devices,
        registerDeviceChangeListener: (listener) {
          deviceChangeListener = listener;
        },
      );
      await monitor.start();
      expect(monitor.devices, hasLength(1));

      final refreshed = Completer<void>();
      monitor.addListener(() {
        if (!refreshed.isCompleted && monitor.devices.length == 2) {
          refreshed.complete();
        }
      });
      devices = [
        ...devices,
        rtc.MediaDeviceInfo(
          deviceId: 'usb-input',
          label: 'USB 麦克风',
          kind: 'audioinput',
        ),
      ];
      deviceChangeListener!(null);
      await refreshed.future;

      expect(
        monitor.devices.map((device) => device.deviceId),
        contains('usb-input'),
      );
      expect(monitor.audioInputDevicesChanged, isTrue);
      monitor.dispose();
      expect(deviceChangeListener, isNull);
    },
  );

  test(
    'audio device monitor polls when Windows misses device events',
    () async {
      var devices = <rtc.MediaDeviceInfo>[
        rtc.MediaDeviceInfo(
          deviceId: 'built-in-input',
          label: '内置麦克风',
          kind: 'audioinput',
        ),
      ];
      final monitor = AudioDeviceMonitor(
        enumerateDevices: () async => devices,
        registerDeviceChangeListener: (_) {},
        pollInterval: const Duration(milliseconds: 10),
      );
      await monitor.start();
      final refreshed = Completer<void>();
      monitor.addListener(() {
        if (!refreshed.isCompleted && monitor.devices.length == 2) {
          refreshed.complete();
        }
      });
      devices = [
        ...devices,
        rtc.MediaDeviceInfo(
          deviceId: 'usb-input',
          label: 'USB 麦克风',
          kind: 'audioinput',
        ),
      ];

      await refreshed.future.timeout(const Duration(seconds: 1));

      expect(monitor.devices.last.deviceId, 'usb-input');
      monitor.dispose();
    },
  );

  test(
    'audio device monitor probes again when the first hot-plug list is stale',
    () async {
      Function(dynamic)? deviceChangeListener;
      var enumerateCalls = 0;
      var hotPlugged = false;
      final monitor = AudioDeviceMonitor(
        enumerateDevices: () async {
          enumerateCalls += 1;
          final devices = [
            rtc.MediaDeviceInfo(
              deviceId: 'built-in-input',
              label: '内置麦克风',
              kind: 'audioinput',
            ),
          ];
          if (hotPlugged && enumerateCalls >= 3) {
            devices.add(
              rtc.MediaDeviceInfo(
                deviceId: 'usb-input',
                label: 'USB 麦克风',
                kind: 'audioinput',
              ),
            );
          }
          return devices;
        },
        registerDeviceChangeListener: (listener) {
          deviceChangeListener = listener;
        },
        deviceChangeProbeDelays: const [
          Duration.zero,
          Duration(milliseconds: 10),
        ],
      );
      await monitor.start();
      hotPlugged = true;
      final refreshed = Completer<void>();
      monitor.addListener(() {
        if (!refreshed.isCompleted &&
            monitor.devices.any((device) => device.deviceId == 'usb-input')) {
          refreshed.complete();
        }
      });

      deviceChangeListener!(null);
      await refreshed.future.timeout(const Duration(seconds: 1));

      expect(enumerateCalls, greaterThanOrEqualTo(3));
      expect(
        monitor.devices.map((device) => device.deviceId),
        contains('usb-input'),
      );
      monitor.dispose();
    },
  );

  test('audio device monitor retries transient empty native results', () async {
    var calls = 0;
    final monitor = AudioDeviceMonitor(
      enumerateDevices: () async {
        calls += 1;
        if (calls == 1) return <rtc.MediaDeviceInfo>[];
        return [
          rtc.MediaDeviceInfo(
            deviceId: 'built-in-output',
            label: 'Mac mini扬声器',
            kind: 'audiooutput',
          ),
        ];
      },
      registerDeviceChangeListener: (_) {},
      emptyRetryDelay: Duration.zero,
    );
    final refreshed = Completer<void>();
    monitor.addListener(() {
      if (!refreshed.isCompleted && monitor.devices.isNotEmpty) {
        refreshed.complete();
      }
    });

    await monitor.start();
    await refreshed.future.timeout(const Duration(seconds: 1));

    expect(calls, 2);
    expect(monitor.devices.single.label, 'Mac mini扬声器');
    monitor.dispose();
  });

  test(
    'audio device monitor preserves devices during an empty retry',
    () async {
      var returnEmpty = false;
      final monitor = AudioDeviceMonitor(
        enumerateDevices: () async => returnEmpty
            ? <rtc.MediaDeviceInfo>[]
            : [
                rtc.MediaDeviceInfo(
                  deviceId: 'built-in-output',
                  label: 'Mac mini扬声器',
                  kind: 'audiooutput',
                ),
              ],
        registerDeviceChangeListener: (_) {},
        emptyRetryDelay: const Duration(seconds: 1),
      );
      await monitor.start();
      returnEmpty = true;

      await monitor.refresh();

      expect(monitor.devices.single.deviceId, 'built-in-output');
      monitor.dispose();
    },
  );

  test('disconnected selected audio devices fall back to system defaults', () {
    final selection = audioDeviceSelectionAfterRefresh(
      inputDeviceId: 'removed-input',
      outputDeviceId: 'available-output',
      devices: [
        rtc.MediaDeviceInfo(
          deviceId: 'available-input',
          label: '内置麦克风',
          kind: 'audioinput',
        ),
        rtc.MediaDeviceInfo(
          deviceId: 'available-output',
          label: '内置扬声器',
          kind: 'audiooutput',
        ),
      ],
    );

    expect(selection.inputDeviceId, isNull);
    expect(selection.outputDeviceId, 'available-output');
  });

  test('WebRTC virtual default audio device is hidden from selectors', () {
    final outputs = selectableAudioDevices([
      rtc.MediaDeviceInfo(
        deviceId: 'default',
        label: 'default (Mac mini扬声器)',
        kind: 'audiooutput',
      ),
      rtc.MediaDeviceInfo(
        deviceId: 'display-output',
        label: 'AG273QG3R3B',
        kind: 'audiooutput',
      ),
      rtc.MediaDeviceInfo(
        deviceId: 'built-in-output',
        label: 'Mac mini扬声器',
        kind: 'audiooutput',
      ),
    ], 'audiooutput');

    expect(outputs.map((device) => device.label), [
      'AG273QG3R3B',
      'Mac mini扬声器',
    ]);
  });

  test('system default audio labels include the current physical devices', () {
    final devices = [
      rtc.MediaDeviceInfo(
        deviceId: 'default',
        label: 'default (USB 麦克风)',
        kind: 'audioinput',
      ),
      rtc.MediaDeviceInfo(
        deviceId: 'default',
        label: 'default (Mac mini扬声器)',
        kind: 'audiooutput',
      ),
    ];

    expect(
      systemDefaultAudioDeviceLabel(devices, 'audioinput', '系统默认麦克风'),
      '系统默认麦克风(USB 麦克风)',
    );
    expect(
      systemDefaultAudioDeviceLabel(devices, 'audiooutput', '系统默认扬声器'),
      '系统默认扬声器(Mac mini扬声器)',
    );
  });

  test('system default audio labels use the first Windows physical device', () {
    final devices = [
      rtc.MediaDeviceInfo(
        deviceId: 'default',
        label: 'default',
        kind: 'audioinput',
      ),
      rtc.MediaDeviceInfo(
        deviceId: 'sonic-cube',
        label: '线路 (Sonic Cube)',
        kind: 'audioinput',
      ),
    ];

    expect(
      systemDefaultAudioDeviceLabel(devices, 'audioinput', '系统默认麦克风'),
      '系统默认麦克风(线路 (Sonic Cube))',
    );
  });

  test(
    'microphone transmission requires activation and another participant',
    () {
      expect(
        microphoneAudioShouldTransmit(
          activationOpen: true,
          hasRemoteParticipants: false,
        ),
        isFalse,
      );
      expect(
        microphoneAudioShouldTransmit(
          activationOpen: false,
          hasRemoteParticipants: true,
        ),
        isFalse,
      );
      expect(
        microphoneAudioShouldTransmit(
          activationOpen: true,
          hasRemoteParticipants: true,
        ),
        isTrue,
      );
    },
  );

  test(
    'local speaking state updates the avatar without a remote participant',
    () {
      expect(
        withLocalSpeakingState(
          const {},
          localUserId: 'local-user',
          speaking: true,
        ),
        {'local-user'},
      );
      expect(
        withLocalSpeakingState(
          const {'local-user', 'remote-user'},
          localUserId: 'local-user',
          speaking: false,
        ),
        {'remote-user'},
      );
    },
  );

  test('speaking rings only show for users in the current voice room', () {
    const currentRoomUsers = {'a', 'b', 'c'};
    const speakingUsers = {'b', 'e'};

    expect(
      channelMemberIsSpeaking('b', currentRoomUsers, speakingUsers),
      isTrue,
    );
    expect(
      channelMemberIsSpeaking('e', currentRoomUsers, speakingUsers),
      isFalse,
    );
  });

  test('system default audio labels fall back when names are unavailable', () {
    expect(
      systemDefaultAudioDeviceLabel(const [], 'audioinput', '系统默认麦克风'),
      '系统默认麦克风',
    );
    expect(
      systemDefaultAudioDeviceLabel(const [], 'audiooutput', '系统默认扬声器'),
      '系统默认扬声器',
    );
  });

  test(
    'audio device availability distinguishes missing input and output',
    () async {
      final monitor = AudioDeviceMonitor(
        enumerateDevices: () async => [
          rtc.MediaDeviceInfo(
            deviceId: 'built-in-output',
            label: 'Mac mini扬声器',
            kind: 'audiooutput',
          ),
        ],
        registerDeviceChangeListener: (_) {},
        emptyRetryDelay: Duration.zero,
      );
      await monitor.start();

      expect(audioDeviceKindUnavailable(monitor, 'audioinput'), isTrue);
      expect(audioDeviceKindUnavailable(monitor, 'audiooutput'), isFalse);
      monitor.dispose();
    },
  );

  test('persisted WebRTC default device migrates to system default', () {
    final selection = audioDeviceSelectionAfterRefresh(
      inputDeviceId: null,
      outputDeviceId: 'default',
      devices: const [],
    );

    expect(selection.outputDeviceId, isNull);
  });

  testWidgets('audio settings show a newly connected device immediately', (
    WidgetTester tester,
  ) async {
    Function(dynamic)? deviceChangeListener;
    var devices = <rtc.MediaDeviceInfo>[
      rtc.MediaDeviceInfo(
        deviceId: 'built-in-input',
        label: '内置麦克风',
        kind: 'audioinput',
      ),
      rtc.MediaDeviceInfo(
        deviceId: 'built-in-output',
        label: '内置扬声器',
        kind: 'audiooutput',
      ),
    ];
    final monitor = AudioDeviceMonitor(
      enumerateDevices: () async => devices,
      registerDeviceChangeListener: (listener) {
        deviceChangeListener = listener;
      },
    );
    await monitor.start();
    final microphoneLevel = ValueNotifier(0.68);
    double? previewVolume;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OsClientAudioSettingsPane(
            deviceMonitor: monitor,
            initialInputDeviceId: null,
            initialOutputDeviceId: null,
            initialActivationMode: MicrophoneActivationMode.continuous,
            initialThreshold: 0.4,
            initialPushToTalkHotkey: null,
            initialSoundEffectVolume: 1,
            microphoneInputLevel: microphoneLevel,
            onSoundEffectPreview: (value) => previewVolume = value,
            onSave: (_, _, _, _, _, _) {},
          ),
        ),
      ),
    );

    expect(find.text('麦克风激活方式'), findsOneWidget);
    expect(find.text('按键通话'), kIsWeb ? findsNothing : findsOneWidget);
    expect(find.text('持续传输'), findsOneWidget);
    expect(find.text('语音阈值'), kIsWeb ? findsNothing : findsOneWidget);
    expect(find.textContaining('房间存在其他参与者'), findsOneWidget);
    expect(find.text('音效'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    var effectSlider = tester.widget<Slider>(
      find.byKey(const ValueKey('sound-effect-volume-slider')),
    );
    effectSlider.onChanged!(0.42);
    await tester.pump();
    expect(find.text('42%'), findsOneWidget);
    effectSlider = tester.widget<Slider>(
      find.byKey(const ValueKey('sound-effect-volume-slider')),
    );
    effectSlider.onChangeEnd!(0.42);
    expect(previewVolume, 0.42);

    if (!kIsWeb) {
      await tester.tap(find.text('语音阈值'));
      await tester.pumpAndSettle();
      expect(find.text('输入音量与传输阈值'), findsOneWidget);
      final liveLevel = find.byKey(const ValueKey('microphone-current-level'));
      expect(liveLevel, findsOneWidget);
      expect(tester.getSize(liveLevel).width, greaterThan(100));
      expect(
        tester.widget<FractionallySizedBox>(liveLevel).widthFactor,
        closeTo(0.68, 0.001),
      );
      microphoneLevel.value = 0.12;
      await tester.pump();
      expect(
        tester.widget<FractionallySizedBox>(liveLevel).widthFactor,
        closeTo(0.12, 0.001),
      );
    }

    devices = [
      ...devices,
      rtc.MediaDeviceInfo(
        deviceId: 'usb-input',
        label: 'USB 麦克风',
        kind: 'audioinput',
      ),
    ];
    deviceChangeListener!(null);
    await tester.pump(const Duration(milliseconds: 201));
    await tester.pumpAndSettle();
    final inputDropdown = find.byKey(
      const ValueKey('audio-device-dropdown-输入设备'),
    );
    await tester.tap(inputDropdown);
    await tester.pumpAndSettle();

    expect(find.text('USB 麦克风'), findsOneWidget);
    final option = find.byKey(const ValueKey('audio-device-option-usb-input'));
    expect(tester.getSize(option).width, tester.getSize(inputDropdown).width);
    expect(
      tester.getTopLeft(option).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(inputDropdown).dy),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    microphoneLevel.dispose();
    monitor.dispose();
  });

  testWidgets('audio settings hide activation modes without a microphone', (
    WidgetTester tester,
  ) async {
    final monitor = AudioDeviceMonitor(
      enumerateDevices: () async => [
        rtc.MediaDeviceInfo(
          deviceId: 'built-in-output',
          label: '内置扬声器',
          kind: 'audiooutput',
        ),
      ],
      registerDeviceChangeListener: (_) {},
      emptyRetryDelay: Duration.zero,
    );
    await monitor.start();
    final level = ValueNotifier(0.0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OsClientAudioSettingsPane(
            deviceMonitor: monitor,
            initialInputDeviceId: null,
            initialOutputDeviceId: null,
            initialActivationMode: MicrophoneActivationMode.continuous,
            initialThreshold: 0.4,
            initialPushToTalkHotkey: null,
            initialSoundEffectVolume: 1,
            microphoneInputLevel: level,
            onSoundEffectPreview: (_) {},
            onSave: (_, _, _, _, _, _) {},
          ),
        ),
      ),
    );

    expect(find.text('未发现麦克风'), findsOneWidget);
    expect(find.text('麦克风激活方式'), findsNothing);
    expect(find.text('按键通话'), findsNothing);

    level.dispose();
    monitor.dispose();
  });

  test('offline avatar changes force the next server sync', () {
    expect(
      shouldUploadLocalAvatar(
        pendingSync: true,
        localHash: 'same',
        remoteHash: 'same',
      ),
      isTrue,
    );
    expect(
      shouldUploadLocalAvatar(
        pendingSync: false,
        localHash: 'same',
        remoteHash: 'same',
      ),
      isFalse,
    );
    expect(
      shouldUploadLocalAvatar(
        pendingSync: false,
        localHash: 'new',
        remoteHash: 'old',
      ),
      isTrue,
    );
  });

  testWidgets('current user nickname is vertically centered with avatar', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CurrentUserBar(
            connected: false,
            displayName: 'mac',
            online: false,
            muted: false,
            listenOff: false,
            inputVolume: 1,
            outputVolume: 1,
            onMute: () {},
            onListenOff: () {},
            onInputVolumeChanged: (_) {},
            onOutputVolumeChanged: (_) {},
            onSettings: () {},
          ),
        ),
      ),
    );

    final avatarCenter = tester.getCenter(find.byType(OsUserAvatar));
    final nicknameCenter = tester.getCenter(
      find.byKey(const ValueKey('current-user-display-name')),
    );
    expect(nicknameCenter.dy, closeTo(avatarCenter.dy, 0.01));
  });

  testWidgets('profile preview avatar is three times its original size', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: OsProfilePreview(displayName: 'mac')),
      ),
    );

    final avatarSize = tester.getSize(
      find.descendant(
        of: find.byType(OsProfilePreview),
        matching: find.byType(OsUserAvatar),
      ),
    );
    expect(avatarSize, const Size.square(144));
  });

  testWidgets('voice speak permission disables the microphone control', (
    WidgetTester tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CurrentUserBar(
            connected: true,
            displayName: 'mac',
            online: true,
            muted: false,
            canSpeak: false,
            listenOff: false,
            inputVolume: 1,
            outputVolume: 1,
            onMute: () => tapped = true,
            onListenOff: () {},
            onInputVolumeChanged: (_) {},
            onOutputVolumeChanged: (_) {},
            onSettings: () {},
          ),
        ),
      ),
    );

    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.mic_off),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);
    await tester.tap(find.byIcon(Icons.mic_off));
    expect(tapped, isFalse);
  });

  testWidgets('channel attachment without download permission is inert', (
    WidgetTester tester,
  ) async {
    var accessed = false;
    final attachment = ChatAttachment(
      direct: false,
      kind: 'image',
      fileId: 'fil_test',
      originalName: 'private.png',
      contentType: 'image/png',
      sizeBytes: 10,
      expiresAt: null,
      expired: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageRow(
            body: 'fil_test',
            attachment: attachment,
            attachmentDownloadsEnabled: false,
            sentAt: DateTime(2026),
            senderName: 'Admin',
            mine: false,
            ensureCached: (_) async {
              accessed = true;
              throw UnimplementedError();
            },
            loadImagePreview: (_) async {
              accessed = true;
              throw UnimplementedError();
            },
            loadAudioMetadata: (_) async {
              accessed = true;
              throw UnimplementedError();
            },
            linkPreviewFallback: null,
            linkPreviewFuture: null,
            onOpen: (_) async => accessed = true,
            onSaveAs: (_) async => accessed = true,
            onOpenLink: (_) async {},
            downloadTask: null,
            onCancelDownload: (_) {},
            activeAudioFileId: null,
            audioLoadingFileId: null,
            audioPlaying: false,
            audioPosition: Duration.zero,
            audioDuration: Duration.zero,
            onToggleAudio: (_) async => accessed = true,
            onSeekAudio: (_) async {},
          ),
        ),
      ),
    );

    expect(find.textContaining('没有下载附件的权限'), findsOneWidget);
    expect(find.byType(ImageAttachmentPreview), findsNothing);
    expect(accessed, isFalse);
  });

  testWidgets(
    'image lightbox zooms without turning the image into a download',
    (WidgetTester tester) async {
      var downloads = 0;
      var closes = 0;
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMA'
        'ASsJTYQAAAAASUVORK5CYII=',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImageLightbox(
              preview: Future.value(
                CachedImagePreview(bytes: bytes, size: const Size(1, 1)),
              ),
              onDownload: () => downloads += 1,
              onClose: () => closes += 1,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(
        tester.getSize(find.byType(InteractiveViewer)),
        const Size(768, 568),
      );
      await tester.tap(find.byTooltip('下载'));
      expect(downloads, 1);
      expect(closes, 0);
      await tester.tap(find.byTooltip('关闭'));
      expect(closes, 1);
    },
  );

  test('client installation IDs are UUIDv4 values', () {
    final first = generateClientInstallationId();
    final second = generateClientInstallationId();
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );
    expect(first, matches(uuid));
    expect(second, matches(uuid));
    expect(second, isNot(first));
  });

  testWidgets('managed member row shows role and blacklist state', (
    WidgetTester tester,
  ) async {
    final member = ManagedServerMember(
      serverId: 'server',
      userId: 'user',
      displayName: 'win',
      role: 'admin',
      online: false,
      legacy: false,
      banned: true,
      installationFingerprint: 'ABC123',
      banReason: 'test',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OsManagedMemberRow(
            member: member,
            currentUser: false,
            canChangeRole: true,
            onAction: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('win'), findsOneWidget);
    expect(find.text('管理员'), findsOneWidget);
    expect(find.textContaining('已封禁'), findsOneWidget);
  });

  testWidgets('admin member manager cannot change roles', (
    WidgetTester tester,
  ) async {
    final member = ManagedServerMember(
      serverId: 'server',
      userId: 'user',
      displayName: 'Admin member',
      role: 'admin',
      online: false,
      legacy: false,
      banned: false,
      installationFingerprint: 'ABC123',
      banReason: '',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OsManagedMemberRow(
            member: member,
            currentUser: false,
            canChangeRole: false,
            permissions: const {'member.ban'},
            onAction: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    expect(find.text('设为普通成员'), findsNothing);
    expect(find.text('加入黑名单'), findsOneWidget);
  });

  test('channel history keeps the sender display name while offline', () {
    final message = ChannelMessage.fromJson({
      'id': 'message',
      'channel_id': 'channel',
      'sender_user_id': 'usr_random',
      'sender_display_name': 'win',
      'sender_avatar_version': 3,
      'kind': 'text',
      'encryption_mode': 'none',
      'body': 'hello',
      'metadata': <String, String>{},
    });

    expect(message.senderDisplayName, 'win');
    expect(message.senderAvatarVersion, 3);
    expect(
      channelMessageSenderName(
        message: message,
        currentUserId: 'usr_current',
        currentDisplayName: 'current',
        liveDisplayName: null,
        fallbackDisplayName: 'fallback',
      ),
      'win',
    );
  });

  test('chat date dividers follow the viewer local calendar day', () {
    final first = DateTime(2026, 7, 15, 23, 59);
    expect(startsNewLocalDay(DateTime(2026, 7, 15, 0, 1), first), isFalse);
    expect(startsNewLocalDay(DateTime(2026, 7, 16, 0, 0), first), isTrue);
    expect(startsNewLocalDay(first, null), isFalse);
    expect(localDateLabel(first), '2026年07月15日');
  });

  testWidgets('direct chat entries reuse the channel date divider', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageEntry(
            sentAt: DateTime(2026, 7, 15),
            previousSentAt: DateTime(2026, 7, 14, 23, 59),
            child: const Text('私聊消息'),
          ),
        ),
      ),
    );

    expect(find.byType(ChatDateDivider), findsOneWidget);
    expect(find.text('2026年07月15日'), findsOneWidget);
    expect(find.byType(Divider), findsNWidgets(2));
  });

  testWidgets('removed message notice matches date text without divider', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ChatMessageRemovalNotice(text: 'mac 撤回了一条消息')),
      ),
    );

    final text = tester.widget<Text>(find.text('mac 撤回了一条消息'));
    expect(text.style?.fontSize, 11);
    expect(text.style?.color, OsColors.dim);
    expect(find.byType(Divider), findsNothing);
  });

  test('own channel messages immediately use the current local nickname', () {
    final message = ChannelMessage.fromJson({
      'id': 'message',
      'channel_id': 'channel',
      'sender_user_id': 'usr_current',
      'sender_display_name': 'old name',
      'kind': 'text',
      'encryption_mode': 'none',
      'body': 'hello',
      'metadata': <String, String>{},
    });

    expect(
      channelMessageSenderName(
        message: message,
        currentUserId: 'usr_current',
        currentDisplayName: 'new name',
        liveDisplayName: null,
        fallbackDisplayName: 'fallback',
      ),
      'new name',
    );
  });

  test('online sender nickname immediately replaces channel history name', () {
    final message = ChannelMessage.fromJson({
      'id': 'message',
      'channel_id': 'channel',
      'sender_user_id': 'usr_other',
      'sender_display_name': 'old name',
      'kind': 'text',
      'encryption_mode': 'none',
      'body': 'hello',
      'metadata': <String, String>{},
    });

    expect(
      channelMessageSenderName(
        message: message,
        currentUserId: 'usr_current',
        currentDisplayName: 'current',
        liveDisplayName: 'new name',
        fallbackDisplayName: 'fallback',
      ),
      'new name',
    );
  });

  testWidgets('chat avatar uses the shared image avatar renderer', (
    tester,
  ) async {
    final avatarFile = File('/tmp/openspeak-chat-avatar-test.png');
    final avatarUri = Uri.parse(
      'http://127.0.0.1:27410/api/v1/users/usr_mac/avatar?v=2&size=small&thumb=png-v1',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChatAvatar(
          name: 'mac1',
          mine: true,
          avatarFile: avatarFile,
          avatarRevision: 7,
          avatarUri: avatarUri,
          avatarToken: 'token',
        ),
      ),
    );

    final avatar = tester.widget<OsUserAvatar>(find.byType(OsUserAvatar));
    expect(avatar.avatarFile?.path, avatarFile.path);
    expect(avatar.avatarRevision, 7);
    expect(avatar.avatarUri, avatarUri);
    expect(avatar.avatarToken, 'token');
    expect(avatar.size, 36);
  });

  test('microphone activity and packet counters reject idle samples', () {
    expect(microphoneRmsIndicatesActivity(0.004), isTrue);
    expect(microphoneRmsIndicatesActivity(0.0002), isFalse);
    expect(packetCounterDelta(120, 100), 20);
    expect(packetCounterDelta(20, null), 0);
    expect(packetCounterDelta(10, 100), 0);
  });

  test(
    'voice audio processing keeps AEC and AGC while toggling noise filters',
    () {
      final enabled = voiceAudioCaptureOptions(
        noiseSuppressionEnabled: true,
        deviceId: 'microphone-1',
      );
      final disabled = voiceAudioCaptureOptions(
        noiseSuppressionEnabled: false,
        deviceId: 'microphone-1',
      );

      expect(enabled.deviceId, 'microphone-1');
      expect(enabled.echoCancellation, isTrue);
      expect(enabled.autoGainControl, isTrue);
      expect(enabled.noiseSuppression, isTrue);
      expect(enabled.highPassFilter, isTrue);
      expect(enabled.typingNoiseDetection, isTrue);
      expect(disabled.echoCancellation, isTrue);
      expect(disabled.autoGainControl, isTrue);
      expect(disabled.noiseSuppression, isFalse);
      expect(disabled.highPassFilter, isFalse);
      expect(disabled.typingNoiseDetection, isFalse);
    },
  );

  test('participant volume multiplies global output up to 200 percent', () {
    expect(effectiveParticipantOutputVolume(1, 1), 1);
    expect(effectiveParticipantOutputVolume(1, 2), 2);
    expect(effectiveParticipantOutputVolume(.8, 1.5), closeTo(1.2, 0.0001));
    expect(effectiveParticipantOutputVolume(2, 3), 2);
    expect(effectiveParticipantOutputVolume(-1, -1), 0);
  });

  test('member context volume is available for every non-current user', () {
    expect(
      memberContextActions(
        currentUser: false,
        canChangeRole: false,
        targetRole: 'owner',
      ),
      [MemberContextAction.adjustVolume],
    );
    expect(
      memberContextActions(
        currentUser: false,
        canChangeRole: true,
        targetRole: 'user',
      ),
      [MemberContextAction.adjustVolume, MemberContextAction.makeAdmin],
    );
    expect(
      memberContextActions(
        currentUser: true,
        canChangeRole: true,
        targetRole: 'user',
      ),
      isEmpty,
    );
    expect(
      memberContextActions(
        currentUser: false,
        canChangeRole: false,
        targetRole: 'user',
        inVoice: true,
        permissions: const {
          'member.move',
          'member.kick',
          'member.ban',
          'member.mute',
          'member.deafen',
        },
      ),
      [
        MemberContextAction.adjustVolume,
        MemberContextAction.forceMute,
        MemberContextAction.forceDeafen,
        MemberContextAction.kick,
        MemberContextAction.ban,
      ],
    );
    expect(
      memberContextActions(
        currentUser: false,
        canChangeRole: false,
        targetRole: 'user',
        permissions: const {
          'member.kick',
          'member.ban',
          'member.mute',
          'member.deafen',
        },
      ),
      [
        MemberContextAction.adjustVolume,
        MemberContextAction.kick,
        MemberContextAction.ban,
      ],
    );
  });

  testWidgets('member volume popup ranges from zero to two hundred percent', (
    tester,
  ) async {
    double? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 286,
              child: MemberVolumePopupEntry(
                displayName: 'Member',
                initialVolume: 1,
                onChanged: (value) => changed = value,
                onChangeEnd: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    var slider = tester.widget<Slider>(
      find.byKey(const ValueKey('member-volume-slider')),
    );
    expect(slider.min, 0);
    expect(slider.max, 2);
    expect(slider.value, 1);
    expect(slider.divisions, 200);
    expect(find.text('100%'), findsOneWidget);
    expect(tester.getSize(find.byType(MemberVolumePopupEntry)).height, 80);

    slider.onChanged!(1.5);
    await tester.pump();
    slider = tester.widget<Slider>(
      find.byKey(const ValueKey('member-volume-slider')),
    );
    expect(slider.value, 1.5);
    expect(changed, 1.5);
    expect(find.text('150%'), findsOneWidget);
  });

  testWidgets('opens directly to main shell', (WidgetTester tester) async {
    await tester.pumpWidget(const OpenSpeakApp());

    expect(find.text('+'), findsOneWidget);
    expect(find.text('未连接'), findsNothing);
    expect(find.text('user'), findsOneWidget);
  });

  testWidgets('chat composer keeps focus after sending', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final sent = <String>[];
    var sending = false;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return ChatComposer(
                controller: controller,
                enabled: true,
                readOnly: sending,
                disabledHintText: '',
                onAdd: () {},
                onSend: () {
                  sent.add(controller.text);
                  controller.clear();
                  setState(() => sending = true);
                },
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'first');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(sent, ['first']);
    expect(editable.focusNode.hasFocus, isTrue);
    rebuild(() => sending = false);
    await tester.pump();
    tester.testTextInput.enterText('second');
    await tester.pump();
    expect(controller.text, 'second');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    expect(sent, ['first', 'second']);
  });

  testWidgets('channel list extends behind the fixed current user card', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const OpenSpeakApp());

    final overlay = tester.widget<Positioned>(
      find.ancestor(
        of: find.byType(CurrentUserBar),
        matching: find.byType(Positioned),
      ),
    );
    final channelList = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );

    expect(overlay.left, 0);
    expect(overlay.right, 0);
    expect(overlay.bottom, 0);
    expect(overlay.height, 132);
    expect(channelList.padding, const EdgeInsets.fromLTRB(8, 8, 8, 132));
  });

  testWidgets('new server dialog starts with blank address and port', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const OpenSpeakApp());

    await tester.tap(find.text('+'));
    await tester.pumpAndSettle();

    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields, hasLength(3));
    expect(fields[0].controller?.text, isEmpty);
    expect(fields[1].controller?.text, isEmpty);
  });

  testWidgets('interactive icon controls use the click cursor', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          iconButtonTheme: IconButtonThemeData(
            style: ButtonStyle(
              mouseCursor: WidgetStateProperty.all(SystemMouseCursors.click),
            ),
          ),
        ),
        home: Scaffold(
          body: CurrentUserBar(
            connected: true,
            displayName: 'Admin',
            online: true,
            muted: false,
            canShareScreen: true,
            listenOff: false,
            inputVolume: 0.8,
            outputVolume: 0.6,
            onMute: () {},
            onListenOff: () {},
            onInputVolumeChanged: (_) {},
            onOutputVolumeChanged: (_) {},
            onScreenShare: () {},
            onSettings: () {},
          ),
        ),
      ),
    );

    final micButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.mic),
        matching: find.byType(IconButton),
      ),
    );
    final networkButton = tester.widget<InkResponse>(
      find.descendant(
        of: find.byType(NetworkQualityButton),
        matching: find.byType(InkResponse),
      ),
    );
    final shareButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.screen_share),
        matching: find.byType(IconButton),
      ),
    );

    expect(micButton.mouseCursor, SystemMouseCursors.click);
    expect(networkButton.mouseCursor, SystemMouseCursors.click);
    expect(shareButton.mouseCursor, SystemMouseCursors.click);
  });

  testWidgets('screen share control is disabled while switching', (
    WidgetTester tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CurrentUserBar(
            connected: true,
            displayName: 'Admin',
            online: true,
            muted: false,
            canShareScreen: true,
            screenShareBusy: true,
            listenOff: false,
            inputVolume: 1,
            outputVolume: 1,
            onMute: () {},
            onListenOff: () {},
            onInputVolumeChanged: (_) {},
            onOutputVolumeChanged: (_) {},
            onScreenShare: () => tapped = true,
            onSettings: () {},
          ),
        ),
      ),
    );

    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.screen_share),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);
    await tester.tap(find.byIcon(Icons.screen_share));
    expect(tapped, isFalse);
  });

  testWidgets('application button themes use hand cursors when enabled', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const OpenSpeakApp());
    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    final styles = <ButtonStyle?>[
      theme.iconButtonTheme.style,
      theme.textButtonTheme.style,
      theme.elevatedButtonTheme.style,
      theme.outlinedButtonTheme.style,
      theme.filledButtonTheme.style,
      theme.menuButtonTheme.style,
    ];

    for (final style in styles) {
      expect(style?.mouseCursor?.resolve({}), SystemMouseCursors.click);
      expect(
        style?.mouseCursor?.resolve({WidgetState.disabled}),
        SystemMouseCursors.basic,
      );
    }
  });

  testWidgets('custom clickable icon areas use the click cursor', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ServerBubble(label: 'AD', selected: true, onTap: () {}),
              LinkPreviewCard(
                preview: LinkPreview(
                  url: 'https://example.com',
                  domain: 'example.com',
                  title: 'example.com',
                  description: '',
                  imageUrl: '',
                ),
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );

    final serverInk = tester.widget<InkWell>(
      find.descendant(
        of: find.byType(ServerBubble),
        matching: find.byType(InkWell),
      ),
    );
    final linkPreviewInk = tester.widget<InkWell>(
      find.descendant(
        of: find.byType(LinkPreviewCard),
        matching: find.byType(InkWell),
      ),
    );

    expect(serverInk.mouseCursor, SystemMouseCursors.click);
    expect(linkPreviewInk.mouseCursor, SystemMouseCursors.click);
  });

  testWidgets('add server dialog uses OpenSpeak styling and validation', (
    WidgetTester tester,
  ) async {
    final addressController = TextEditingController();
    final portController = TextEditingController();
    final passwordController = TextEditingController();
    addTearDown(() {
      addressController.dispose();
      portController.dispose();
      passwordController.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AddServerDialog(
            addressController: addressController,
            portController: portController,
            passwordController: passwordController,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.dns_rounded), findsOneWidget);
    expect(find.byIcon(Icons.link_rounded), findsOneWidget);
    expect(find.byIcon(Icons.tag_rounded), findsOneWidget);
    expect(find.text('添加服务器'), findsOneWidget);
    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('服务器域名 或 ip'), findsOneWidget);
    expect(find.text('端口'), findsOneWidget);
    expect(find.text('密码（如果有）'), findsOneWidget);
    expect(find.text('服务器别名'), findsNothing);
    expect(find.text('保存到左侧服务器列表，并立即连接到这个 OpenSpeak 服务器。'), findsOneWidget);
    expect(addressController.text, isEmpty);
    expect(portController.text, isEmpty);
    final addressFieldFinder = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.controller == addressController,
    );
    final portFieldFinder = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.controller == portController,
    );
    final addressWidth = tester.getSize(addressFieldFinder).width;
    final portWidth = tester.getSize(portFieldFinder).width;
    expect(addressWidth / portWidth, closeTo(7 / 3, 0.01));
    final passwordField = tester
        .widgetList<TextField>(find.byType(TextField))
        .firstWhere((field) => field.controller == passwordController);
    expect(passwordField.obscureText, isFalse);

    await tester.tap(find.text('添加并连接'));
    await tester.pump();

    expect(find.text('服务器地址不能为空'), findsOneWidget);
  });

  testWidgets('saved server bubble shows its server name below the avatar', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ServerBubble(label: 'MO', caption: 'Main OS', selected: true),
        ),
      ),
    );

    expect(find.text('Main OS'), findsOneWidget);
    expect(tester.widget<Tooltip>(find.byType(Tooltip)).message, 'Main OS');
    expect(
      tester.getTopLeft(find.text('Main OS')).dy,
      greaterThan(tester.getTopLeft(find.text('MO')).dy),
    );
  });

  test('shared smooth scroll approaches its target without jumping', () {
    final next = smoothWheelNextPixels(
      current: 0,
      target: 120,
      elapsedSeconds: 1 / 120,
    );

    expect(next, greaterThan(0));
    expect(next, lessThan(120));
    expect(
      smoothWheelNextPixels(
        current: next,
        target: 120,
        elapsedSeconds: 1 / 120,
      ),
      greaterThan(next),
    );
  });

  testWidgets('settings pages share the OpenSpeak navigation shell', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(700, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var opened = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OsSettingsDialog(
            icon: Icons.tune_rounded,
            eyebrow: '',
            title: '个人设置',
            subtitle: '',
            compactHeader: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                OsSettingsTile(
                  icon: Icons.account_circle_outlined,
                  title: '个人资料',
                  subtitle: '本机头像、昵称与显示身份',
                  onTap: () => opened = true,
                ),
                const OsSettingsTile(
                  icon: Icons.graphic_eq_rounded,
                  title: '降噪与处理',
                  subtitle: '后续版本提供',
                  enabled: false,
                  badge: '即将推出',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('个人设置'), findsOneWidget);
    expect(find.text('客户端设置'), findsNothing);
    expect(find.text('本机偏好'), findsNothing);
    expect(find.textContaining('只影响这台设备'), findsNothing);
    expect(find.text('即将推出'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('个人资料'));
    expect(opened, isTrue);
  });

  testWidgets(
    'server permission page separates delegable and owner-only abilities',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: OsServerPermissionsPage(
                adminPermissions: const {'channel.create'},
                userPermissions: const {'channel.messages.view'},
                messageRetractWindowMinutes: 30,
                onChanged: (_, _, _) {},
                onMessageRetractWindowChanged: (_) {},
                onSave: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('服务器权限管理'), findsOneWidget);
      expect(find.text('可下发权限'), findsOneWidget);
      expect(find.text('服务器管理员'), findsOneWidget);
      expect(find.text('服务器成员'), findsOneWidget);
      expect(find.text('服务器拥有者专属权限'), findsOneWidget);
      expect(find.text('屏幕共享可选分辨率'), findsOneWidget);
      expect(find.text('屏幕共享可选帧率'), findsOneWidget);
      expect(find.text('撤回消息时限'), findsOneWidget);
      expect(find.text('30 分钟'), findsOneWidget);
      expect(
        find.text(
          '修改服务器管理员或服务器成员权限、修改成员角色、添加或撤销拥有者设备、生成设备配对码、转移或删除服务器、执行所有权恢复等能力不能下发。',
        ),
        findsOneWidget,
      );
    },
  );

  test(
    'screen share permission options follow the master and minimum rules',
    () {
      final onlyOne = {
        voiceScreenSharePermission,
        screenShareResolutionPermissions['720p']!,
        screenShareFPSPermissions[15]!,
      };
      expect(
        screenSharePermissionInteractive(
          const {},
          screenShareResolutionPermissions['720p']!,
        ),
        isFalse,
      );
      expect(
        screenSharePermissionInteractive(
          onlyOne,
          screenShareResolutionPermissions['720p']!,
        ),
        isFalse,
      );
      expect(
        screenSharePermissionInteractive({
          ...onlyOne,
          screenShareResolutionPermissions['1080p']!,
        }, screenShareResolutionPermissions['720p']!),
        isTrue,
      );
    },
  );

  testWidgets('error box exposes an optional settings action', (
    WidgetTester tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ErrorBox(
            message: '需要系统权限',
            actionLabel: '打开系统设置',
            onAction: () => opened = true,
          ),
        ),
      ),
    );

    expect(find.text('打开系统设置'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('error-box-action')));
    expect(opened, isTrue);
  });

  testWidgets('settings dialog supports back and primary footer actions', (
    WidgetTester tester,
  ) async {
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OsSettingsDialog(
            icon: Icons.key_rounded,
            eyebrow: '服务器设置',
            title: '添加所有者设备',
            subtitle: '',
            leadingActions: [
              OsSecondaryButton(
                label: '返回',
                icon: Icons.arrow_back_rounded,
                onPressed: () => returned = true,
              ),
            ],
            actions: [OsPrimaryButton(label: '完成', onPressed: () {})],
            child: const SizedBox(),
          ),
        ),
      ),
    );

    expect(
      tester.getCenter(find.text('返回')).dx,
      lessThan(tester.getCenter(find.text('完成')).dx),
    );
    await tester.tap(find.text('返回'));
    expect(returned, isTrue);
  });

  testWidgets('settings dialogs resize by default', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: OsSettingsDialog(
            icon: Icons.manage_accounts_outlined,
            eyebrow: '',
            title: '成员与权限',
            subtitle: 'Main OS',
            compactHeader: true,
            maxWidth: 800,
            child: SizedBox(
              key: ValueKey('resizable-dialog-content'),
              height: 420,
            ),
          ),
        ),
      ),
    );

    final left = find.byKey(const ValueKey('settings-dialog-resize-left'));
    final right = find.byKey(const ValueKey('settings-dialog-resize-right'));
    final bottom = find.byKey(const ValueKey('settings-dialog-resize-bottom'));
    final content = find.byKey(const ValueKey('resizable-dialog-content'));
    expect(left, findsOneWidget);
    expect(right, findsOneWidget);
    expect(bottom, findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-dialog-resize-topLeft')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-dialog-resize-bottomRight')),
      findsOneWidget,
    );
    final initialWidth = tester.getCenter(right).dx - tester.getCenter(left).dx;
    final initialContentHeight = tester.getSize(content).height;
    expect(
      DefaultTextStyle.of(tester.element(find.text('成员与权限'))).style.decoration,
      isNot(TextDecoration.underline),
    );

    await tester.drag(right, const Offset(80, 0));
    await tester.pump();

    final resizedWidth = tester.getCenter(right).dx - tester.getCenter(left).dx;
    expect(resizedWidth, greaterThan(initialWidth + 70));

    await tester.drag(bottom, const Offset(0, 60));
    await tester.pump();

    expect(
      tester.getSize(content).height,
      greaterThan(initialContentHeight + 50),
    );
  });

  test('server menu actions follow owner and member permissions', () {
    expect(
      serverMenuActions(claimed: true, isOwner: true, permissions: const {}),
      [ServerMenuAction.settings, ServerMenuAction.members],
    );
    expect(
      serverMenuActions(claimed: true, isOwner: false, permissions: const {}),
      [ServerMenuAction.pair],
    );
    expect(
      serverMenuActions(
        claimed: true,
        isOwner: false,
        permissions: const {'server.profile.update'},
        allowPairing: false,
      ),
      [ServerMenuAction.settings],
    );
    expect(
      serverMenuActions(
        claimed: true,
        isOwner: false,
        permissions: const {'server.profile.update'},
      ),
      [ServerMenuAction.settings, ServerMenuAction.pair],
    );
    expect(
      serverMenuActions(
        claimed: true,
        isOwner: false,
        permissions: const {'member.view'},
      ),
      [ServerMenuAction.members, ServerMenuAction.pair],
    );
    expect(
      serverMenuActions(claimed: false, isOwner: false, permissions: const {}),
      [ServerMenuAction.claim],
    );
  });

  test('server settings pages expose only granted categories', () {
    expect(
      serverSettingsPages(const {
        'server.profile.update',
        'audit.view',
        'voice.join',
      }),
      ['overview', 'audit'],
    );
  });

  testWidgets('settings body keeps category navigation beside page content', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OsSettingsDialog(
            icon: Icons.tune_rounded,
            eyebrow: '',
            title: '个人设置',
            subtitle: '',
            compactHeader: true,
            maxWidth: 920,
            child: OsSplitSettingsBody(
              navigation: [
                OsSettingsNavEntry(
                  icon: Icons.person_outline_rounded,
                  label: '个人资料',
                  selected: true,
                  onTap: () {},
                ),
                OsSettingsNavEntry(
                  icon: Icons.headphones_rounded,
                  label: '音频设备',
                  selected: false,
                  onTap: () {},
                ),
              ],
              content: const OsSettingsPage(
                icon: Icons.person_rounded,
                title: '个人资料详情',
                subtitle: '设置本机身份',
                child: Text('右侧内容'),
              ),
            ),
          ),
        ),
      ),
    );

    final navigationCenter = tester.getCenter(find.text('个人资料'));
    final contentCenter = tester.getCenter(find.text('个人资料详情'));
    final compactHeight = tester
        .getSize(find.byType(OsSplitSettingsBody))
        .height;
    expect(navigationCenter.dx, lessThan(contentCenter.dx));
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    await tester.pump();
    expect(
      tester.getSize(find.byType(OsSplitSettingsBody)).height,
      greaterThan(compactHeight),
    );
    expect(find.text('右侧内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings body stacks navigation on mobile widths', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: OsSplitSettingsBody(
              navigation: [
                OsSettingsNavEntry(
                  icon: Icons.person_outline_rounded,
                  label: '个人资料',
                  selected: true,
                  onTap: () {},
                ),
                OsSettingsNavEntry(
                  icon: Icons.headphones_rounded,
                  label: '音频设备',
                  selected: false,
                  onTap: () {},
                ),
              ],
              content: const OsSettingsPage(
                icon: Icons.person_rounded,
                title: '个人资料详情',
                subtitle: '设置本机身份',
                child: Text('下方内容'),
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getCenter(find.text('个人资料')).dy,
      lessThan(tester.getCenter(find.text('个人资料详情')).dy),
    );
    expect(find.text('下方内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows compact mic volume popover on hover', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: CurrentUserBar(
              connected: true,
              displayName: 'Admin',
              online: true,
              muted: false,
              listenOff: false,
              inputVolume: 0.8,
              outputVolume: 0.6,
              onMute: () {},
              onListenOff: () {},
              onInputVolumeChanged: (_) {},
              onOutputVolumeChanged: (_) {},
              onSettings: () {},
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer();
    await gesture.moveTo(tester.getCenter(find.byIcon(Icons.mic)));
    await tester.pump();

    expect(find.byType(AudioVolumePopover), findsOneWidget);
    expect(
      tester.getSize(find.byType(AudioVolumePopover)),
      const Size(44, 116),
    );
    await gesture.removePointer();
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('volume popover hides 300ms after pointer leaves', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: CurrentUserBar(
              connected: true,
              displayName: 'Admin',
              online: true,
              muted: false,
              listenOff: false,
              inputVolume: 0.8,
              outputVolume: 0.6,
              onMute: () {},
              onListenOff: () {},
              onInputVolumeChanged: (_) {},
              onOutputVolumeChanged: (_) {},
              onSettings: () {},
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer();
    await gesture.moveTo(tester.getCenter(find.byIcon(Icons.volume_up)));
    await tester.pump();
    expect(find.byType(AudioVolumePopover), findsOneWidget);

    await gesture.moveTo(tester.getCenter(find.byType(AudioVolumePopover)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(AudioVolumePopover), findsOneWidget);

    await gesture.moveTo(const Offset(400, 400));
    await tester.pump(const Duration(milliseconds: 299));
    expect(find.byType(AudioVolumePopover), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(AudioVolumePopover), findsNothing);
    await gesture.removePointer();
  });

  testWidgets('audio controls align to the settings right edge', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CurrentUserBar(
            connected: true,
            displayName: 'Admin',
            online: true,
            muted: false,
            canShareScreen: true,
            listenOff: false,
            inputVolume: 0.8,
            outputVolume: 0.6,
            onMute: () {},
            onListenOff: () {},
            onInputVolumeChanged: (_) {},
            onOutputVolumeChanged: (_) {},
            onScreenShare: () {},
            onSettings: () {},
          ),
        ),
      ),
    );

    final micRect = tester.getRect(find.byTooltip('静音'));
    final speakerRect = tester.getRect(find.byTooltip('关闭收听'));
    final settingsRect = tester.getRect(find.byTooltip('设置'));

    expect(speakerRect.right, settingsRect.right);
    expect(speakerRect.center.dx - micRect.center.dx, 28);
    expect(speakerRect.center.dy, micRect.center.dy);
  });

  testWidgets('noise suppression control toggles from the status bar', (
    WidgetTester tester,
  ) async {
    var toggleCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CurrentUserBar(
            connected: true,
            displayName: 'Admin',
            online: true,
            muted: false,
            listenOff: false,
            noiseSuppressionEnabled: true,
            inputVolume: 0.8,
            outputVolume: 0.6,
            onMute: () {},
            onListenOff: () {},
            onNoiseSuppressionToggle: () => toggleCount += 1,
            onInputVolumeChanged: (_) {},
            onOutputVolumeChanged: (_) {},
            onSettings: () {},
          ),
        ),
      ),
    );

    if (kIsWeb) {
      expect(
        find.byKey(const ValueKey('noise-suppression-toggle')),
        findsNothing,
      );
      return;
    }
    final icon = tester.widget<Image>(
      find.byKey(const ValueKey('noise-suppression-icon')),
    );
    expect(
      (icon.image as AssetImage).assetName,
      'assets/images/noise_suppression.png',
    );
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('noise-suppression-icon')),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(opacity.opacity, 1);
    await tester.tap(find.byTooltip('关闭降噪'));
    expect(toggleCount, 1);
  });

  testWidgets('status and audio icon groups use mirrored spacing', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CurrentUserBar(
            connected: true,
            displayName: 'Admin',
            online: true,
            muted: false,
            canShareScreen: true,
            listenOff: false,
            inputVolume: 0.8,
            outputVolume: 0.6,
            onMute: () {},
            onListenOff: () {},
            onInputVolumeChanged: (_) {},
            onOutputVolumeChanged: (_) {},
            onScreenShare: () {},
            onSettings: () {},
          ),
        ),
      ),
    );

    final barRect = tester.getRect(find.byType(CurrentUserBar));
    final signalRect = tester.getRect(find.byType(NetworkQualityButton));
    final shareRect = tester.getRect(find.byIcon(Icons.screen_share));
    final micRect = tester.getRect(find.byIcon(Icons.mic));
    final micButtonRect = tester.getRect(find.byTooltip('静音'));
    final speakerRect = tester.getRect(find.byIcon(Icons.volume_up));
    final shareIcon = tester.widget<Icon>(find.byIcon(Icons.screen_share));

    final signalVisualLeft = signalRect.center.dx - 10;
    expect(signalVisualLeft - barRect.left, barRect.right - speakerRect.right);
    expect(shareRect.center.dx - signalRect.center.dx, 28);
    if (kIsWeb) {
      expect(
        find.byKey(const ValueKey('noise-suppression-toggle')),
        findsNothing,
      );
    } else {
      final noiseRect = tester.getRect(
        find.byKey(const ValueKey('noise-suppression-toggle')),
      );
      expect(noiseRect.size, const Size(56, 28));
      expect(noiseRect.right, micButtonRect.left);
      expect(signalRect.center.dy, noiseRect.center.dy);
    }
    expect(speakerRect.center.dx - micRect.center.dx, 28);
    expect(signalRect.center.dy, shareRect.center.dy);
    expect(signalRect.center.dy, micRect.center.dy);
    expect(signalRect.center.dy, speakerRect.center.dy);
    expect(shareIcon.color, Colors.white);
  });

  test(
    'network quality uses the worst latency, jitter, and packet-loss value',
    () {
      NetworkQuality quality({
        double? latencyMs = 80,
        double? latencyJitterMs = 5,
        double? upstreamPacketLoss = 0,
        double? downstreamPacketLoss = 0,
      }) => networkQualityForStats(
        latencyMs: latencyMs,
        latencyJitterMs: latencyJitterMs,
        upstreamPacketLoss: upstreamPacketLoss,
        downstreamPacketLoss: downstreamPacketLoss,
      );

      expect(quality().bars, 3);
      expect(quality(upstreamPacketLoss: 1).bars, 2);
      expect(quality(downstreamPacketLoss: 3.1).bars, 1);
      expect(quality(latencyMs: 150).bars, 2);
      expect(quality(latencyJitterMs: 31).bars, 1);
      expect(
        quality(upstreamPacketLoss: null, downstreamPacketLoss: null).bars,
        3,
      );
      expect(quality(latencyMs: null).bars, 0);
    },
  );

  test('voice media resets do not clear server latency', () {
    final snapshot = VoiceSessionSnapshot.initial().copyWith(
      upstreamPacketLoss: 1,
      downstreamPacketLoss: 2,
      latencyMs: 80,
      latencyJitterMs: 4,
    );

    final mediaReset = snapshot.copyWith(clearMediaNetworkStats: true);
    expect(mediaReset.upstreamPacketLoss, isNull);
    expect(mediaReset.downstreamPacketLoss, isNull);
    expect(mediaReset.latencyMs, 80);
    expect(mediaReset.latencyJitterMs, 4);

    final latencyReset = snapshot.copyWith(clearLatencyStats: true);
    expect(latencyReset.upstreamPacketLoss, 1);
    expect(latencyReset.downstreamPacketLoss, 2);
    expect(latencyReset.latencyMs, isNull);
    expect(latencyReset.latencyJitterMs, isNull);
  });

  test('ignores retired plaintext network probe fields', () {
    final token = VoiceToken.fromJson({
      'url': 'ws://voice.example.com:27420',
      'token': 'livekit-token',
      'can_publish': false,
      'network_probe': {
        'host': 'voice.example.com',
        'port': 27423,
        'token': 'opaque-probe-token',
        'protocol': 'udp-token-v1',
        'encrypted': false,
      },
    });

    expect(token.canPublish, isFalse);
    expect(token.canShareScreen, isFalse);
  });

  test('screen sharing exposes exactly the nine relay quality options', () {
    expect(screenShareQualities, hasLength(9));
    expect(
      screenShareQualities
          .map((quality) => '${quality.resolution}:${quality.fps}')
          .toSet(),
      {
        '720p:15',
        '720p:30',
        '720p:60',
        '1080p:15',
        '1080p:30',
        '1080p:60',
        'source:15',
        'source:30',
        'source:60',
      },
    );
    final source60 = screenShareVideoParameters(
      const ScreenShareQuality('source', 60),
    );
    expect(source60.dimensions.width, 3840);
    expect(source60.dimensions.height, 2160);
    expect(source60.encoding?.maxFramerate, 60);
    expect(source60.encoding?.bitratePriority, lk.Priority.high);
    expect(
      screenShareQualities.map(
        (quality) => screenShareVideoParameters(quality).encoding?.maxBitrate,
      ),
      [
        2000000,
        4000000,
        8000000,
        4000000,
        8000000,
        16000000,
        8000000,
        16000000,
        32000000,
      ],
    );
    expect(
      screenShareVideoParameters(
        const ScreenShareQuality('1080p', 60),
        maxBitrateMbps: 25,
      ).encoding?.maxBitrate,
      25000000,
    );
  });

  test('screen share bitrate settings parse defaults and overrides', () {
    final defaults = ScreenShareBitrateLimits.fromJson(null);
    expect(defaults.bitrateMbps('720p', 15), 2);
    expect(defaults.bitrateMbps('source', 60), 32);

    final custom = ScreenShareBitrateLimits.fromJson({
      '720p': {'15': 3, '30': 6, '60': 12},
      '1080p': {'15': 5, '30': 10, '60': 25},
      'source': {'15': 9, '30': 18, '60': 60},
    });
    expect(custom.bitrateMbps('1080p', 60), 25);
    expect(custom.bitrateMbps('source', 60), 60);
    expect(custom.toJson()['720p'], {'15': 3, '30': 6, '60': 12});

    final partial = ScreenShareBitrateLimits.fromJson({
      '720p': {'15': 0, '30': 7},
    });
    expect(partial.bitrateMbps('720p', 15), 2);
    expect(partial.bitrateMbps('720p', 30), 7);
    expect(partial.bitrateMbps('1080p', 60), 16);
  });

  test('native desktop screen sharing requires only H264', () {
    final encoding = screenShareVideoParameters(
      const ScreenShareQuality('1080p', 60),
    ).encoding;
    final macOS = screenShareVideoPublishOptions(
      encoding,
      TargetPlatform.macOS,
      isWeb: false,
    );
    final windows = screenShareVideoPublishOptions(
      encoding,
      TargetPlatform.windows,
      isWeb: false,
    );
    final web = screenShareVideoPublishOptions(
      encoding,
      TargetPlatform.macOS,
      isWeb: true,
    );

    expect(macOS.videoCodec, 'h264');
    expect(macOS.backupVideoCodec.enabled, isFalse);
    expect(
      macOS.degradationPreference,
      lk.DegradationPreference.maintainFramerate,
    );
    expect(macOS.screenShareEncoding, same(encoding));
    expect(windows.videoCodec, 'h264');
    expect(windows.backupVideoCodec.enabled, isFalse);
    expect(windows.degradationPreference, isNull);
    expect(web.videoCodec, 'vp8');
    expect(web.degradationPreference, isNull);
  });

  test('screen share diagnostics calculate native and web RTP bitrate', () {
    expect(
      rtpBitrateBitsPerSecond(
        bytes: 5000000,
        previousBytes: 0,
        timestamp: 6000000,
        previousTimestamp: 1000000,
        timestampInMicroseconds: true,
      ),
      8000000,
    );
    expect(
      rtpBitrateBitsPerSecond(
        bytes: 5000000,
        previousBytes: 0,
        timestamp: 6000,
        previousTimestamp: 1000,
        timestampInMicroseconds: false,
      ),
      8000000,
    );
    expect(
      counterAverageDelta(
        total: 900,
        previousTotal: 300,
        count: 40,
        previousCount: 20,
      ),
      30,
    );
  });

  test('screen share diagnostics read RTT from the selected ICE pair', () {
    expect(
      selectedCandidatePairRoundTripTime([
        rtc.StatsReport('transport', 'transport', 1, {
          'selectedCandidatePairId': 'pair',
        }),
        rtc.StatsReport('pair', 'candidate-pair', 1, {
          'currentRoundTripTime': 0.042,
        }),
      ]),
      0.042,
    );
    expect(
      selectedCandidatePairRoundTripTime([
        rtc.StatsReport('pair', 'candidate-pair', 1, {
          'selected': true,
          'currentRoundTripTime': 0.025,
        }),
      ]),
      0.025,
    );
  });

  test('screen share qualities are the cross product of role permissions', () {
    final qualities = allowedScreenShareQualities({
      voiceScreenSharePermission,
      screenShareResolutionPermissions['720p']!,
      screenShareResolutionPermissions['source']!,
      screenShareFPSPermissions[15]!,
      screenShareFPSPermissions[60]!,
    });
    expect(qualities.map((quality) => quality.label), [
      '720p · 15 FPS',
      '720p · 60 FPS',
      'Source · 15 FPS',
      'Source · 60 FPS',
    ]);
  });

  testWidgets(
    'screen share viewer controls fold and use audio-button spacing',
    (WidgetTester tester) async {
      var collapsed = false;
      var expanded = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => ScreenShareViewerActions(
                collapsed: collapsed,
                onToggleCollapsed: () => setState(() => collapsed = !collapsed),
                onMaximize: () => expanded = true,
              ),
            ),
          ),
        ),
      );

      final collapse = find.byKey(const ValueKey('screen-share-collapse'));
      final expand = find.byKey(const ValueKey('screen-share-expand'));
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);
      expect(find.byTooltip('最大化窗口'), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
      expect(tester.getCenter(expand).dx - tester.getCenter(collapse).dx, 28);

      await tester.tap(collapse);
      await tester.pump();
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
      await tester.tap(expand);
      expect(expanded, isTrue);
    },
  );

  test('screen share panel removes side bars and keeps its maximum width', () {
    expect(screenShareAspectRatioForDimensions(1920, 1080), 16 / 9);
    expect(screenShareAspectRatioForDimensions(0, 1080), isNull);
    expect(
      screenShareStagePanelWidth(
        maxWidth: 1600,
        maxHeight: 500,
        aspectRatio: 16 / 9,
      ),
      closeTo((500 - 14 - 38 - 2) * 16 / 9 + 2, 0.01),
    );
    expect(
      screenShareStagePanelWidth(
        maxWidth: 800,
        maxHeight: 500,
        aspectRatio: 16 / 9,
      ),
      768,
    );
  });

  testWidgets('screen share floats without reserving chat layout space', (
    WidgetTester tester,
  ) async {
    const chatKey = ValueKey('overlay-chat');
    const stageKey = ValueKey('overlay-stage');
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 700,
            height: 500,
            child: screenShareOverlay(
              chat: const ColoredBox(key: chatKey, color: Colors.black),
              stage: const ColoredBox(key: stageKey, color: Colors.white),
              stageWidth: 300,
              stageHeight: 200,
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(chatKey)), const Size(700, 500));
    expect(tester.getSize(find.byKey(stageKey)), const Size(300, 200));
    expect(
      tester.getTopLeft(find.byKey(stageKey)),
      tester.getTopLeft(find.byKey(chatKey)) + const Offset(400, 0),
    );
  });

  testWidgets('screen share opens maximized and has one restore action', (
    WidgetTester tester,
  ) async {
    final controller = VoiceSessionController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => ScreenShareWindow(controller: controller),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('屏幕共享'), findsOneWidget);
    expect(find.text('屏幕共享已结束'), findsOneWidget);
    final windowContext = tester.element(find.byType(ScreenShareWindow));
    expect(
      tester.getSize(find.byType(ScreenShareHeader)).width,
      closeTo(MediaQuery.sizeOf(windowContext).width - 16, 0.01),
    );

    expect(find.byTooltip('还原窗口'), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
    expect(
      find.byKey(const ValueKey('screen-share-window-maximize')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('settings-dialog-resize-bottomRight')),
      findsNothing,
    );
    expect(find.byIcon(Icons.picture_in_picture_alt_rounded), findsNothing);

    await tester.tap(find.byTooltip('还原窗口'));
    await tester.pumpAndSettle();
    expect(find.byType(ScreenShareWindow), findsNothing);
  });

  test(
    'screen sharing fits Windows source frames inside the selected size',
    () {
      final target = screenShareVideoParameters(
        const ScreenShareQuality('720p', 30),
      ).dimensions;

      expect(
        screenShareScaleDownBy(
          sourceWidth: 2560,
          sourceHeight: 1440,
          target: target,
        ),
        2,
      );
      expect(
        screenShareScaleDownBy(
          sourceWidth: 3440,
          sourceHeight: 1440,
          target: target,
        ),
        closeTo(2.6875, 0.0001),
      );
      expect(
        screenShareScaleDownBy(
          sourceWidth: 1024,
          sourceHeight: 576,
          target: target,
        ),
        1,
      );
    },
  );

  testWidgets('network status button opens the stats card', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CurrentUserBar(
            connected: true,
            displayName: 'Admin',
            online: true,
            muted: false,
            listenOff: false,
            inputVolume: 0.8,
            outputVolume: 0.6,
            upstreamPacketLoss: 1.25,
            downstreamPacketLoss: 2.75,
            latencyMs: 86.4,
            latencyJitterMs: 3.45,
            onMute: () {},
            onListenOff: () {},
            onInputVolumeChanged: (_) {},
            onOutputVolumeChanged: (_) {},
            onSettings: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('网络状态'));
    await tester.pump();

    expect(find.byType(NetworkStatsCard), findsOneWidget);
    expect(find.text('上行丢包'), findsOneWidget);
    expect(find.text('1.3%'), findsOneWidget);
    expect(find.text('下行丢包'), findsOneWidget);
    expect(find.text('2.8%'), findsOneWidget);
    expect(find.text('延迟'), findsOneWidget);
    expect(find.text('86 ms ± 3.5 ms'), findsOneWidget);
  });

  testWidgets('muted input and output volume popovers show zero', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CurrentUserBar(
            connected: true,
            displayName: 'Admin',
            online: true,
            muted: true,
            listenOff: true,
            inputVolume: 0.8,
            outputVolume: 0.6,
            onMute: () {},
            onListenOff: () {},
            onInputVolumeChanged: (_) {},
            onOutputVolumeChanged: (_) {},
            onSettings: () {},
          ),
        ),
      ),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer();
    await gesture.moveTo(tester.getCenter(find.byIcon(Icons.mic_off).first));
    await tester.pump();
    expect(find.bySemanticsLabel('麦克风音量 0%'), findsOneWidget);

    await gesture.moveTo(tester.getCenter(find.byIcon(Icons.volume_off).first));
    await tester.pump();
    expect(find.bySemanticsLabel('扬声器音量 0%'), findsOneWidget);
    await gesture.removePointer();
  });

  testWidgets('channel mute and deafen badges keep the same center', (
    WidgetTester tester,
  ) async {
    Future<Offset> badgeCenter(VoiceState? voiceState) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(child: ChannelMemberVoiceBadge(voiceState: voiceState)),
        ),
      );
      return tester.getCenter(
        find.byKey(const ValueKey('channel-member-voice-badge')),
      );
    }

    final mutedCenter = await badgeCenter(
      VoiceState(
        serverId: 'server',
        userId: 'user',
        displayName: 'User',
        channelId: 'channel',
        muted: true,
        deafened: false,
        speaking: false,
      ),
    );
    final deafenedCenter = await badgeCenter(
      VoiceState(
        serverId: 'server',
        userId: 'user',
        displayName: 'User',
        channelId: 'channel',
        muted: true,
        deafened: true,
        speaking: false,
      ),
    );

    expect(deafenedCenter, mutedCenter);
  });

  testWidgets(
    'missing audio devices use red badges distinct from manual mute',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: ChannelMemberVoiceBadge(
              voiceState: null,
              microphoneUnavailable: true,
              speakerUnavailable: true,
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('channel-member-device-unavailable-badge')),
        findsOneWidget,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.mic_off)).color,
        OsColors.danger,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.volume_off)).color,
        OsColors.danger,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ChannelMemberVoiceBadge(
              voiceState: VoiceState(
                serverId: 'server',
                userId: 'user',
                displayName: 'User',
                channelId: 'channel',
                muted: true,
                deafened: false,
                speaking: false,
              ),
            ),
          ),
        ),
      );

      expect(
        tester.widget<Icon>(find.byIcon(Icons.mic_off)).color,
        OsColors.dim,
      );
    },
  );

  testWidgets('speaking avatar has no green dot and releases after 200ms', (
    WidgetTester tester,
  ) async {
    VoiceState voiceState({required bool speaking}) => VoiceState(
      serverId: 'server',
      userId: 'user',
      displayName: 'User',
      channelId: 'channel',
      muted: false,
      deafened: false,
      speaking: speaking,
    );

    Widget avatar(VoiceState state) => MaterialApp(
      home: Center(
        child: ChannelMemberSpeakingAvatar(
          displayName: 'User',
          online: true,
          voiceState: state,
        ),
      ),
    );

    await tester.pumpWidget(avatar(voiceState(speaking: false)));
    expect(
      find.byKey(const ValueKey('channel-member-speaking-avatar-idle')),
      findsOneWidget,
    );

    await tester.pumpWidget(avatar(voiceState(speaking: true)));
    expect(
      find.byKey(const ValueKey('channel-member-speaking-avatar-active')),
      findsOneWidget,
    );
    final activeAvatar = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('channel-member-speaking-avatar-active')),
    );
    final activeDecoration = activeAvatar.decoration! as BoxDecoration;
    expect(activeAvatar.duration, Duration.zero);
    expect(activeDecoration.boxShadow, isNull);
    expect(
      find.byKey(const ValueKey('channel-member-voice-badge')),
      findsNothing,
    );

    await tester.pumpWidget(avatar(voiceState(speaking: false)));
    await tester.pump(const Duration(milliseconds: 199));
    expect(
      find.byKey(const ValueKey('channel-member-speaking-avatar-active')),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 1));
    expect(
      find.byKey(const ValueKey('channel-member-speaking-avatar-idle')),
      findsOneWidget,
    );
  });

  testWidgets('ordinary online channel members have no green badge', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: ChannelMemberVoiceBadge(voiceState: null)),
      ),
    );

    expect(
      find.byKey(const ValueKey('channel-member-voice-badge')),
      findsNothing,
    );
  });

  testWidgets('channel member role badges distinguish owner and admin', (
    WidgetTester tester,
  ) async {
    Future<void> pumpBadge(String role) => tester.pumpWidget(
      MaterialApp(
        home: Center(child: ChannelMemberRoleBadge(role: role)),
      ),
    );

    await pumpBadge('owner');
    final owner = tester.widget<Icon>(
      find.byKey(const ValueKey('channel-member-owner-badge')),
    );
    expect(owner.icon, Icons.bookmark_rounded);
    expect(owner.color, const Color(0xFFFFC928));
    expect(
      find.byKey(const ValueKey('channel-member-admin-badge')),
      findsNothing,
    );

    await pumpBadge('admin');
    final admin = tester.widget<Icon>(
      find.byKey(const ValueKey('channel-member-admin-badge')),
    );
    expect(admin.icon, Icons.stars_rounded);
    expect(admin.color, const Color(0xFF3297F5));
    expect(
      find.byKey(const ValueKey('channel-member-owner-badge')),
      findsNothing,
    );

    await pumpBadge('user');
    expect(find.byType(Icon), findsNothing);
  });

  testWidgets('server screen share state shows a badge left of the role', (
    WidgetTester tester,
  ) async {
    final user = PresenceUser(
      userId: 'owner',
      displayName: 'Owner',
      role: 'owner',
      online: true,
      devices: const [],
      currentChannelId: 'channel',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: ChannelMemberSubTile(
              user: user,
              voiceState: VoiceState(
                serverId: 'server',
                userId: 'owner',
                displayName: 'Owner',
                channelId: 'channel',
                muted: false,
                deafened: false,
                speaking: false,
                screenSharing: true,
              ),
              unreadCount: 0,
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    final share = find.byKey(
      const ValueKey('channel-member-screen-share-badge'),
    );
    final owner = find.byKey(const ValueKey('channel-member-owner-badge'));
    expect(tester.widget<Icon>(share).color, OsColors.green);
    expect(tester.getRect(share).right, lessThan(tester.getRect(owner).left));
  });

  testWidgets(
    'channel tile selects immediately and only joins on double click',
    (WidgetTester tester) async {
      var selections = 0;
      var joins = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            useMaterial3: false,
            splashFactory: InkRipple.splashFactory,
          ),
          home: Scaffold(
            body: ChannelTile(
              channel: Channel(id: 'channel', name: '频道', sortOrder: 0),
              selected: false,
              unreadCount: 0,
              mentionCount: 0,
              members: const [],
              directUnreadCounts: const {},
              voiceStatesByUserId: const {},
              currentUserId: null,
              currentUserMicrophoneUnavailable: false,
              currentUserSpeakerUnavailable: false,
              onTap: () => selections += 1,
              onDoubleTap: () => joins += 1,
              onSecondaryTapDown: (_) {},
              onMemberTap: (_) {},
              onMemberSecondaryTapDown: (_, _) {},
            ),
          ),
        ),
      );

      final channel = find.text('频道');
      await tester.tap(channel);
      await tester.pump();
      final material = Material.of(tester.element(channel));
      expect(material, paintsExactlyCountTimes(#drawCircle, 1));
      expect(selections, 1);
      expect(joins, 0);
      await tester.pumpAndSettle();

      await tester.tap(channel);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(channel);
      await tester.pump(const Duration(milliseconds: 400));
      expect(selections, 3);
      expect(joins, 1);
      await tester.pumpAndSettle();

      final drag = await tester.startGesture(tester.getCenter(channel));
      await drag.moveBy(const Offset(50, 0));
      await drag.up();
      await tester.tap(channel);
      await tester.pump(const Duration(milliseconds: 400));
      expect(selections, 5);
      expect(joins, 1);
      await tester.pumpAndSettle();

      await tester.tap(channel);
      await tester.pump(const Duration(milliseconds: 50));
      final heldSecondTap = await tester.startGesture(
        tester.getCenter(channel),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await heldSecondTap.up();
      await tester.pump();
      expect(selections, 7);
      expect(joins, 2);
      await tester.pumpAndSettle();

      await tester.tap(channel);
      final tooFastSecondTap = await tester.startGesture(
        tester.getCenter(channel),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tooFastSecondTap.up();
      await tester.pump();
      expect(selections, 9);
      expect(joins, 2);
      await tester.pumpAndSettle();
    },
  );

  test('channel reorder moves the whole channel and normalizes sort order', () {
    final channels = [
      Channel(id: 'a', name: 'A', sortOrder: 4),
      Channel(id: 'b', name: 'B', sortOrder: 9),
      Channel(id: 'c', name: 'C', sortOrder: 12),
    ];

    final reordered = channelsAfterMove(channels, 0, 2);

    expect(reordered.map((channel) => channel.id), ['b', 'c', 'a']);
    expect(reordered.map((channel) => channel.sortOrder), [0, 1, 2]);
  });

  testWidgets('channel member row reports secondary clicks', (
    WidgetTester tester,
  ) async {
    var secondaryClicks = 0;
    final user = PresenceUser(
      userId: 'member',
      displayName: 'Member',
      role: 'user',
      online: true,
      devices: const [],
      currentChannelId: 'channel',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: ChannelMemberSubTile(
              user: user,
              voiceState: null,
              unreadCount: 0,
              onTap: () {},
              onSecondaryTapDown: (_) => secondaryClicks += 1,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Member'), buttons: kSecondaryMouseButton);
    expect(secondaryClicks, 1);
  });

  testWidgets('member move permission drags a user onto another channel', (
    WidgetTester tester,
  ) async {
    final user = PresenceUser(
      userId: 'member',
      displayName: 'Member',
      role: 'user',
      online: true,
      devices: const [],
      currentChannelId: 'source',
    );
    String? movedUserId;
    Widget channelTile(Channel channel, List<PresenceUser> members) =>
        ChannelTile(
          channel: channel,
          selected: false,
          unreadCount: 0,
          mentionCount: 0,
          members: members,
          directUnreadCounts: const {},
          voiceStatesByUserId: const {},
          currentUserId: 'manager',
          currentUserMicrophoneUnavailable: false,
          currentUserSpeakerUnavailable: false,
          onTap: () {},
          onDoubleTap: () {},
          onSecondaryTapDown: (_) {},
          onMemberTap: (_) {},
          onMemberSecondaryTapDown: (_, _) {},
          canMoveMembers: true,
          onMemberDropped: (member) => movedUserId = member.userId,
        );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: Column(
              children: [
                channelTile(Channel(id: 'source', name: '原频道', sortOrder: 0), [
                  user,
                ]),
                channelTile(
                  Channel(id: 'target', name: '目标频道', sortOrder: 1),
                  const [],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Draggable<PresenceUser>), findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Member')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(tester.getCenter(find.text('目标频道')));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(movedUserId, 'member');
  });

  test('detects previewable http and www links', () {
    expect(
      firstPreviewableUrl('看这个 https://www.bilibili.com/'),
      'https://www.bilibili.com/',
    );
    expect(
      firstPreviewableUrl('看这个 www.bilibili.com'),
      'https://www.bilibili.com',
    );
    expect(firstPreviewableUrl('ftp://example.com'), isNull);
    expect(firstPreviewableUrl('http://127.0.0.1:27410'), isNull);
  });

  test('builds fallback link preview when metadata is unavailable', () {
    final preview = fallbackLinkPreview('https://www.bilibili.com/');
    expect(preview.hasContent, isTrue);
    expect(preview.domain, 'www.bilibili.com');
    expect(preview.title, 'www.bilibili.com');
    expect(preview.description, isEmpty);
    expect(linkPreviewDescription(preview), isEmpty);
  });

  test('parses client-side link preview html metadata', () {
    final preview = parseLinkPreviewHtml('''
      <html><head>
        <title>Fallback title</title>
        <meta property="og:title" content="OG Title">
        <meta name="description" content="Plain description">
        <meta property="og:description" content="OG Description">
        <meta property="og:image" content="/cover.png">
      </head></html>
      ''', Uri.parse('https://example.com/post'));

    expect(preview.title, 'OG Title');
    expect(preview.description, 'OG Description');
    expect(preview.imageUrl, 'https://example.com/cover.png');
  });

  test('uses known-site metadata when client fetch is unavailable', () {
    final preview = fallbackLinkPreview('https://www.youtube.com');
    expect(preview.title, 'YouTube');
    expect(preview.description, contains('Enjoy the videos and music'));
    expect(preview.imageUrl, contains('google.com/s2/favicons'));
  });

  testWidgets('link preview message keeps a compact row height', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 700,
            child: ListView(
              children: [
                ChatMessageRow(
                  body: 'https://www.bilibili.com/',
                  attachment: null,
                  sentAt: DateTime(2026, 7, 8, 2, 18),
                  senderName: 'Admin',
                  mine: true,
                  ensureCached: (_) async => throw UnimplementedError(),
                  loadImagePreview: (_) async => throw UnimplementedError(),
                  loadAudioMetadata: (_) async => throw UnimplementedError(),
                  linkPreviewFallback: fallbackLinkPreview(
                    'https://www.bilibili.com/',
                  ),
                  linkPreviewFuture: null,
                  onOpen: (_) async {},
                  onSaveAs: (_) async {},
                  onOpenLink: (_) async {},
                  downloadTask: null,
                  onCancelDownload: (_) {},
                  activeAudioFileId: null,
                  audioLoadingFileId: null,
                  audioPlaying: false,
                  audioPosition: Duration.zero,
                  audioDuration: Duration.zero,
                  onToggleAudio: (_) async {},
                  onSeekAudio: (_) async {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final rowSize = tester.getSize(find.byType(ChatMessageRow));
    expect(rowSize.height, lessThan(220));

    final bubble = find.byKey(
      const ValueKey('chat-message-bubble-context-target'),
    );
    final position = tester.getTopLeft(bubble) + const Offset(2, 2);
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.addPointer(location: position);
    await gesture.down(position);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
  });

  testWidgets('message body links are clickable', (tester) async {
    String? openedUrl;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBodyText(
            body: '镜像站 https://ip.skk.moe/',
            mine: false,
            onOpenLink: (url) async {
              openedUrl = url;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('https://ip.skk.moe/'));
    await tester.pump();

    expect(openedUrl, 'https://ip.skk.moe/');
  });

  testWidgets('channel message text context menu exposes retract action', (
    tester,
  ) async {
    var retracted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBodyText(
            body: '可撤回的消息',
            mine: true,
            onOpenLink: (_) async {},
            messageActionLabel: '撤回消息',
            onMessageAction: () => retracted = true,
          ),
        ),
      ),
    );

    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.addPointer(location: tester.getCenter(find.text('可撤回的消息')));
    await gesture.down(tester.getCenter(find.text('可撤回的消息')));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('撤回消息'), findsOneWidget);
    await tester.tap(find.text('撤回消息'));
    expect(retracted, isTrue);
  });

  testWidgets('right click does not auto-select message text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: MessageBodyText(
            body: '右键不应该选中这段文字',
            mine: false,
            onOpenLink: (_) async {},
          ),
        ),
      ),
    );

    final text = find.byType(TextField);
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.addPointer(location: tester.getCenter(text));
    await gesture.down(tester.getCenter(text));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    expect(editable.currentTextEditingValue.selection.isCollapsed, isTrue);
    expect(find.text('复制'), findsOneWidget);
  });

  testWidgets('text context menu is localized and content-sized', (
    tester,
  ) async {
    final items = osEditableContextMenuItems([
      const ContextMenuButtonItem(
        onPressed: null,
        type: ContextMenuButtonType.cut,
      ),
      const ContextMenuButtonItem(
        onPressed: null,
        type: ContextMenuButtonType.copy,
      ),
    ], () {});
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: OsCompactTextSelectionToolbar(
          anchors: const TextSelectionToolbarAnchors(
            primaryAnchor: Offset(20, 20),
          ),
          buttonItems: items,
        ),
      ),
    );

    expect(find.text('剪切'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('粘贴'), findsOneWidget);
    expect(
      tester.getCenter(find.text('复制')).dx,
      closeTo(
        tester
            .getCenter(
              find.byKey(const ValueKey('compact-text-selection-toolbar')),
            )
            .dx,
        0.01,
      ),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('compact-text-selection-toolbar')))
          .width,
      lessThan(222),
    );
  });

  test('detects audio attachments from windows-style names', () {
    expect(
      isAudioContent('', r'F:\Music\✦世界情绪 - 创生_Instrumental-.mp3'),
      isTrue,
    );
    expect(isAudioContent('application/octet-stream', 'song.FLAC '), isTrue);
    expect(contentTypeForPath(r'F:\Music\track.MP3 '), 'audio/mpeg');
    expect(
      attachmentContentType('application/octet-stream', 'song.FLAC '),
      'audio/flac',
    );
    expect(
      attachmentContentType(
        'Application/Octet-Stream ; charset=binary',
        'song.mp3',
      ),
      'audio/mpeg',
    );
    expect(attachmentContentType('audio/custom', 'song.mp3'), 'audio/custom');
    expect(isAudioContent('application/pdf', '音乐 文件.pdf'), isFalse);
  });

  test('parses local audio proxy ranges for streaming playback', () {
    final initial = parseProxyRange(null, 5 * 1024 * 1024);
    expect(initial, isNull);

    final tiny = parseProxyRange('bytes=0-1', 5 * 1024 * 1024);
    expect(tiny?.start, 0);
    expect(tiny?.end, 1);

    final openEnded = parseProxyRange('bytes=1024-', 5 * 1024 * 1024);
    expect(openEnded?.start, 1024);
    expect(openEnded?.end, 5 * 1024 * 1024 - 1);

    final longRange = parseProxyRange('bytes=0-8284880', 8284881);
    expect(longRange?.start, 0);
    expect(longRange?.end, 8284880);
    expect(audioProxyFetchSize(0, 0), audioProxyInitialBurstBytes);
    expect(
      audioProxyFetchSize(0, audioProxyFetchChunkBytes),
      audioProxyFetchChunkBytes,
    );
    expect(
      audioProxyFetchSize(audioProxyFetchChunkBytes, audioProxyFetchChunkBytes),
      audioProxyFetchChunkBytes,
    );
  });

  test('stopped audio proxy reloads a newly cached source before resuming', () {
    expect(
      shouldReloadAudioSource(
        proxySourceStopped: true,
        localSourceAvailable: true,
      ),
      isTrue,
    );
    expect(
      shouldReloadAudioSource(
        proxySourceStopped: false,
        localSourceAvailable: true,
      ),
      isFalse,
    );
  });

  test('parses flac vorbis comments and front cover metadata', () {
    final commentBlock = _buildVorbisCommentBlock([
      'TITLE=届かない恋',
      'ARTIST=冬馬かずさ',
    ]);
    final coverBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
    final pictureBlock = _buildFlacPictureBlock(coverBytes);
    final flac = Uint8List.fromList([
      0x66,
      0x4C,
      0x61,
      0x43,
      ..._flacBlockHeader(type: 4, length: commentBlock.length),
      ...commentBlock,
      ..._flacBlockHeader(type: 6, length: pictureBlock.length, isLast: true),
      ...pictureBlock,
    ]);

    expect(flacMetadataLength(flac), flac.length);
    final metadata = parseFlacMetadata(flac);
    expect(metadata.title, '届かない恋');
    expect(metadata.artist, '冬馬かずさ');
    expect(metadata.coverBytes, coverBytes);
  });

  test('parses ID3v2.4 unsynchronized APIC cover metadata', () {
    final titleFrame = _buildID3v24Frame('TIT2', [
      3,
      ...utf8.encode('热爱105°C的你'),
    ]);
    final artistFrame = _buildID3v24Frame('TPE1', [3, ...utf8.encode('早稻叽')]);
    final coverBytes = Uint8List.fromList([
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      0x00,
      0x10,
      0xFF,
      0xDB,
      0xFF,
      0xD9,
    ]);
    final apicPayload = <int>[
      0,
      ...ascii.encode('image/jpeg'),
      0,
      3,
      0,
      ..._applyID3Unsynchronization(coverBytes),
    ];
    final apicDataLengthIndicator = <int>[];
    _appendSynchsafe32(apicDataLengthIndicator, apicPayload.length);
    final apicFrame = _buildID3v24Frame(
      'APIC',
      [...apicDataLengthIndicator, ...apicPayload],
      flags: [0x00, 0x03],
    );
    final metadata = parseID3v2Metadata(
      Uint8List.fromList([...titleFrame, ...artistFrame, ...apicFrame]),
      majorVersion: 4,
      unsynchronized: true,
    );

    expect(metadata.title, '热爱105°C的你');
    expect(metadata.artist, '早稻叽');
    expect(metadata.coverBytes, coverBytes);
  });

  test('parses m4a mp4 title artist and cover metadata', () {
    final coverBytes = Uint8List.fromList([
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
    ]);
    final ilst = _mp4Atom('ilst', [
      ..._mp4Atom('©nam', _mp4DataAtom(1, utf8.encode('Hibiki'))),
      ..._mp4Atom('©ART', _mp4DataAtom(1, utf8.encode('Akiko Shikata'))),
      ..._mp4Atom('covr', _mp4DataAtom(14, coverBytes)),
    ]);
    final mp4 = Uint8List.fromList([
      ..._mp4Atom('ftyp', ascii.encode('M4A \x00\x00\x00\x00M4A ')),
      ..._mp4Atom(
        'moov',
        _mp4Atom('udta', _mp4Atom('meta', [0, 0, 0, 0, ...ilst])),
      ),
    ]);

    final metadata = parseMp4Metadata(mp4.sublist(20));
    expect(metadata.title, 'Hibiki');
    expect(metadata.artist, 'Akiko Shikata');
    expect(metadata.coverBytes, coverBytes);
  });

  test('locates m4a moov metadata and parses jpeg cover with hdlr', () async {
    final coverBytes = _jpegCoverBytes();
    final mp4 = _buildM4aWithJpegCover(coverBytes);

    final metadata = await readMp4MetadataFromRanges(
      sizeBytes: mp4.length,
      readRange: (start, endInclusive) async {
        return Uint8List.sublistView(mp4, start, endInclusive + 1);
      },
    );
    expect(metadata.title, 'Hibiki');
    expect(metadata.artist, 'Akiko Shikata');
    expect(metadata.coverBytes, coverBytes);
  });

  test('reads m4a mp4 cover metadata from a local file', () async {
    final coverBytes = _jpegCoverBytes();
    final dir = await Directory.systemTemp.createTemp('openspeak-m4a-test-');
    try {
      final file = File('${dir.path}/hibiki.m4a');
      await file.writeAsBytes(_buildM4aWithJpegCover(coverBytes));

      final metadata = await readAudioAttachmentMetadataFromFile(file);
      expect(metadata.title, 'Hibiki');
      expect(metadata.artist, 'Akiko Shikata');
      expect(metadata.coverBytes, coverBytes);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}

List<int> _buildID3v24Frame(
  String id,
  List<int> payload, {
  List<int> flags = const [0x00, 0x00],
}) {
  final out = <int>[...ascii.encode(id)];
  _appendSynchsafe32(out, payload.length);
  out.addAll(flags);
  out.addAll(payload);
  return out;
}

List<int> _mp4Atom(String type, List<int> payload) {
  final out = <int>[];
  _appendUint32BE(out, payload.length + 8);
  out.addAll(latin1.encode(type));
  out.addAll(payload);
  return out;
}

List<int> _mp4DataAtom(int dataType, List<int> payload) {
  final out = <int>[];
  _appendUint32BE(out, dataType);
  _appendUint32BE(out, 0);
  out.addAll(payload);
  return _mp4Atom('data', out);
}

Uint8List _jpegCoverBytes() {
  return Uint8List.fromList([
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    0x00,
    0x10,
    ...ascii.encode('JFIF'),
    0x00,
    0x01,
    0x01,
    0x00,
  ]);
}

Uint8List _buildM4aWithJpegCover(Uint8List coverBytes) {
  final ilst = _mp4Atom('ilst', [
    ..._mp4Atom('©nam', _mp4DataAtom(1, utf8.encode('Hibiki'))),
    ..._mp4Atom('©ART', _mp4DataAtom(1, utf8.encode('Akiko Shikata'))),
    ..._mp4Atom('covr', _mp4DataAtom(13, coverBytes)),
  ]);
  return Uint8List.fromList([
    ..._mp4Atom('ftyp', ascii.encode('M4A \x00\x00\x00\x00M4A ')),
    ..._mp4Atom('free', const []),
    ..._mp4Atom(
      'moov',
      _mp4Atom(
        'udta',
        _mp4Atom('meta', [
          0,
          0,
          0,
          0,
          ..._mp4Atom('hdlr', List<int>.filled(25, 0)),
          ...ilst,
        ]),
      ),
    ),
    ..._mp4Atom('mdat', List<int>.filled(64, 0)),
  ]);
}

List<int> _applyID3Unsynchronization(Uint8List bytes) {
  final out = <int>[];
  for (var i = 0; i < bytes.length; i += 1) {
    out.add(bytes[i]);
    if (bytes[i] == 0xFF &&
        i + 1 < bytes.length &&
        (bytes[i + 1] == 0x00 || bytes[i + 1] >= 0xE0)) {
      out.add(0x00);
    }
  }
  return out;
}

Uint8List _buildVorbisCommentBlock(List<String> comments) {
  final vendor = utf8.encode('OpenSpeak');
  final out = <int>[];
  _appendUint32LE(out, vendor.length);
  out.addAll(vendor);
  _appendUint32LE(out, comments.length);
  for (final comment in comments) {
    final bytes = utf8.encode(comment);
    _appendUint32LE(out, bytes.length);
    out.addAll(bytes);
  }
  return Uint8List.fromList(out);
}

Uint8List _buildFlacPictureBlock(Uint8List imageBytes) {
  final mime = ascii.encode('image/jpeg');
  final out = <int>[];
  _appendUint32BE(out, 3);
  _appendUint32BE(out, mime.length);
  out.addAll(mime);
  _appendUint32BE(out, 0);
  _appendUint32BE(out, 300);
  _appendUint32BE(out, 300);
  _appendUint32BE(out, 24);
  _appendUint32BE(out, 0);
  _appendUint32BE(out, imageBytes.length);
  out.addAll(imageBytes);
  return Uint8List.fromList(out);
}

List<int> _flacBlockHeader({
  required int type,
  required int length,
  bool isLast = false,
}) {
  return [
    (isLast ? 0x80 : 0) | type,
    (length >> 16) & 0xFF,
    (length >> 8) & 0xFF,
    length & 0xFF,
  ];
}

void _appendUint32BE(List<int> out, int value) {
  out.addAll([
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ]);
}

void _appendSynchsafe32(List<int> out, int value) {
  out.addAll([
    (value >> 21) & 0x7F,
    (value >> 14) & 0x7F,
    (value >> 7) & 0x7F,
    value & 0x7F,
  ]);
}

void _appendUint32LE(List<int> out, int value) {
  out.addAll([
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ]);
}
