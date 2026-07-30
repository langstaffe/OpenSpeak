#include "rnnoise_processor.h"

#include <algorithm>
#include <array>
#include <cmath>

#include "rnnoise/include/rnnoise.h"

namespace {

constexpr int kRnnoiseSampleRateHz = 48000;
constexpr double kHighPassFrequencyHz = 80.0;
constexpr double kButterworthQ = 0.7071067811865476;
constexpr double kPi = 3.14159265358979323846;

class HighPassFilter {
 public:
  explicit HighPassFilter(int sample_rate_hz) {
    const double omega = 2.0 * kPi * kHighPassFrequencyHz / sample_rate_hz;
    const double cosine = std::cos(omega);
    const double alpha = std::sin(omega) / (2.0 * kButterworthQ);
    const double a0 = 1.0 + alpha;
    b0_ = static_cast<float>(((1.0 + cosine) / 2.0) / a0);
    b1_ = static_cast<float>((-(1.0 + cosine)) / a0);
    b2_ = b0_;
    a1_ = static_cast<float>((-2.0 * cosine) / a0);
    a2_ = static_cast<float>((1.0 - alpha) / a0);
  }

  void Reset() { x1_ = x2_ = y1_ = y2_ = 0.0f; }

  float Process(float sample) {
    const float output = b0_ * sample + b1_ * x1_ + b2_ * x2_ - a1_ * y1_ -
                         a2_ * y2_;
    x2_ = x1_;
    x1_ = sample;
    y2_ = y1_;
    y1_ = output;
    return output;
  }

 private:
  float b0_ = 0.0f;
  float b1_ = 0.0f;
  float b2_ = 0.0f;
  float a1_ = 0.0f;
  float a2_ = 0.0f;
  float x1_ = 0.0f;
  float x2_ = 0.0f;
  float y1_ = 0.0f;
  float y2_ = 0.0f;
};

}  // namespace

struct OpenSpeakRnnoiseProcessor::State {
  State()
      : denoise(rnnoise_create(nullptr)),
        frame_size(rnnoise_get_frame_size()),
        high_pass(kRnnoiseSampleRateHz) {
    if (denoise != nullptr && frame_size == static_cast<int>(input.size())) {
      // Prime RNNoise's shared FFT tables away from the real-time callback.
      rnnoise_process_frame(denoise, output.data(), input.data());
    }
  }

  ~State() {
    if (denoise != nullptr) rnnoise_destroy(denoise);
  }

  bool ready() const {
    return denoise != nullptr && frame_size == static_cast<int>(input.size());
  }

  DenoiseState* denoise;
  int frame_size;
  HighPassFilter high_pass;
  std::array<float, 480> input{};
  std::array<float, 480> output{};
};

OpenSpeakRnnoiseProcessor::OpenSpeakRnnoiseProcessor() = default;

OpenSpeakRnnoiseProcessor::~OpenSpeakRnnoiseProcessor() = default;

void OpenSpeakRnnoiseProcessor::Initialize(int sample_rate_hz, int channels) {
  state_.reset();
  if (sample_rate_hz != kRnnoiseSampleRateHz || channels != 1) return;
  auto state = std::make_unique<State>();
  if (state->ready()) state_ = std::move(state);
}

void OpenSpeakRnnoiseProcessor::Release() {
  state_.reset();
}

void OpenSpeakRnnoiseProcessor::SetEnabled(bool enabled) {
  const bool changed = enabled_.exchange(enabled, std::memory_order_acq_rel) !=
                       enabled;
  if (changed && enabled) {
    reset_state_.store(true, std::memory_order_release);
  }
}

bool OpenSpeakRnnoiseProcessor::Process(float* samples,
                                        std::size_t frame_count) {
  if (!enabled_.load(std::memory_order_acquire) || samples == nullptr) {
    return false;
  }
  State* const state = state_.get();
  if (state == nullptr || frame_count != state->input.size()) return false;

  if (reset_state_.exchange(false, std::memory_order_acq_rel)) {
    state->high_pass.Reset();
    if (rnnoise_reset(state->denoise) != 0) return false;
  }
  for (std::size_t index = 0; index < frame_count; ++index) {
    const float sample = std::isfinite(samples[index]) ? samples[index] : 0.0f;
    state->input[index] = state->high_pass.Process(sample);
  }
  rnnoise_process_frame(state->denoise, state->output.data(),
                        state->input.data());
  for (std::size_t index = 0; index < frame_count; ++index) {
    const float sample = state->output[index];
    samples[index] =
        std::isfinite(sample)
            ? std::max(-32768.0f, std::min(sample, 32767.0f))
            : 0.0f;
  }
  return true;
}
