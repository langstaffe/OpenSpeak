#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <cstdint>
#include <string>

#include "win32_window.h"

class MicrophoneLevelMonitor;
class AudioDeviceNotificationRegistration;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  static LRESULT CALLBACK KeyboardHookProc(int code,
                                           WPARAM wparam,
                                           LPARAM lparam);
  static FlutterWindow* hook_owner_;

  void RegisterPushToTalk(uint32_t usb_hid_usage, int modifiers);
  void ClearPushToTalk();
  void SendPushToTalkState(bool pressed);
  bool PushToTalkModifiersMatch() const;
  static DWORD VirtualKeyForUsbHidUsage(uint32_t usage);
  bool StartMicrophoneLevelMonitor(const std::string& monitor_id,
                                   const std::string& device_id,
                                   const std::string& track_id,
                                   bool use_webrtc);
  void StopMicrophoneLevelMonitor(const std::string* monitor_id = nullptr);
  void SendMicrophoneLevel(double rms);
  void SendAudioDevicesChanged();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      push_to_talk_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      microphone_level_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      microphone_level_event_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      audio_device_channel_;
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>>
      microphone_level_event_sink_;
  std::unique_ptr<MicrophoneLevelMonitor> microphone_level_monitor_;
  std::string microphone_level_monitor_id_;
  uint32_t microphone_level_generation_ = 0;
  std::unique_ptr<AudioDeviceNotificationRegistration>
      audio_device_notifications_;
  HHOOK keyboard_hook_ = nullptr;
  DWORD push_to_talk_virtual_key_ = 0;
  int push_to_talk_modifiers_ = 0;
  bool push_to_talk_pressed_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
