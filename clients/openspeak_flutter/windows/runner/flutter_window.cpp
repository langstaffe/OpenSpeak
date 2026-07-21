#include "flutter_window.h"

#include <algorithm>
#include <audioclient.h>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <mutex>
#include <optional>
#include <thread>
#include <wrl/client.h>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <flutter_webrtc.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>
#include <rtc_audio_processing.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr int kControlModifier = 1;
constexpr int kAltModifier = 2;
constexpr int kShiftModifier = 4;
constexpr int kMetaModifier = 8;
constexpr UINT kMicrophoneLevelMessage = WM_APP + 1;
constexpr UINT kAudioDevicesChangedMessage = WM_APP + 2;
constexpr ULONGLONG kMicrophoneLevelIntervalMs = 20;

int64_t EncodableInteger(const flutter::EncodableValue& value) {
  if (const auto* integer = std::get_if<int32_t>(&value)) {
    return *integer;
  }
  if (const auto* integer = std::get_if<int64_t>(&value)) {
    return *integer;
  }
  return -1;
}

std::string EncodableString(const flutter::EncodableMap& arguments,
                            const char* key) {
  const auto it = arguments.find(flutter::EncodableValue(key));
  if (it == arguments.end()) return {};
  const auto* value = std::get_if<std::string>(&it->second);
  return value == nullptr ? std::string() : *value;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int size = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (size <= 0) return {};
  std::wstring result(size, L'\0');
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), result.data(),
                            size) != size) {
    return {};
  }
  return result;
}

}  // namespace

class AudioDeviceNotificationClient final : public IMMNotificationClient {
 public:
  explicit AudioDeviceNotificationClient(HWND window) : window_(window) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,
                                            void** object) override {
    if (object == nullptr) return E_POINTER;
    *object = nullptr;
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IMMNotificationClient)) {
      *object = static_cast<IMMNotificationClient*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return ref_count_.fetch_add(1, std::memory_order_relaxed) + 1;
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG count =
        ref_count_.fetch_sub(1, std::memory_order_acq_rel) - 1;
    if (count == 0) delete this;
    return count;
  }

  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(
      EDataFlow flow, ERole role, LPCWSTR device_id) override {
    Notify();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR device_id) override {
    Notify();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR device_id) override {
    Notify();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR device_id,
                                                  DWORD state) override {
    Notify();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(
      LPCWSTR device_id, const PROPERTYKEY key) override {
    return S_OK;
  }

  bool TakePending() {
    return notification_pending_.exchange(false, std::memory_order_acq_rel);
  }

 private:
  void Notify() {
    if (notification_pending_.exchange(true, std::memory_order_acq_rel)) return;
    if (!::PostMessage(window_, kAudioDevicesChangedMessage, 0, 0)) {
      notification_pending_.store(false, std::memory_order_release);
    }
  }

  std::atomic<ULONG> ref_count_{1};
  std::atomic<bool> notification_pending_{false};
  HWND window_;
};

class AudioDeviceNotificationRegistration {
 public:
  explicit AudioDeviceNotificationRegistration(HWND window) {
    if (FAILED(::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                  CLSCTX_ALL,
                                  IID_PPV_ARGS(&enumerator_)))) {
      return;
    }
    client_ = new AudioDeviceNotificationClient(window);
    if (FAILED(enumerator_->RegisterEndpointNotificationCallback(client_))) {
      client_->Release();
      client_ = nullptr;
      enumerator_.Reset();
      return;
    }
    registered_ = true;
  }

  ~AudioDeviceNotificationRegistration() {
    if (registered_) {
      enumerator_->UnregisterEndpointNotificationCallback(client_);
    }
    if (client_ != nullptr) client_->Release();
  }

  bool TakePending() { return client_ != nullptr && client_->TakePending(); }

 private:
  Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator_;
  AudioDeviceNotificationClient* client_ = nullptr;
  bool registered_ = false;
};

class MicrophoneLevelMonitor {
 public:
  MicrophoneLevelMonitor(HWND window, uint32_t generation)
      : window_(window), generation_(generation) {}
  virtual ~MicrophoneLevelMonitor() = default;

  double TakeLatestRms() {
    message_pending_.store(false, std::memory_order_release);
    return latest_rms_.load(std::memory_order_acquire);
  }

 protected:
  void PublishRms(double rms) {
    latest_rms_.store(std::clamp(rms, 0.0, 1.0),
                      std::memory_order_relaxed);

    const ULONGLONG now = ::GetTickCount64();
    const ULONGLONG last = last_post_ms_.load(std::memory_order_relaxed);
    if (now - last < kMicrophoneLevelIntervalMs ||
        message_pending_.exchange(true, std::memory_order_acq_rel)) {
      return;
    }
    last_post_ms_.store(now, std::memory_order_relaxed);
    if (!::PostMessage(window_, kMicrophoneLevelMessage, generation_, 0)) {
      message_pending_.store(false, std::memory_order_release);
    }
  }

 private:
  HWND window_;
  uint32_t generation_;
  std::atomic<double> latest_rms_{0};
  std::atomic<ULONGLONG> last_post_ms_{0};
  std::atomic<bool> message_pending_{false};
};

class WebRtcMicrophoneLevelMonitor;

class WebRtcCaptureLevelTap final
    : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  void Bind(WebRtcMicrophoneLevelMonitor* monitor) {
    std::lock_guard<std::mutex> lock(mutex_);
    monitor_ = monitor;
  }

  void Unbind(WebRtcMicrophoneLevelMonitor* monitor) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (monitor_ == monitor) monitor_ = nullptr;
  }

  void Initialize(int sample_rate_hz, int num_channels) override {}
  void Process(int num_bands, int num_frames, int buffer_size,
               float* buffer) override;
  void Reset(int new_rate) override {}
  void Release() override {}

 private:
  std::mutex mutex_;
  WebRtcMicrophoneLevelMonitor* monitor_ = nullptr;
};

WebRtcCaptureLevelTap& SharedWebRtcCaptureLevelTap() {
  // The plugin keeps this callback for the lifetime of its audio processor.
  static auto* tap = new WebRtcCaptureLevelTap();
  return *tap;
}

class WebRtcMicrophoneLevelMonitor : public MicrophoneLevelMonitor {
 public:
  WebRtcMicrophoneLevelMonitor(HWND window, uint32_t generation,
                               WebRtcCaptureLevelTap& tap)
      : MicrophoneLevelMonitor(window, generation), tap_(tap) {
    tap_.Bind(this);
  }

  ~WebRtcMicrophoneLevelMonitor() override { tap_.Unbind(this); }

  void OnAudioBuffer(const float* samples, int sample_count) {
    if (samples == nullptr || sample_count <= 0) return;
    double sum_squares = 0;
    for (int index = 0; index < sample_count; ++index) {
      const double sample = std::isfinite(samples[index])
                                ? samples[index] / 32768.0
                                : 0.0;
      sum_squares += sample * sample;
    }
    PublishRms(std::sqrt(sum_squares / sample_count));
  }

 private:
  WebRtcCaptureLevelTap& tap_;
};

void WebRtcCaptureLevelTap::Process(int num_bands, int num_frames,
                                    int buffer_size, float* buffer) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (monitor_ != nullptr) monitor_->OnAudioBuffer(buffer, buffer_size);
}

class WasapiMicrophoneLevelMonitor : public MicrophoneLevelMonitor {
 public:
  WasapiMicrophoneLevelMonitor(HWND window, uint32_t generation,
                              std::string device_id)
      : MicrophoneLevelMonitor(window, generation),
        device_id_(std::move(device_id)) {}

  ~WasapiMicrophoneLevelMonitor() { Stop(); }

  bool Start() {
    stop_event_ = ::CreateEvent(nullptr, TRUE, FALSE, nullptr);
    audio_event_ = ::CreateEvent(nullptr, FALSE, FALSE, nullptr);
    ready_event_ = ::CreateEvent(nullptr, TRUE, FALSE, nullptr);
    if (stop_event_ == nullptr || audio_event_ == nullptr ||
        ready_event_ == nullptr) {
      Stop();
      return false;
    }
    thread_ = std::thread([this]() { Run(); });
    if (::WaitForSingleObject(ready_event_, 1500) != WAIT_OBJECT_0 ||
        !started_.load(std::memory_order_acquire)) {
      Stop();
      return false;
    }
    return true;
  }

  void Stop() {
    if (stop_event_ != nullptr) ::SetEvent(stop_event_);
    if (thread_.joinable()) thread_.join();
    if (ready_event_ != nullptr) ::CloseHandle(ready_event_);
    if (audio_event_ != nullptr) ::CloseHandle(audio_event_);
    if (stop_event_ != nullptr) ::CloseHandle(stop_event_);
    ready_event_ = nullptr;
    audio_event_ = nullptr;
    stop_event_ = nullptr;
  }

 private:
  void SignalReady(bool started) {
    started_.store(started, std::memory_order_release);
    ::SetEvent(ready_event_);
  }

  void Run() {
    const HRESULT com_result = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(com_result)) {
      SignalReady(false);
      return;
    }

    Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator;
    Microsoft::WRL::ComPtr<IMMDevice> device;
    Microsoft::WRL::ComPtr<IAudioClient> audio_client;
    Microsoft::WRL::ComPtr<IAudioCaptureClient> capture_client;
    WAVEFORMATEX* format = nullptr;
    bool ready_signaled = false;
    bool client_started = false;

    do {
      if (FAILED(::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                    CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) {
        break;
      }
      const auto use_default_device = [&]() {
        device.Reset();
        if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(
                eCapture, eCommunications, &device))) {
          return true;
        }
        device.Reset();
        return SUCCEEDED(enumerator->GetDefaultAudioEndpoint(
            eCapture, eConsole, &device));
      };
      if (device_id_.empty() || device_id_ == "default" ||
          device_id_ == "communications") {
        if (!use_default_device()) break;
      } else {
        const std::wstring wide_device_id = Utf8ToWide(device_id_);
        if (wide_device_id.empty() ||
            FAILED(enumerator->GetDevice(wide_device_id.c_str(), &device))) {
          if (!use_default_device()) break;
        }
      }
      if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                  &audio_client))) {
        break;
      }
      if (FAILED(audio_client->GetMixFormat(&format))) break;
      if (FAILED(audio_client->Initialize(
              AUDCLNT_SHAREMODE_SHARED,
              AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                  AUDCLNT_STREAMFLAGS_NOPERSIST,
              0, 0, format, nullptr))) {
        break;
      }
      if (FAILED(audio_client->SetEventHandle(audio_event_))) break;
      if (FAILED(audio_client->GetService(IID_PPV_ARGS(&capture_client)))) {
        break;
      }
      if (FAILED(audio_client->Start())) break;
      client_started = true;
      SignalReady(true);
      ready_signaled = true;

      HANDLE events[] = {stop_event_, audio_event_};
      bool capture_running = true;
      while (capture_running) {
        const DWORD wait_result = ::WaitForMultipleObjects(2, events, FALSE,
                                                           INFINITE);
        if (wait_result == WAIT_OBJECT_0) break;
        if (wait_result != WAIT_OBJECT_0 + 1) break;

        UINT32 packet_frames = 0;
        while (SUCCEEDED(capture_client->GetNextPacketSize(&packet_frames)) &&
               packet_frames > 0) {
          BYTE* data = nullptr;
          DWORD flags = 0;
          UINT64 device_position = 0;
          UINT64 performance_position = 0;
          const HRESULT buffer_result = capture_client->GetBuffer(
              &data, &packet_frames, &flags, &device_position,
              &performance_position);
          if (FAILED(buffer_result)) {
            capture_running = false;
            break;
          }
          const double rms = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0
                                 ? 0.0
                                 : CalculateRms(data, packet_frames, *format);
          capture_client->ReleaseBuffer(packet_frames);
          PublishRms(rms);
        }
      }
    } while (false);

    if (!ready_signaled) SignalReady(false);
    if (client_started) audio_client->Stop();
    if (format != nullptr) ::CoTaskMemFree(format);
    ::CoUninitialize();
  }

  double CalculateRms(const BYTE* data, UINT32 frames,
                      const WAVEFORMATEX& format) const {
    if (data == nullptr || frames == 0 || format.nChannels == 0) return 0;
    const size_t sample_count =
        static_cast<size_t>(frames) * format.nChannels;
    bool is_float = format.wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    bool is_pcm = format.wFormatTag == WAVE_FORMAT_PCM;
    if (format.wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
        format.cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
      const auto& extensible =
          reinterpret_cast<const WAVEFORMATEXTENSIBLE&>(format);
      is_float = extensible.SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
      is_pcm = extensible.SubFormat == KSDATAFORMAT_SUBTYPE_PCM;
    }

    double sum_squares = 0;
    if (is_float && format.wBitsPerSample == 32) {
      const auto* samples = reinterpret_cast<const float*>(data);
      for (size_t index = 0; index < sample_count; ++index) {
        const double sample = std::isfinite(samples[index])
                                  ? std::clamp<double>(samples[index], -1, 1)
                                  : 0;
        sum_squares += sample * sample;
      }
    } else if (is_pcm && format.wBitsPerSample == 16) {
      const auto* samples = reinterpret_cast<const int16_t*>(data);
      for (size_t index = 0; index < sample_count; ++index) {
        const double sample = static_cast<double>(samples[index]) / 32768.0;
        sum_squares += sample * sample;
      }
    } else if (is_pcm && format.wBitsPerSample == 24) {
      for (size_t index = 0; index < sample_count; ++index) {
        const BYTE* sample_data = data + index * 3;
        int32_t value = static_cast<int32_t>(sample_data[0]) |
                        (static_cast<int32_t>(sample_data[1]) << 8) |
                        (static_cast<int32_t>(sample_data[2]) << 16);
        if ((value & 0x00800000) != 0) value |= 0xFF000000;
        const double sample = static_cast<double>(value) / 8388608.0;
        sum_squares += sample * sample;
      }
    } else if (is_pcm && format.wBitsPerSample == 32) {
      const auto* samples = reinterpret_cast<const int32_t*>(data);
      for (size_t index = 0; index < sample_count; ++index) {
        const double sample = static_cast<double>(samples[index]) /
                              2147483648.0;
        sum_squares += sample * sample;
      }
    } else if (is_pcm && format.wBitsPerSample == 8) {
      for (size_t index = 0; index < sample_count; ++index) {
        const double sample =
            (static_cast<double>(data[index]) - 128.0) / 128.0;
        sum_squares += sample * sample;
      }
    } else {
      return 0;
    }
    return std::sqrt(sum_squares / sample_count);
  }

  std::string device_id_;
  HANDLE stop_event_ = nullptr;
  HANDLE audio_event_ = nullptr;
  HANDLE ready_event_ = nullptr;
  std::thread thread_;
  std::atomic<bool> started_{false};
};

FlutterWindow* FlutterWindow::hook_owner_ = nullptr;

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  push_to_talk_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "openspeak/global_push_to_talk",
          &flutter::StandardMethodCodec::GetInstance());
  push_to_talk_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "register") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!arguments) {
            result->Error("invalid_hotkey", "Missing hotkey arguments");
            return;
          }
          const auto usage_it = arguments->find(
              flutter::EncodableValue("usb_hid_usage"));
          const auto modifiers_it =
              arguments->find(flutter::EncodableValue("modifiers"));
          if (usage_it == arguments->end() ||
              modifiers_it == arguments->end()) {
            result->Error("invalid_hotkey", "Missing hotkey key or modifiers");
            return;
          }
          const auto usage = EncodableInteger(usage_it->second);
          const auto modifiers = EncodableInteger(modifiers_it->second);
          const auto virtual_key =
              VirtualKeyForUsbHidUsage(static_cast<uint32_t>(usage));
          if (usage <= 0 || modifiers < 0 || virtual_key == 0) {
            result->Error("unsupported_hotkey",
                          "This key cannot be used as a global hotkey");
            return;
          }
          RegisterPushToTalk(static_cast<uint32_t>(usage),
                             static_cast<int>(modifiers));
          if (!keyboard_hook_) {
            result->Error("hotkey_hook_failed",
                          "Could not install the global keyboard hook");
            return;
          }
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (call.method_name() == "clear") {
          ClearPushToTalk();
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  microphone_level_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "openspeak/microphone_level",
          &flutter::StandardMethodCodec::GetInstance());
  microphone_level_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_arguments", "Missing microphone arguments");
          return;
        }
        const std::string monitor_id =
            EncodableString(*arguments, "monitor_id");
        if (call.method_name() == "start") {
          const std::string device_id =
              EncodableString(*arguments, "device_id");
          const std::string track_id =
              EncodableString(*arguments, "track_id");
          const std::string source = EncodableString(*arguments, "source");
          result->Success(flutter::EncodableValue(
              !monitor_id.empty() &&
              StartMicrophoneLevelMonitor(monitor_id, device_id, track_id,
                                          source == "webrtc")));
          return;
        }
        if (call.method_name() == "stop") {
          StopMicrophoneLevelMonitor(&monitor_id);
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  microphone_level_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "openspeak/microphone_level/events",
          &flutter::StandardMethodCodec::GetInstance());
  auto microphone_level_stream_handler = std::make_unique<
      flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [this](const flutter::EncodableValue*,
             std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                 events) {
        microphone_level_event_sink_ = std::move(events);
        return std::unique_ptr<
            flutter::StreamHandlerError<flutter::EncodableValue>>();
      },
      [this](const flutter::EncodableValue*) {
        microphone_level_event_sink_.reset();
        return std::unique_ptr<
            flutter::StreamHandlerError<flutter::EncodableValue>>();
      });
  microphone_level_event_channel_->SetStreamHandler(
      std::move(microphone_level_stream_handler));
  audio_device_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "openspeak/audio_devices",
          &flutter::StandardMethodCodec::GetInstance());
  audio_device_notifications_ =
      std::make_unique<AudioDeviceNotificationRegistration>(GetHandle());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  ClearPushToTalk();
  StopMicrophoneLevelMonitor();
  audio_device_notifications_.reset();
  audio_device_channel_.reset();
  microphone_level_event_sink_.reset();
  microphone_level_event_channel_.reset();
  microphone_level_channel_.reset();
  push_to_talk_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

bool FlutterWindow::StartMicrophoneLevelMonitor(
    const std::string& monitor_id, const std::string& device_id,
    const std::string& track_id, bool use_webrtc) {
  StopMicrophoneLevelMonitor();
  if (use_webrtc) {
    auto* webrtc = FlutterWebRTCPluginSharedInstance();
    if (webrtc == nullptr || track_id.empty()) return false;
    auto audio_processing = webrtc->audio_processing();
    if (!audio_processing) return false;
    auto& tap = SharedWebRtcCaptureLevelTap();
    auto monitor = std::make_unique<WebRtcMicrophoneLevelMonitor>(
        GetHandle(), microphone_level_generation_, tap);
    audio_processing->SetCapturePostProcessing(&tap);
    microphone_level_monitor_id_ = monitor_id;
    microphone_level_monitor_ = std::move(monitor);
    return true;
  }
  auto monitor = std::make_unique<WasapiMicrophoneLevelMonitor>(
      GetHandle(), microphone_level_generation_, device_id);
  if (!monitor->Start()) return false;
  microphone_level_monitor_id_ = monitor_id;
  microphone_level_monitor_ = std::move(monitor);
  return true;
}

void FlutterWindow::StopMicrophoneLevelMonitor(
    const std::string* monitor_id) {
  if (monitor_id != nullptr && *monitor_id != microphone_level_monitor_id_) {
    return;
  }
  ++microphone_level_generation_;
  microphone_level_monitor_.reset();
  microphone_level_monitor_id_.clear();
}

void FlutterWindow::SendMicrophoneLevel(double rms) {
  if (!microphone_level_event_sink_ || microphone_level_monitor_id_.empty()) {
    return;
  }
  flutter::EncodableMap event;
  event[flutter::EncodableValue("monitor_id")] =
      flutter::EncodableValue(microphone_level_monitor_id_);
  event[flutter::EncodableValue("rms")] = flutter::EncodableValue(rms);
  microphone_level_event_sink_->Success(flutter::EncodableValue(event));
}

void FlutterWindow::SendAudioDevicesChanged() {
  if (!audio_device_channel_) return;
  audio_device_channel_->InvokeMethod(
      "changed", std::make_unique<flutter::EncodableValue>());
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kMicrophoneLevelMessage) {
    if (wparam == microphone_level_generation_ && microphone_level_monitor_) {
      SendMicrophoneLevel(microphone_level_monitor_->TakeLatestRms());
    }
    return 0;
  }
  if (message == kAudioDevicesChangedMessage) {
    if (audio_device_notifications_ &&
        audio_device_notifications_->TakePending()) {
      SendAudioDevicesChanged();
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::RegisterPushToTalk(uint32_t usb_hid_usage,
                                       int modifiers) {
  ClearPushToTalk();
  push_to_talk_virtual_key_ = VirtualKeyForUsbHidUsage(usb_hid_usage);
  push_to_talk_modifiers_ = modifiers;
  hook_owner_ = this;
  keyboard_hook_ = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardHookProc,
                                     GetModuleHandleW(nullptr), 0);
  if (!keyboard_hook_) {
    hook_owner_ = nullptr;
    push_to_talk_virtual_key_ = 0;
  }
}

void FlutterWindow::ClearPushToTalk() {
  if (keyboard_hook_) {
    UnhookWindowsHookEx(keyboard_hook_);
  }
  keyboard_hook_ = nullptr;
  if (hook_owner_ == this) {
    hook_owner_ = nullptr;
  }
  push_to_talk_virtual_key_ = 0;
  push_to_talk_modifiers_ = 0;
  if (push_to_talk_pressed_) {
    push_to_talk_pressed_ = false;
    SendPushToTalkState(false);
  }
}

LRESULT CALLBACK FlutterWindow::KeyboardHookProc(int code,
                                                  WPARAM wparam,
                                                  LPARAM lparam) {
  auto* owner = hook_owner_;
  if (code == HC_ACTION && owner != nullptr) {
    const auto* event = reinterpret_cast<KBDLLHOOKSTRUCT*>(lparam);
    if (event->vkCode == owner->push_to_talk_virtual_key_) {
      const bool key_down = wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN;
      const bool key_up = wparam == WM_KEYUP || wparam == WM_SYSKEYUP;
      if (key_down && !owner->push_to_talk_pressed_ &&
          owner->PushToTalkModifiersMatch()) {
        owner->push_to_talk_pressed_ = true;
        owner->SendPushToTalkState(true);
      } else if (key_up && owner->push_to_talk_pressed_) {
        owner->push_to_talk_pressed_ = false;
        owner->SendPushToTalkState(false);
      }
    }
  }
  return CallNextHookEx(owner ? owner->keyboard_hook_ : nullptr, code, wparam,
                        lparam);
}

bool FlutterWindow::PushToTalkModifiersMatch() const {
  if ((push_to_talk_modifiers_ & kControlModifier) != 0 &&
      (GetAsyncKeyState(VK_CONTROL) & 0x8000) == 0) {
    return false;
  }
  if ((push_to_talk_modifiers_ & kAltModifier) != 0 &&
      (GetAsyncKeyState(VK_MENU) & 0x8000) == 0) {
    return false;
  }
  if ((push_to_talk_modifiers_ & kShiftModifier) != 0 &&
      (GetAsyncKeyState(VK_SHIFT) & 0x8000) == 0) {
    return false;
  }
  if ((push_to_talk_modifiers_ & kMetaModifier) != 0 &&
      (GetAsyncKeyState(VK_LWIN) & 0x8000) == 0 &&
      (GetAsyncKeyState(VK_RWIN) & 0x8000) == 0) {
    return false;
  }
  return true;
}

void FlutterWindow::SendPushToTalkState(bool pressed) {
  if (!push_to_talk_channel_) {
    return;
  }
  push_to_talk_channel_->InvokeMethod(
      "pressed", std::make_unique<flutter::EncodableValue>(pressed));
}

DWORD FlutterWindow::VirtualKeyForUsbHidUsage(uint32_t usage) {
  const uint32_t key = usage & 0xffff;
  if (key >= 0x04 && key <= 0x1d) {
    return 'A' + (key - 0x04);
  }
  if (key >= 0x1e && key <= 0x26) {
    return '1' + (key - 0x1e);
  }
  if (key == 0x27) return '0';
  if (key >= 0x3a && key <= 0x45) {
    return VK_F1 + (key - 0x3a);
  }
  switch (key) {
    case 0x28:
      return VK_RETURN;
    case 0x29:
      return VK_ESCAPE;
    case 0x2a:
      return VK_BACK;
    case 0x2b:
      return VK_TAB;
    case 0x2c:
      return VK_SPACE;
    case 0x2d:
      return VK_OEM_MINUS;
    case 0x2e:
      return VK_OEM_PLUS;
    case 0x2f:
      return VK_OEM_4;
    case 0x30:
      return VK_OEM_6;
    case 0x31:
      return VK_OEM_5;
    case 0x33:
      return VK_OEM_1;
    case 0x34:
      return VK_OEM_7;
    case 0x35:
      return VK_OEM_3;
    case 0x36:
      return VK_OEM_COMMA;
    case 0x37:
      return VK_OEM_PERIOD;
    case 0x38:
      return VK_OEM_2;
    case 0x39:
      return VK_CAPITAL;
    case 0x49:
      return VK_INSERT;
    case 0x4a:
      return VK_HOME;
    case 0x4b:
      return VK_PRIOR;
    case 0x4c:
      return VK_DELETE;
    case 0x4d:
      return VK_END;
    case 0x4e:
      return VK_NEXT;
    case 0x4f:
      return VK_RIGHT;
    case 0x50:
      return VK_LEFT;
    case 0x51:
      return VK_DOWN;
    case 0x52:
      return VK_UP;
    default:
      return 0;
  }
}
