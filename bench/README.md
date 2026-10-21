# Wheel benchmark suite

Status: implementation for wheel#86 / CTX-0025. Offline benchmark evidence,
not a release performance claim. The release-smoke ceilings are regression
signals; the owner has not accepted them as release-blocking budgets.

## Purpose and scope

The suite measures Wheel's multiplicative paths at more than one cardinality:

| Scenario        | Workload                                                                     | Cardinalities        |
| --------------- | ---------------------------------------------------------------------------- | -------------------- |
| `activation`    | `require("wheel")` cold (fresh process) and warm (cleared modules), CPU time | 1 entry point        |
| `process`       | `WheelHost.proc.run_program` normal exit and timeout                         | 1, 5, 20 calls       |
| `runner`        | `WheelRunner.run_task` against `WheelProvider.MockProvider`                  | 1, 5, 10 turns       |
| `orchestration` | `WheelTeam:run_orchestration_loop` with mock workers and a reviewer          | 1, 5, 10 tasks       |
| `context`       | `WheelContext` slot write/read and Three-Zone `compile_prompt`               | 10, 100, 1,000 slots |

Everything is offline and deterministic. There is no network, no credentials,
no live provider, no artificial sleep, and no dependency beyond the Lua
interpreter and the repository sources. Process calls and cold activation
spawn subprocesses; the process scenario exercises the production bounded
wrapper, so it is the one intentionally expensive scenario.

Out of scope:

- live provider latency, throughput, or token-per-second measurement;
- cross-host comparison claims (a record describes one environment);
- a dashboard, historical database, or general benchmarking framework;
- replacing functional tests with benchmarks.

## Commands

```sh
just bench                 # full suite, human-readable
just bench-json            # full suite, JSON on stdout
just bench-release-smoke   # short subset with generous ceilings
```

Extra arguments go to `bench/run.lua`:

```sh
just bench --scenario runner --samples 10
just bench-json --scenario context > recording/bench-context-$(date +%F).json
```

Direct invocation works too:

```sh
sh bench/run.sh --help
WHEEL_BENCH_NO_PIN=1 sh bench/run.sh --scenario activation
```

The full suite is manual and takes roughly a minute on the recorded host,
mostly because every process call pays the production 250 ms post-exit sweep
grace. The release smoke is the bounded subset; it is not part of `just check`.
`just check` runs the benchmark unit tests (`tests/test_bench.lua`) and one
short context-scenario run instead.

## Interpreter and pinning

`bench/run.sh` selects the release-gate interpreter in this order: `lua5.1`,
`luajit`, `lua`. LuaJIT is a sensitivity check, not the release baseline, and
the script warns when it is used. `WHEEL_BENCH_LUA` overrides the selection.

When `taskset` is available, the runner derives the first CPU from the current
affinity mask and pins the process to it; the selected CPU is recorded in the
result. `WHEEL_BENCH_NO_PIN=1` disables pinning. A missing `taskset` only warns
and runs unpinned, so the suite never fails just because pinning is
unavailable. A missing interpreter fails closed.

## Measurement method

- CPU-time series use `os.clock()` (process CPU time). `WheelHost.time.now()` is
  not used for timing because the standalone backend maps it to `os.time()`
  with one-second resolution.
- Process wall time reads `/proc/uptime` (10 ms resolution on Linux) and falls
  back to `os.time()` when that file is absent. The chosen source and
  resolution are recorded in every result.
- `activation` counts cold samples in fresh interpreter processes through the
  hidden `--child-cold` mode, so process startup is outside the measured
  region while module loading and registration are inside it. Warm samples
  clear every `wheel.*` / `lua.wheel.*` module and re-require the entry.
- Instruction counts use a `debug.sethook` count hook in separate instrumented
  runs; the hook inflates CPU time and is never mixed into the timing series.
  Registration count is checked against the command catalog on every
  activation sample.
- `process` measures each call individually. The per-call distribution across
  all calls is reported, not a batch total. The fixed sweep grace is reported
  separately from the command's own timeout. Process calls are fresh OS
  boundaries, so `--warmup` does not apply to this scenario; the JSON records
  the requested value for the other scenarios. The 1,000-slot context series
  also runs without a warm-up to avoid doubling its cost.
- `runner` measures the whole `run_task` call in CPU time and the mock
  provider's stream work through a thin wrapper; runner overhead is the
  difference. The mock performs no I/O and no sleeps.
- `orchestration` times only `run_orchestration_loop`; team and task
  construction are excluded. One reviewer plus N coding workers run N
  independent ready tasks with the default deterministic step function.
- `context` times slot write, slot read, and prompt compilation from a fresh
  `WheelContext`. At N=1,000 the default 64 KiB budget is exceeded on purpose,
  so the compile series includes the multi-tier reduction path.

Statistics are fixed: min, median, p95 by nearest rank (`ceil(0.95 n)`), max,
and IQR from nearest-rank quartiles. Every series states its sample count.

Sample counts are scenario-specific because cost varies by orders of
magnitude:

| Scenario        | Default samples                      |
| --------------- | ------------------------------------ |
| `activation`    | 30 cold, 30 warm, 5 + 5 instrumented |
| `process`       | 2 per mode/cardinality               |
| `runner`        | 30 per cardinality                   |
| `orchestration` | 15 at 1 task, 5 at 5, 3 at 10        |
| `context`       | 30 at 10 slots, 5 at 100, 1 at 1,000 |

The 1,000-slot context series uses one sample and the 10-task orchestration
series uses three because each sample costs seconds (pure-Lua SHA-256 content
hashing and coordination work respectively). The result records the real n,
so a single-sample series is never presented as a distribution.

## Output

Human output prints one line per series and a short derived summary
(per-turn cost, per-task cost, per-slot compile cost, sweep-grace share).
JSON output is a single object with stable, sorted keys:

```json
{
  "schema_version": 1,
  "generated_at": "2026-10-21T12:00:00Z",
  "environment": {
    "revision": "0123456789ab",
    "dirty": false,
    "interpreter": "Lua 5.1",
    "interpreter_name": "lua5.1",
    "jit": false,
    "cpu": "...",
    "cpu_count": 16,
    "os": "...",
    "kernel": "...",
    "arch": "x86_64",
    "pinning": "taskset",
    "pinned_cpu": 2
  },
  "config": {
    "profile": "full",
    "samples_override": null,
    "scenarios": ["activation"]
  },
  "scenarios": [
    {
      "name": "activation",
      "series": [
        {
          "name": "cold_cpu",
          "unit": "us",
          "samples": 30,
          "stats": { "n": 30, "median": 1234.5 }
        }
      ]
    }
  ],
  "smoke": { "passed": true, "checks": [] }
}
```

Records include the Wheel revision, interpreter, CPU model, OS, kernel,
architecture, pinning, and the wall-clock source. They never include the
checkout path, user name, or hostname. Keep result files under gitignored
`recording/`; no host-specific baseline is committed.

## Release smoke

`just bench-release-smoke` runs a bounded subset: 5 activation samples, one
process sample for normal 1/5 calls and a timeout at 1 call, 3 runner samples
at 1/10 turns, one orchestration sample at 1/10 tasks, and 3 context samples at
10/100 slots. It exits non-zero when a ceiling or a relative-scaling check
fails.

The ceilings are deliberately wide: activation median CPU must stay under the
RC-1 50 ms budget (cold p95 under 100 ms), a normal process call p95 under 5 s,
a timeout call p95 under 6 s, the 10-turn runner p95 under 5 s, the 10-task
orchestration p95 under 15 s, and the largest context compile p95 under 2 s.
Relative checks allow 100x for runner 10/1 turns, 200x for orchestration 10/1
tasks, and 500x for the smoke context 100/10 slots (the full suite also runs
1,000 slots). These are broad guards against a
missing fast path or a quadratic path, not a performance contract. The
orchestration ceiling is the widest because a shared host can stretch a
ten-task wave several-fold between runs.

The command is not wired into CI and its output is not a release claim until
the owner accepts thresholds and the release checklist consumes the record.

## Limitations

- One host per record; results are per-environment evidence.
- CPU frequency is not locked and the host may be shared. Medians are the
  stable comparison; cold maxima and single-sample series are observations,
  not distributions.
- `/proc/uptime` quantizes process wall time to 10 ms. That is small against a
  300 ms call but visible at the low end.
- Process calls require GNU `timeout`, `setsid`, `sleep`, and the other
  utilities the production host seam already requires; an unavailable utility
  fails the scenario rather than silently skipping it.
- On PUC Lua 5.1 without a native bit library, context slot writes use the
  pure-Lua SHA-256 fallback and cost about 5 ms per 48-byte slot on the
  recorded host. That cost is real product behavior, not benchmark overhead.
- Activation measurement includes source compilation and excludes interpreter
  process startup (cold samples) or includes only the re-require (warm
  samples), as stated in the series names.
