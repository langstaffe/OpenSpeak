import 'dart:io';

import 'package:flutter/material.dart';

import 'os_theme.dart';

String initials(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return 'OS';
  final chars = trimmed.runes.take(2).toList();
  return String.fromCharCodes(chars).toUpperCase();
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
