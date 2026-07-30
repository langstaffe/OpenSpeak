#!/bin/sh
set -eu

native_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/openspeak-rnnoise-test.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

for source in celt_lpc denoise kiss_fft pitch rnn rnn_data rnn_reader; do
  cc -std=c11 -O2 \
    -I"$native_dir/rnnoise/include" -I"$native_dir/rnnoise/src" \
    -c "$native_dir/rnnoise/src/$source.c" -o "$build_dir/$source.o"
done

c++ -std=c++14 -O2 -I"$native_dir" \
  "$native_dir/rnnoise_processor.cc" "$native_dir/rnnoise_processor_test.cc" \
  "$build_dir"/*.o -lm -o "$build_dir/rnnoise_processor_test"
"$build_dir/rnnoise_processor_test"
