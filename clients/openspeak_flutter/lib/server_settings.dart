import 'dart:async';

import 'package:flutter/material.dart';

import 'openspeak_api.dart';
import 'os_avatar.dart';
import 'os_settings_shell.dart';
import 'os_theme.dart';
import 'voice_session_controller.dart';

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
