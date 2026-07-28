import 'package:flutter/material.dart';

class OsColors {
  static const app = Color(0xFF202225);
  static const rail = Color(0xFF1E1F22);
  static const sidebar = Color(0xFF2B2D31);
  static const sidebarBottom = Color(0xFF292B2F);
  static const content = Color(0xFF313338);
  static const rowHover = Color(0xFF36393F);
  static const rowSelected = Color(0xFF3A3D42);
  static const divider = Color(0xFF24262B);
  static const text = Color(0xFFF2F3F5);
  static const muted = Color(0xFFB5BAC1);
  static const dim = Color(0xFF949BA4);
  static const icon = Color(0xFF72767D);
  static const green = Color(0xFF23A559);
  static const warning = Color(0xFFF0A33A);
  static const blurple = Color(0xFF5865F2);
  static const danger = Color(0xFFED4245);
  static const disconnect = Color(0xFFC83F4A);
  static const panel = Color(0xFF25272C);
  static const panelRaised = Color(0xFF2B2E34);
  static const panelBorder = Color(0xFF3A3E46);
  static const field = Color(0xFF1F2125);
  static const blurpleSoft = Color(0xFF303653);
}

ButtonStyle osClickableButtonStyle() {
  return ButtonStyle(
    mouseCursor: WidgetStateProperty.resolveWith((states) {
      return states.contains(WidgetState.disabled)
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click;
    }),
  );
}
