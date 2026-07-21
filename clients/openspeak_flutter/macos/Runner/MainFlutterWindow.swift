import Cocoa
import ApplicationServices
import CoreAudio
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var pushToTalkChannel: FlutterMethodChannel?
  private var audioDeviceChannel: FlutterMethodChannel?
  private var audioDeviceListener: AudioObjectPropertyListenerBlock?
  private var audioDevicePropertyAddresses: [AudioObjectPropertyAddress] = []
  private var globalKeyMonitor: Any?
  private var localKeyMonitor: Any?
  private var pushToTalkKeyCode: UInt16?
  private var pushToTalkModifiers = 0
  private var pushToTalkPressed = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "openspeak/global_push_to_talk",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(false) }
      switch call.method {
      case "register":
        guard
          let arguments = call.arguments as? [String: Any],
          let usage = arguments["usb_hid_usage"] as? NSNumber,
          let modifiers = arguments["modifiers"] as? NSNumber,
          let keyCode = self.macKeyCode(forUSBHIDUsage: usage.uint32Value)
        else {
          return result(
            FlutterError(
              code: "unsupported_hotkey",
              message: "这个按键不能注册为系统级快捷键",
              details: nil
            )
          )
        }
        if self.registerPushToTalk(keyCode: keyCode, modifiers: modifiers.intValue) {
          result(true)
        } else {
          self.clearPushToTalk()
          result(
            FlutterError(
              code: "accessibility_permission_required",
              message: "请在 macOS 系统设置中允许 OpenSpeak 使用辅助功能，然后重新保存快捷键",
              details: nil
            )
          )
        }
      case "clear":
        self.clearPushToTalk()
        result(nil)
      case "openAccessibilitySettings":
        guard let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
          return result(false)
        }
        result(NSWorkspace.shared.open(url))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    pushToTalkChannel = channel

    audioDeviceChannel = FlutterMethodChannel(
      name: "openspeak/audio_devices",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    registerAudioDeviceListener()

    super.awakeFromNib()
  }

  deinit {
    if let listener = audioDeviceListener {
      for var address in audioDevicePropertyAddresses {
        AudioObjectRemovePropertyListenerBlock(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          DispatchQueue.main,
          listener
        )
      }
    }
  }

  private func registerAudioDeviceListener() {
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.audioDeviceChannel?.invokeMethod("changed", arguments: nil)
    }
    let selectors: [AudioObjectPropertySelector] = [
      kAudioHardwarePropertyDevices,
      kAudioHardwarePropertyDefaultInputDevice,
      kAudioHardwarePropertyDefaultOutputDevice,
    ]
    for selector in selectors {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMaster
      )
      if AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        DispatchQueue.main,
        listener
      ) == noErr {
        audioDevicePropertyAddresses.append(address)
      }
    }
    audioDeviceListener = listener
  }

  private func registerPushToTalk(keyCode: UInt16, modifiers: Int) -> Bool {
    clearPushToTalk()
    pushToTalkKeyCode = keyCode
    pushToTalkModifiers = modifiers

    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
      return false
    }

    globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.keyDown, .keyUp]
    ) { [weak self] event in
      self?.handlePushToTalk(event)
    }
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .keyUp]
    ) { [weak self] event in
      self?.handlePushToTalk(event)
      return event
    }
    return true
  }

  private func clearPushToTalk() {
    if let monitor = globalKeyMonitor {
      NSEvent.removeMonitor(monitor)
    }
    if let monitor = localKeyMonitor {
      NSEvent.removeMonitor(monitor)
    }
    globalKeyMonitor = nil
    localKeyMonitor = nil
    pushToTalkKeyCode = nil
    if pushToTalkPressed {
      pushToTalkPressed = false
      pushToTalkChannel?.invokeMethod("pressed", arguments: false)
    }
  }

  private func handlePushToTalk(_ event: NSEvent) {
    guard let keyCode = pushToTalkKeyCode, event.keyCode == keyCode else {
      return
    }
    if event.type == .keyDown {
      guard modifiersMatch(event.modifierFlags), !pushToTalkPressed else {
        return
      }
      pushToTalkPressed = true
      pushToTalkChannel?.invokeMethod("pressed", arguments: true)
    } else if event.type == .keyUp, pushToTalkPressed {
      pushToTalkPressed = false
      pushToTalkChannel?.invokeMethod("pressed", arguments: false)
    }
  }

  private func modifiersMatch(_ flags: NSEvent.ModifierFlags) -> Bool {
    if pushToTalkModifiers & 1 != 0, !flags.contains(.control) { return false }
    if pushToTalkModifiers & 2 != 0, !flags.contains(.option) { return false }
    if pushToTalkModifiers & 4 != 0, !flags.contains(.shift) { return false }
    if pushToTalkModifiers & 8 != 0, !flags.contains(.command) { return false }
    return true
  }

  private func macKeyCode(forUSBHIDUsage usage: UInt32) -> UInt16? {
    let pageUsage = usage & 0xffff
    let codes: [UInt32: UInt16] = [
      0x04: 0, 0x05: 11, 0x06: 8, 0x07: 2, 0x08: 14, 0x09: 3,
      0x0a: 5, 0x0b: 4, 0x0c: 34, 0x0d: 38, 0x0e: 40, 0x0f: 37,
      0x10: 46, 0x11: 45, 0x12: 31, 0x13: 35, 0x14: 12, 0x15: 15,
      0x16: 1, 0x17: 17, 0x18: 32, 0x19: 9, 0x1a: 13, 0x1b: 7,
      0x1c: 16, 0x1d: 6,
      0x1e: 18, 0x1f: 19, 0x20: 20, 0x21: 21, 0x22: 23,
      0x23: 22, 0x24: 26, 0x25: 28, 0x26: 25, 0x27: 29,
      0x28: 36, 0x29: 53, 0x2a: 51, 0x2b: 48, 0x2c: 49,
      0x2d: 27, 0x2e: 24, 0x2f: 33, 0x30: 30, 0x31: 42,
      0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43, 0x37: 47, 0x38: 44,
      0x39: 57,
      0x3a: 122, 0x3b: 120, 0x3c: 99, 0x3d: 118, 0x3e: 96,
      0x3f: 97, 0x40: 98, 0x41: 100, 0x42: 101, 0x43: 109,
      0x44: 103, 0x45: 111,
      0x49: 114, 0x4a: 115, 0x4b: 116, 0x4c: 117, 0x4d: 119,
      0x4e: 121, 0x4f: 124, 0x50: 123, 0x51: 125, 0x52: 126,
    ]
    return codes[pageUsage]
  }
}
