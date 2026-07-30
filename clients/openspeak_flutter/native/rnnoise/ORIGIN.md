# RNNoise source

This directory vendors the C sources used by the existing Web bundle:

- Repository: https://github.com/shiguredo/rnnoise
- Tag: `2022.1.0`
- Commit: `0aee43d89c685ccadeca5409cb7adc93462f4bc8`

`@shiguredo/rnnoise-wasm` `2022.2.0`, bundled under `web/rnnoise`, builds
this RNNoise tag. OpenSpeak carries two native-integration changes: an MSVC
compatibility macro uses `_alloca` for the eight variable-length stack arrays
unsupported by MSVC C11 (other compilers keep the original declarations), and
`rnnoise_reset` clears an existing state without reallocating its RNN buffers
when noise suppression is re-enabled. The original BSD 3-Clause terms are in
`COPYING`.
