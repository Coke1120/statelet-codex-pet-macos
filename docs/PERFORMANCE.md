# Statelet performance measurement

Statelet has a reproducible, local-only harness for CPU, memory, and lifecycle
presentation latency. The harness reports machine-readable JSON and does not
include executable, media, home-directory, or temporary paths. This repository
does not contain a completed live benchmark or claim that the current build
passes these targets; run the harness locally against the exact build and media
being evaluated.

## Default budgets

These are acceptance budgets for a freshly built release executable on an idle
Mac, not guarantees for every animation or machine:

| Metric | Default budget |
| --- | ---: |
| Player average CPU | 3% or less |
| Player peak RSS | 120 MB or less |
| Warm state-switch p95 | 300 ms or less |
| Aggregator average CPU, when measured | 0.3% or less |
| Sustained player CPU hard failure | Over 8% for 60 seconds |
| Player RSS hard failure | Over 250 MB |

Only `display_ready` with `transition_id=1` is cold startup. Capture order does
not change that classification: if the first captured event is transition 2,
it is warm evidence. Duplicate transition IDs are counted once so duplicated
log delivery cannot inflate the sample. Malformed or missing transition IDs
fail closed.

Acceptance also requires at least five unique warm transitions, ten player
samples, and an observation span of `min(60 seconds, requested duration)` with
a 50 ms scheduling tolerance. Live runs take a final process sample at or just
after the requested duration and record its actual monotonic elapsed time, so
late or failed early samples reduce the evidence span instead of fabricating a
full run. The default 60-second run can therefore observe the 60-second hard
CPU gate. RSS slope is reported in MB/hour for longer soak runs;
it is evidence for investigation rather than a universal pass/fail threshold.

## Run a local measurement

Build the release executable, then provide a real local media map whose clips
are readable:

```bash
swift build -c release --package-path mac/CodexPetMac
python3 mac/CodexPetMac/scripts/measure_runtime.py \
  --executable "$(pwd)/mac/CodexPetMac/.build/release/statelet" \
  --media-map "$HOME/Library/Application Support/Statelet/media/media-map.json" \
  --duration 60 \
  --interval 1 \
  --transition-interval 8
```

To measure the already-running state aggregator as well, pass its positive PID:

```bash
python3 mac/CodexPetMac/scripts/measure_runtime.py \
  --executable "$(pwd)/mac/CodexPetMac/.build/release/statelet" \
  --media-map "$HOME/Library/Application Support/Statelet/media/media-map.json" \
  --aggregator-pid 12345
```

The PID is accepted only while it belongs to the current user and its process
command identifies the installed Statelet state aggregator; identity is checked before
and after sampling. This is a best-effort local process-identity check, not
cryptographic attestation. If no PID is supplied, aggregator metrics are
reported as unavailable and do not affect acceptance.

Use 15–30 minutes for a memory soak. The script validates that inputs are
absolute, owned regular files rather than symlinks, copies and normalizes the
map into a private temporary directory, and launches the exact executable with
explicit temporary map and state paths. Live measurement forces the panel to
stay visible and above other windows while keeping normal pointer interaction;
this prevents the normal occlusion suspension from hiding lifecycle-transition
work. Keep the panel visible for the complete run. The harness redirects `HOME`,
`CFFIXED_USER_HOME`, and `TMPDIR`, samples with macOS `ps`, captures Statelet's
unified-log `display_ready` durations through a continuously drained bounded
parser, verifies the executable SHA-256 before and after the run, and
terminates the launched process group on success or failure. Raw unified-log
text is never retained. The configured state sequence repeats for the complete
run so long soaks continue exercising transitions. `footprint` is sampled when
the installed macOS version exposes a parseable value.

The process returns `0` when all required budgets pass, `1` when a measured
budget fails, and `2` for invalid input or an incomplete run. Save the JSON to
a private benchmark artifact if comparison across commits is needed; it
contains no paths, but hardware and OS context may still be identifying.

## CI-safe parser mode

Hosted CI must not launch the AppKit accessory or enforce machine resource
budgets. It should run the normal Python test discovery, which exercises only
fixture parsing, evaluation, fail-closed behavior, and the path-free report:

```bash
python3 -m unittest tests.test_macos_performance -v
```

The CLI equivalent is:

```bash
python3 mac/CodexPetMac/scripts/measure_runtime.py --fixture benchmark-fixture.json
```

Fixture keys are `player_samples`, optional `aggregator_samples`, `log`, required
`requested_duration_seconds`, optional `executable_sha256`, and optional
`footprint_mb`. Every `display_ready` fixture line must include a positive
`transition_id`. Logs containing private absolute paths are rejected. Fixture
files are capped at 1 MiB and each process sample list is capped at 20,000
entries. Results carry `measurement.mode=fixture`; they can pass parser budgets,
but executable attestation is always false. They are not live performance claims
or substitutes for a local run.

## Manual energy investigation

For a suspected wakeup or battery regression, use a release build and close
unrelated high-load applications first. These commands are intentionally
manual because their results depend on hardware, display state, media, and OS:

```bash
sudo powermetrics --samplers tasks --show-process-energy -i 1000 -n 60
open -a "Activity Monitor"
```

In Activity Monitor, inspect Statelet's **Energy**, **CPU**, and **Memory** tabs
during idle playback and several state transitions. `powermetrics` requires
administrator approval and is never invoked by the harness or hosted CI.
