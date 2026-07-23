# RNNoise Web runtime

These files are loaded lazily when the Web client opens its microphone.
Native OpenSpeak clients do not load or use them.

- `workletProcessor.js` and `rnnoise.wasm` are from
  `@sapphi-red/web-noise-suppressor` 0.3.5.
- `rnnoise.wasm` SHA-256:
  `8b60a2ab88fdae2d1a9f940249d0eb072f28ba8e796f7304347b4e07839c8853`
- `workletProcessor.js` SHA-256:
  `7e95f138ff6901a6a246dd29e6be4a1e8e4ada2baf0bcc04dae065745b51ff3d`

The package is MIT licensed, its bundled `@shiguredo/rnnoise-wasm`
runtime is Apache-2.0 licensed, and RNNoise itself is BSD-3-Clause licensed.
The corresponding license texts are kept beside the runtime files.
