import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' as native_strings;

typedef _ShellExecuteWNative =
    ffi.IntPtr Function(
      ffi.IntPtr hwnd,
      ffi.Pointer<native_strings.Utf16> lpOperation,
      ffi.Pointer<native_strings.Utf16> lpFile,
      ffi.Pointer<native_strings.Utf16> lpParameters,
      ffi.Pointer<native_strings.Utf16> lpDirectory,
      ffi.Uint32 nShowCmd,
    );

typedef _ShellExecuteWDart =
    int Function(
      int hwnd,
      ffi.Pointer<native_strings.Utf16> lpOperation,
      ffi.Pointer<native_strings.Utf16> lpFile,
      ffi.Pointer<native_strings.Utf16> lpParameters,
      ffi.Pointer<native_strings.Utf16> lpDirectory,
      int nShowCmd,
    );

void openWithWindowsShell(String target) {
  final shell32 = ffi.DynamicLibrary.open('shell32.dll');
  final shellExecute = shell32
      .lookupFunction<_ShellExecuteWNative, _ShellExecuteWDart>(
        'ShellExecuteW',
      );
  final operation = 'open'.toNativeUtf16();
  final file = target.toNativeUtf16();
  final nullString = ffi.nullptr.cast<native_strings.Utf16>();
  try {
    const swShownormal = 1;
    final result = shellExecute(
      0,
      operation,
      file,
      nullString,
      nullString,
      swShownormal,
    );
    if (result <= 32) {
      throw StateError('ShellExecute failed with code $result');
    }
  } finally {
    native_strings.malloc.free(operation);
    native_strings.malloc.free(file);
  }
}
