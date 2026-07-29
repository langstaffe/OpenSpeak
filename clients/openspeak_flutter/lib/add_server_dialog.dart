import 'package:flutter/material.dart';

import 'os_settings_shell.dart';
import 'os_theme.dart';
import 'saved_server_connection.dart';
import 'smooth_scroll.dart';

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
                  child: OsDialogGlow(size: 230, color: Color(0x335865F2)),
                ),
                const Positioned(
                  right: -88,
                  bottom: -130,
                  child: OsDialogGlow(size: 220, color: Color(0x2223A559)),
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
