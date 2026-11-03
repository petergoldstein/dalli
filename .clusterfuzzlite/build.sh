#!/bin/bash -eu
# Builds the fuzz targets in fuzz/ for ClusterFuzzLite. Dalli is pure Ruby,
# so this copies the code and Ruzzy into $OUT and writes a launcher per target.

mkdir -p "$OUT/dalli"
cp -R lib fuzz "$OUT/dalli/"
rm -rf "$OUT/dalli/fuzz/corpus"

# Ruzzy is installed in the build image only; the runner gets this copy.
# The launchers below do what OSS-Fuzz's ruzzy script does, which
# ClusterFuzzLite's runner image doesn't have.
rsync -a --exclude cache/ --exclude doc/ /install/ruzzy/ "$OUT/fuzz-gem/"

for harness in fuzz/fuzz_*_harness.rb; do
  target=$(basename "$harness" _harness.rb)

  # The comment names libFuzzer's entry point, which is how the runner
  # recognizes the launcher as a fuzz target
  cat > "$OUT/$target" <<LAUNCHER
#!/usr/bin/env bash
# LLVMFuzzerTestOneInput for fuzzer detection.
this_dir=\$(dirname "\$0")
export GEM_HOME=\$this_dir/fuzz-gem GEM_PATH=\$this_dir/fuzz-gem
# Keeps the runner's ASan options, with the ones Ruzzy needs last
export ASAN_OPTIONS="\${ASAN_OPTIONS:+\$ASAN_OPTIONS:}allocator_may_return_null=1:detect_leaks=0:use_sigaltstack=0"
LD_PRELOAD=\$(ruby -e 'require "ruzzy"; print Ruzzy::ASAN_PATH') \\
  ruby "\$this_dir/dalli/fuzz/$target.rb" "\$@"
LAUNCHER
  chmod +x "$OUT/$target"

  corpus="fuzz/corpus/${target#fuzz_}"
  if [ -d "$corpus" ]; then
    (cd "$corpus" && zip -q -r "$OUT/${target}_seed_corpus.zip" .)
  fi
done
