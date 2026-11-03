# Fuzzing

These targets feed Dalli's reply parsing the bytes a server could send. They
fail when anything other than an error Dalli raises on purpose escapes. See
`DalliFuzz.expected_error?` in `fuzz_helper.rb`.

| Target | What it parses |
|---|---|
| `fuzz_response_processor` | The reply to one request, read line by line. The first byte picks the request. |
| `fuzz_pipelined_get` | A `get_multi`'s replies, from the buffer. The first byte sets the size of each socket read and whether the request was raw. |

Each target has two files. `fuzz_<name>_harness.rb` is the target.
`fuzz_<name>.rb` starts Ruzzy's tracing and then loads the harness, since
Ruzzy only measures coverage of Ruby code loaded after tracing starts.
`corpus/` holds seed inputs.

## CI

`.github/workflows/fuzzing.yml` builds the targets with ClusterFuzzLite
(`.clusterfuzzlite/`):
- **Pull requests** that change `lib/` or `fuzz/` get a 5-minute run.
- **Weekly:** a 30-minute run.

A crash fails the job, and its input is uploaded as an artifact.

## Running locally

ClusterFuzzLite's images are x86_64 Linux. With Docker and a checkout of
[OSS-Fuzz](https://github.com/google/oss-fuzz):

```bash
cd oss-fuzz
python3 infra/helper.py build_image --external /path/to/dalli
python3 infra/helper.py build_fuzzers --external /path/to/dalli --sanitizer address
python3 infra/helper.py run_fuzzer --external dalli fuzz_response_processor -- -max_total_time=60
```

To reproduce a crash, pass its input file in place of the options:

```bash
python3 infra/helper.py reproduce --external dalli fuzz_pipelined_get crash-<hash>
```
