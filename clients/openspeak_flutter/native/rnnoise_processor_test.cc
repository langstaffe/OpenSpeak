#include "rnnoise_processor.h"

#include <array>
#include <cassert>
#include <cmath>

int main() {
  OpenSpeakRnnoiseProcessor processor;
  std::array<float, 480> frame{};
  for (std::size_t index = 0; index < frame.size(); ++index) {
    frame[index] =
        10000.0f * std::sin(2.0 * 3.14159265358979323846 * index / 48.0);
  }

  const auto original = frame;
  assert(!processor.Process(frame.data(), frame.size()));
  assert(frame == original);

  processor.Initialize(44100, 1);
  processor.SetEnabled(true);
  assert(!processor.Process(frame.data(), frame.size()));

  processor.Initialize(48000, 1);
  assert(processor.Process(frame.data(), frame.size()));
  for (const float sample : frame) {
    assert(std::isfinite(sample));
    assert(sample >= -32768.0f && sample <= 32767.0f);
  }

  processor.SetEnabled(false);
  frame = original;
  assert(!processor.Process(frame.data(), frame.size()));
  assert(frame == original);

  for (int count = 0; count < 20; ++count) {
    processor.SetEnabled(true);
    frame = original;
    assert(processor.Process(frame.data(), frame.size()));
  }
  processor.SetEnabled(false);
  frame.fill(0.0f);
  assert(!processor.Process(frame.data(), frame.size()));
  processor.SetEnabled(true);
  assert(processor.Process(frame.data(), frame.size()));
  for (const float sample : frame) assert(std::abs(sample) < 0.001f);
}
