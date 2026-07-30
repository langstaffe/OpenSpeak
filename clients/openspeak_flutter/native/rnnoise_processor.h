#ifndef OPENSPEAK_RNNOISE_PROCESSOR_H_
#define OPENSPEAK_RNNOISE_PROCESSOR_H_

#include <atomic>
#include <cstddef>
#include <memory>

class OpenSpeakRnnoiseProcessor {
 public:
  OpenSpeakRnnoiseProcessor();
  ~OpenSpeakRnnoiseProcessor();

  OpenSpeakRnnoiseProcessor(const OpenSpeakRnnoiseProcessor&) = delete;
  OpenSpeakRnnoiseProcessor& operator=(const OpenSpeakRnnoiseProcessor&) =
      delete;

  void Initialize(int sample_rate_hz, int channels);
  void Release();
  void SetEnabled(bool enabled);
  bool Process(float* samples, std::size_t frame_count);

 private:
  struct State;

  std::unique_ptr<State> state_;
  std::atomic<bool> enabled_{false};
  std::atomic<bool> reset_state_{false};
};

#endif  // OPENSPEAK_RNNOISE_PROCESSOR_H_
