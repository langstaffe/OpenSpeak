import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, LengthLimitingTextInputFormatter;

import 'openspeak_api.dart';
import 'os_avatar.dart';
import 'os_settings_shell.dart';
import 'os_theme.dart';
import 'screen_share.dart';

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

typedef ServerSettingsDialogResult = ({
  String action,
  Set<String> adminPermissions,
  String attachmentMode,
  File? avatarFile,
  bool clearServerPassword,
  String? defaultChannelId,
  String encryptionMode,
  String fileNodeHost,
  String fileNodePath,
  String fileNodePort,
  String fileNodeSecret,
  String? selectedFileNodeId,
  String historyRetentionDays,
  String mediaNodeHost,
  String mediaNodeKey,
  String mediaNodeName,
  String mediaNodePath,
  String mediaNodePort,
  String mediaNodeSecret,
  String? selectedMediaNodeId,
  int messageRetractWindowMinutes,
  String password,
  String screenRelayMode,
  Map<(String, int), String> screenShareBitrates,
  String serverName,
  String tlsCertificateType,
  String tlsIdentifier,
  Set<String> userPermissions,
  int voiceAudioBitrateKbps,
  bool webCustomPathEnabled,
  bool webEnabled,
  String webPath,
});

class OsServerSettingsDialog extends StatefulWidget {
  const OsServerSettingsDialog({
    super.key,
    required this.api,
    required this.authToken,
    required this.serverId,
    required this.serverName,
    required this.server,
    required this.channels,
    required this.mediaNodes,
    required this.fileNodes,
    required this.permissionSettings,
    required this.currentMessageRetractWindowMinutes,
    required this.webSettings,
    required this.ownerStatus,
    required this.isOwner,
    required this.canEditProfile,
    required this.allowedPages,
    required this.initialPage,
    required this.cachedServerAvatar,
  });

  final OpenSpeakApi api;
  final String authToken;
  final String serverId;
  final String serverName;
  final OsServer server;
  final List<Channel> channels;
  final List<MediaNode> mediaNodes;
  final List<FileNode> fileNodes;
  final ServerPermissionSettings? permissionSettings;
  final int currentMessageRetractWindowMinutes;
  final WebSettings? webSettings;
  final OwnerStatus? ownerStatus;
  final bool isOwner;
  final bool canEditProfile;
  final List<String> allowedPages;
  final String initialPage;
  final File? cachedServerAvatar;

  @override
  State<OsServerSettingsDialog> createState() => _OsServerSettingsDialogState();
}

class _OsServerSettingsDialogState extends State<OsServerSettingsDialog> {
  static const screenShareBitrateRows = [
    ('720p', '720p'),
    ('1080p', '1080p'),
    ('source', 'Source'),
  ];
  static const screenShareBitrateFps = [15, 30, 60];

  late final TextEditingController serverNameController;
  late final TextEditingController retentionController;
  late final TextEditingController passwordController;
  late final TextEditingController tlsIdentifierController;
  late final TextEditingController mediaNodeHostController;
  late final TextEditingController mediaNodePortController;
  late final TextEditingController mediaNodeKeyController;
  late final TextEditingController mediaNodeSecretController;
  late final TextEditingController fileNodeHostController;
  late final TextEditingController fileNodePortController;
  late final TextEditingController fileNodeSecretController;
  late final Map<(String, int), TextEditingController>
  screenShareBitrateControllers;
  late final TextEditingController webPathController;
  late final Set<String> adminPermissions;
  late final Set<String> userPermissions;
  late final String? selectedMediaNodeId;
  late final String mediaNodeName;
  late final String mediaNodePath;
  late final String? selectedFileNodeId;
  late final String fileNodePath;
  late final bool tlsActive;
  late final String tlsStatusText;
  late final Color tlsStatusColor;
  late final String webOrigin;

  File? pendingServerAvatar;
  late String selectedPage;
  String? defaultChannelId;
  var clearServerPassword = false;
  late String encryptionMode;
  late String tlsCertificateType;
  var tlsDetectionError = '';
  late int voiceAudioBitrateKbps;
  late String screenRelayMode;
  late String attachmentMode;
  late int retractWindowMinutes;
  late bool webEnabled;
  late bool webCustomPathEnabled;

  @override
  void initState() {
    super.initState();
    final server = widget.server;
    serverNameController = TextEditingController(text: widget.serverName);
    retentionController = TextEditingController(
      text: server.historyRetentionDays.toString(),
    );
    passwordController = TextEditingController();
    tlsIdentifierController = TextEditingController(text: server.tlsIdentifier);

    final activeMediaNode = widget.mediaNodes
        .where((node) => node.enabled && !node.draining)
        .firstOrNull;
    final configuredMediaNode =
        widget.mediaNodes
            .where((node) => !node.isLocal && node.enabled && !node.draining)
            .firstOrNull ??
        widget.mediaNodes.where((node) => !node.isLocal).firstOrNull;
    selectedMediaNodeId = configuredMediaNode?.id;
    screenRelayMode = activeMediaNode == null || activeMediaNode.isLocal
        ? 'local'
        : 'external';
    mediaNodeName = configuredMediaNode?.name ?? '外部屏幕共享节点';
    final configuredMediaNodeUri = Uri.tryParse(
      configuredMediaNode?.liveKitUrl ?? '',
    );
    mediaNodePath = configuredMediaNode == null
        ? ''
        : configuredMediaNodeUri?.path ?? '';
    mediaNodeHostController = TextEditingController(
      text: configuredMediaNodeUri?.host ?? '',
    );
    mediaNodePortController = TextEditingController(
      text: configuredMediaNodeUri?.hasPort == true
          ? configuredMediaNodeUri!.port.toString()
          : '27412',
    );
    mediaNodeKeyController = TextEditingController(
      text: configuredMediaNode?.apiKey ?? '',
    );
    mediaNodeSecretController = TextEditingController();

    final configuredFileNode =
        widget.fileNodes
            .where((node) => node.id == server.attachmentFileNodeId)
            .firstOrNull ??
        widget.fileNodes.where((node) => node.enabled).firstOrNull ??
        widget.fileNodes.firstOrNull;
    selectedFileNodeId = configuredFileNode?.id;
    final configuredFileNodeUri = Uri.tryParse(
      configuredFileNode?.baseUrl ?? '',
    );
    fileNodePath = configuredFileNode == null
        ? '/files'
        : configuredFileNodeUri?.path ?? '';
    fileNodeHostController = TextEditingController(
      text: configuredFileNodeUri?.host ?? '',
    );
    fileNodePortController = TextEditingController(
      text: configuredFileNodeUri?.hasPort == true
          ? configuredFileNodeUri!.port.toString()
          : '27412',
    );
    fileNodeSecretController = TextEditingController();

    selectedPage = widget.allowedPages.contains(widget.initialPage)
        ? widget.initialPage
        : widget.allowedPages.first;
    defaultChannelId =
        server.defaultChannelId ?? widget.channels.firstOrNull?.id;
    encryptionMode = server.encryptionMode;
    tlsCertificateType = server.tlsCertificateType.isEmpty
        ? 'domain'
        : server.tlsCertificateType;
    final tlsHealth = tlsCertificateHealth(server.tlsExpiresAt);
    final tlsExpiry = server.tlsExpiresAt
        ?.toLocal()
        .toString()
        .split('.')
        .first;
    final tlsRenewal = server.tlsRenewalAt
        ?.toLocal()
        .toString()
        .split('.')
        .first;
    tlsActive = server.tlsStatus == 'active';
    tlsStatusText = tlsActive
        ? tlsHealth == TlsCertificateHealth.expired
              ? '证书已过期，有效期至 ${tlsExpiry ?? '未知'}；Caddy 将继续自动重试续签'
              : '证书已启用，有效期至 ${tlsExpiry ?? '未知'}；下次续签时间 ${tlsRenewal ?? '由 Caddy 自动安排'}'
        : server.tlsError.isNotEmpty
        ? '上次启用失败：${server.tlsError}'
        : '保存时将检查网络、申请证书，并在 HTTPS/WSS 自检通过后切换。';
    tlsStatusColor = !tlsActive
        ? OsColors.dim
        : switch (tlsHealth) {
            TlsCertificateHealth.valid => OsColors.green,
            TlsCertificateHealth.expiring => OsColors.warning,
            TlsCertificateHealth.expired => OsColors.danger,
            TlsCertificateHealth.unknown => OsColors.dim,
          };
    voiceAudioBitrateKbps = server.voiceAudioBitrateKbps;
    screenShareBitrateControllers = {
      for (final row in screenShareBitrateRows)
        for (final fps in screenShareBitrateFps)
          (row.$1, fps): TextEditingController(
            text: server.screenShareBitrateLimits
                .bitrateMbps(row.$1, fps)
                .toString(),
          ),
    };
    attachmentMode = server.attachmentExternalEnabled ? 'external' : 'local';
    adminPermissions = <String>{...?widget.permissionSettings?.admin};
    userPermissions = <String>{...?widget.permissionSettings?.user};
    retractWindowMinutes =
        widget.permissionSettings?.messageRetractWindowMinutes ??
        widget.currentMessageRetractWindowMinutes;
    webEnabled = widget.webSettings?.enabled ?? false;
    webCustomPathEnabled = widget.webSettings?.customPathEnabled ?? true;
    webPathController = TextEditingController(
      text: widget.webSettings?.path ?? 'chat',
    );
    final savedWebUri = Uri.tryParse(widget.webSettings?.accessUrl ?? '');
    webOrigin = savedWebUri != null && savedWebUri.host.isNotEmpty
        ? savedWebUri.replace(path: '/', query: null, fragment: null).toString()
        : server.tlsIdentifier.isEmpty
        ? 'https://服务器:27412/'
        : Uri(
            scheme: 'https',
            host: server.tlsIdentifier,
            port: 27412,
            path: '/',
          ).toString();
  }

  void _close(String action) {
    Navigator.pop<ServerSettingsDialogResult>(context, (
      action: action,
      adminPermissions: {...adminPermissions},
      attachmentMode: attachmentMode,
      avatarFile: pendingServerAvatar,
      clearServerPassword: clearServerPassword,
      defaultChannelId: defaultChannelId,
      encryptionMode: encryptionMode,
      fileNodeHost: fileNodeHostController.text,
      fileNodePath: fileNodePath,
      fileNodePort: fileNodePortController.text,
      fileNodeSecret: fileNodeSecretController.text,
      selectedFileNodeId: selectedFileNodeId,
      historyRetentionDays: retentionController.text,
      mediaNodeHost: mediaNodeHostController.text,
      mediaNodeKey: mediaNodeKeyController.text,
      mediaNodeName: mediaNodeName,
      mediaNodePath: mediaNodePath,
      mediaNodePort: mediaNodePortController.text,
      mediaNodeSecret: mediaNodeSecretController.text,
      selectedMediaNodeId: selectedMediaNodeId,
      messageRetractWindowMinutes: retractWindowMinutes,
      password: passwordController.text,
      screenRelayMode: screenRelayMode,
      screenShareBitrates: {
        for (final entry in screenShareBitrateControllers.entries)
          entry.key: entry.value.text,
      },
      serverName: serverNameController.text,
      tlsCertificateType: tlsCertificateType,
      tlsIdentifier: tlsIdentifierController.text,
      userPermissions: {...userPermissions},
      voiceAudioBitrateKbps: voiceAudioBitrateKbps,
      webCustomPathEnabled: webCustomPathEnabled,
      webEnabled: webEnabled,
      webPath: webPathController.text,
    ));
  }

  @override
  void dispose() {
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OsSettingsDialog(
      icon: Icons.dns_rounded,
      eyebrow: '',
      title: '服务器设置',
      subtitle: widget.serverName,
      compactHeader: true,
      maxWidth: 920,
      child: OsSplitSettingsBody(
        navigation: [
          if (widget.allowedPages.contains('overview'))
            OsSettingsNavEntry(
              icon: Icons.dashboard_outlined,
              label: '服务器概览',
              selected: selectedPage == 'overview',
              onTap: () => setState(() => selectedPage = 'overview'),
            ),
          if (widget.allowedPages.contains('general'))
            OsSettingsNavEntry(
              icon: Icons.tune_rounded,
              label: '常规设置',
              selected: selectedPage == 'general',
              onTap: () => setState(() => selectedPage = 'general'),
            ),
          if (widget.allowedPages.contains('transport'))
            OsSettingsNavEntry(
              icon: Icons.security_rounded,
              label: '传输与安全',
              selected: selectedPage == 'transport',
              onTap: () => setState(() => selectedPage = 'transport'),
            ),
          if (widget.allowedPages.contains('audit'))
            OsSettingsNavEntry(
              icon: Icons.history_rounded,
              label: '审计日志',
              selected: selectedPage == 'audit',
              onTap: () => setState(() => selectedPage = 'audit'),
            ),
          if (widget.allowedPages.contains('owner'))
            OsSettingsNavEntry(
              icon: Icons.devices_rounded,
              label: '设备与会话',
              selected: selectedPage == 'owner',
              onTap: () => setState(() => selectedPage = 'owner'),
            ),
          if (widget.allowedPages.contains('permissions'))
            OsSettingsNavEntry(
              icon: Icons.admin_panel_settings_outlined,
              label: '服务器权限管理',
              selected: selectedPage == 'permissions',
              onTap: () => setState(() => selectedPage = 'permissions'),
            ),
          if (widget.allowedPages.contains('web'))
            OsSettingsNavEntry(
              icon: Icons.language_rounded,
              label: '网页端设置',
              selected: selectedPage == 'web',
              onTap: () => setState(() => selectedPage = 'web'),
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
                onPressed: () => _close('save-web'),
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
                            setState(() => webEnabled = value),
                      ),
                      const Divider(height: 20),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('使用自定义访问路径'),
                        subtitle: const Text('开启后根地址保持空白，只能通过下方路径进入'),
                        value: webCustomPathEnabled,
                        onChanged: (value) =>
                            setState(() => webCustomPathEnabled = value),
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
                        onChanged: (_) => setState(() {}),
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
                      ActivationHint(
                        text: widget.webSettings?.assetsAvailable == false
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
              setState(() {
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
                setState(() => retractWindowMinutes = value),
            onSave: () => _close('save-permissions'),
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
                onPressed: () => _close('save-general'),
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
                      for (final channel in widget.channels)
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
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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
                          labelText: widget.server.passwordProtected
                              ? '输入新密码；留空则保持不变'
                              : '设置连接密码；留空则不启用',
                        ),
                      ),
                      if (widget.server.passwordProtected)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('清除现有服务器密码'),
                          value: clearServerPassword,
                          onChanged: (value) => setState(
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
            api: widget.api,
            token: widget.authToken,
            serverId: widget.serverId,
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
                onPressed: () => _close('save-transport'),
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
                        (32, '超低', '最低流量，适合网络较差 · 预计 3.91 KiB/s'),
                        (48, '低', '节省流量，适合普通语音 · 预计 5.86 KiB/s'),
                        (64, '中', '清晰语音，推荐默认 · 预计 7.81 KiB/s'),
                        (80, '高', '更清晰，使用更多带宽 · 预计 9.77 KiB/s'),
                        (96, '超高', '最高质量与带宽占用 · 预计 11.72 KiB/s'),
                      ]) ...[
                        if (option.$1 != 32) const SizedBox(height: 7),
                        MicrophoneActivationOption(
                          icon: Icons.multitrack_audio_rounded,
                          selected: voiceAudioBitrateKbps == option.$1,
                          title: option.$2,
                          subtitle: option.$3,
                          onTap: () =>
                              setState(() => voiceAudioBitrateKbps = option.$1),
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
                        style: TextStyle(color: OsColors.muted, height: 1.45),
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
                                      FilteringTextInputFormatter.digitsOnly,
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
                                screenShareBitrateControllers[(row.$1, fps)]!
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
                            widget.server.tlsStatus == 'active' &&
                                !widget.isOwner
                            ? null
                            : () => setState(() => encryptionMode = 'none'),
                      ),
                      const SizedBox(height: 7),
                      MicrophoneActivationOption(
                        icon: Icons.https_outlined,
                        selected: encryptionMode == 'transport',
                        title: '传输层加密',
                        subtitle: '通过 HTTPS、WSS 等安全传输保护连接',
                        onTap: widget.isOwner
                            ? () => setState(() => encryptionMode = 'transport')
                            : null,
                        expanded: encryptionMode == 'transport'
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Divider(height: 18),
                                  MicrophoneActivationOption(
                                    icon: Icons.language_rounded,
                                    selected: tlsCertificateType == 'domain',
                                    title: '域名证书（推荐）',
                                    subtitle: '域名已解析到服务器，80/TCP 可访问；自动申请和续签',
                                    onTap: widget.isOwner
                                        ? () => setState(() {
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
                                    onTap: widget.isOwner
                                        ? () => setState(() {
                                            tlsCertificateType = 'ip';
                                            tlsDetectionError = '';
                                            unawaited(() async {
                                              try {
                                                final detected = await widget
                                                    .api
                                                    .detectServerPublicIp(
                                                      widget.authToken,
                                                      widget.serverId,
                                                    );
                                                if (detected.isNotEmpty &&
                                                    context.mounted &&
                                                    tlsCertificateType ==
                                                        'ip') {
                                                  setState(() {
                                                    tlsIdentifierController
                                                            .text =
                                                        detected;
                                                    tlsDetectionError = '';
                                                  });
                                                }
                                              } catch (exception) {
                                                if (context.mounted &&
                                                    tlsCertificateType ==
                                                        'ip') {
                                                  setState(
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
                                    enabled: widget.isOwner,
                                    decoration: InputDecoration(
                                      labelText: tlsCertificateType == 'domain'
                                          ? '公网域名'
                                          : '固定公网 IP',
                                      hintText: tlsCertificateType == 'domain'
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
                        onTap: widget.isOwner
                            ? () => setState(() => encryptionMode = 'e2ee')
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
                        onTap: () => setState(() => attachmentMode = 'local'),
                      ),
                      const SizedBox(height: 7),
                      MicrophoneActivationOption(
                        icon: Icons.cloud_outlined,
                        selected: attachmentMode == 'external',
                        title: '其他服务器承载',
                        subtitle: '聊天附件交由外部附件节点传输与存储',
                        onTap: () =>
                            setState(() => attachmentMode = 'external'),
                        expanded: attachmentMode == 'external'
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Divider(height: 18),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: fileNodeHostController,
                                          decoration: const InputDecoration(
                                            labelText: '外部服务器 IP 或域名',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      SizedBox(
                                        width: 128,
                                        child: TextField(
                                          controller: fileNodePortController,
                                          keyboardType: TextInputType.number,
                                          inputFormatters: [
                                            FilteringTextInputFormatter
                                                .digitsOnly,
                                          ],
                                          decoration: const InputDecoration(
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
                                          widget.fileNodes
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
                                  const ActivationHint(
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
                        onTap: () => setState(() => screenRelayMode = 'local'),
                      ),
                      const SizedBox(height: 7),
                      MicrophoneActivationOption(
                        icon: Icons.cloud_outlined,
                        selected: screenRelayMode == 'external',
                        title: '外部 LiveKit 中转',
                        subtitle: '仅屏幕共享使用外部节点，不迁移语音',
                        onTap: () =>
                            setState(() => screenRelayMode = 'external'),
                        expanded: screenRelayMode == 'external'
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Divider(height: 18),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: mediaNodeHostController,
                                          decoration: const InputDecoration(
                                            labelText: 'LiveKit 服务器 IP 或域名',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      SizedBox(
                                        width: 128,
                                        child: TextField(
                                          controller: mediaNodePortController,
                                          keyboardType: TextInputType.number,
                                          inputFormatters: [
                                            FilteringTextInputFormatter
                                                .digitsOnly,
                                          ],
                                          decoration: const InputDecoration(
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
                                          widget.mediaNodes
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
                                  const ActivationHint(
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
            subtitle: widget.ownerStatus?.isOwner == true
                ? '管理已授权设备、会话与设备配对。'
                : '将此设备添加为所有者设备。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.ownerStatus?.isOwner == true
                  ? [
                      OsSettingsTile(
                        icon: Icons.devices_rounded,
                        title: '所有者设备与会话',
                        subtitle: '查看、下线或撤销已授权设备',
                        onTap: () => _close('devices'),
                      ),
                      const SizedBox(height: 10),
                      OsSettingsTile(
                        icon: Icons.add_moderator_outlined,
                        title: '添加所有者设备',
                        subtitle: '生成 5 分钟有效的一次性配对码',
                        onTap: () => _close('pairing-code'),
                      ),
                    ]
                  : [
                      OsSettingsTile(
                        icon: Icons.key_rounded,
                        title: '输入设备配对码',
                        subtitle: '将这台电脑添加为服务器所有者设备',
                        onTap: () => _close('pair'),
                      ),
                    ],
            ),
          ),
          _ => OsSettingsPage(
            icon: Icons.dashboard_outlined,
            title: '服务器概览',
            subtitle: '设置服务器头像与昵称。',
            footer: widget.canEditProfile
                ? Align(
                    alignment: Alignment.centerRight,
                    child: OsPrimaryButton(
                      label: '保存更改',
                      icon: Icons.check_rounded,
                      onPressed: () => _close('save-overview'),
                    ),
                  )
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OsProfilePreview(
                  displayName: serverNameController.text.trim().isEmpty
                      ? widget.serverName
                      : serverNameController.text.trim(),
                  avatarFile: pendingServerAvatar ?? widget.cachedServerAvatar,
                  avatarUri:
                      pendingServerAvatar == null &&
                          widget.cachedServerAvatar == null &&
                          widget.server.avatarVersion > 0
                      ? widget.api.serverAvatarUri(
                          widget.serverId,
                          widget.server.avatarVersion,
                        )
                      : null,
                  onChooseAvatar: widget.canEditProfile && !kIsWeb
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
                            setState(
                              () => pendingServerAvatar = File(selected.path),
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
                  enabled: widget.canEditProfile,
                  decoration: const InputDecoration(
                    hintText: '输入服务器昵称',
                    prefixIcon: Icon(Icons.badge_outlined, size: 20),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: widget.canEditProfile
                      ? (_) => _close('save-overview')
                      : null,
                ),
              ],
            ),
          ),
        },
      ),
    );
  }
}
