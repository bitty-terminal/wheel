# Provider stub evidence

Offline Gate 2 evidence for the harness provider path (CTX-0029 / wheel#95). It
proves that a synthetic provider credential reaches only the intended loopback
stub and never appears in captured output, errors, request records, or test
artifacts. It is not a live-provider test, not a release claim, and not a
complete Gate 2 pass.

## What runs

`just test-provider-stub` (also part of `just check` and CI) runs
`tests/test_provider_stub.lua`, which:

1. Creates a private scratch directory under `$WHEEL_TEST_TMP` when set,
   otherwise `${TMPDIR:-/tmp}/bitty`.
2. Starts `tests/provider_stub.py` in a separate process. The stub binds
   `127.0.0.1:0`, publishes an atomically written `0600` readiness record
   (protocol marker, host, port, pid), and serves exactly
   `POST /chat/completions`. Every other path, method, or malformed request is
   rejected with a static response; the normal stub never redirects. A second
   instance runs in `--redirect` mode only to prove the client refuses a 302
   without a second hop.
3. Constructs the real `OpenAIAdapter` with the stub URL and a fixed,
   clearly synthetic key, and performs one non-streaming completion through
   `tests/provider_stub_client.py`.
4. Fails the run if the completion content, finish reason, request path, or
   observed authorization state is wrong. A wrong key must return 401 and be
   recorded as invalid; a missing key environment (including one with an
   ambient value present) must fail before a request reaches the stub; a
   request without an authorization header must return 401; a key containing
   CRLF must fail with only the static `ValueError` type and no value echo;
   non-loopback hosts, URL userinfo, other paths, query strings, fragments,
   and other methods must be refused locally; a 302 must be refused without a
   second hop.
5. Scans every file the run creates, plus every captured stdout/stderr,
   error, adapter description, request, response, and shutdown channel, for
   all synthetic values. Any occurrence fails the test.
6. Terminates only the pid recorded at launch and confirmed by the stub's
   readiness record. SIGTERM must complete the stub's graceful shutdown path
   (proved by its atomic clean-shutdown marker); a SIGKILL fallback leaves the
   marker missing and fails the test. The scratch directory is removed on
   success and on failure.

The stub and client are test-only: they are not imported by the harness and are
not packaged into a release artifact.

## Credential model

- The synthetic key is a fixed, obviously fake string declared in the test. No
  real credential is read.
- The key reaches the stub and client as `WHEEL_PROVIDER_STUB_KEY` in their
  child environments. The Lua test exports it through an anonymous `sh -s`
  script pipe, not through an `env` argv, a request file, or a configuration
  file, so the value never enters a process command line or a persisted file.
  Every client invocation first runs `unset WHEEL_PROVIDER_STUB_KEY`, so an
  ambient value cannot satisfy a missing-key probe.
- The stub refuses to start if the key appears in its own argv. The scan runs
  before argument parsing with a static diagnostic, so even an unrecognized
  option that carries the key cannot be echoed by `argparse`. The client
  refuses to run in the same situation. The test additionally reads the
  launched stub's `/proc/<pid>/cmdline`; an unreadable value fails the check
  instead of passing vacuously.
- The client discards any caller-supplied `Authorization` or `X-Api-Key`
  header and attaches the environment value only as
  `Authorization: Bearer <key>` for the single loopback request. A test-only
  `omit_authorization` flag suppresses the header so the stub's 401 path can
  be exercised without weakening the normal path.
- Transport diagnostics are static. The client reports only
  `type(error).__name__` for transport failures; `http.client` embeds rejected
  header values in its `ValueError` message, so neither that message nor a
  traceback is ever written to stderr. The Lua test bounds and redacts any
  child diagnostic before it can reach an assertion message.
- The request record stores path, method, status, declared body size, and two
  booleans: whether an authorization header was present and whether it
  matched. It never stores the header value, the key, or the prompt body.

Same-user residual: the child environment is readable by any process running
as the same user while the stub is alive, and the synthetic key exists in the
Lua test's memory. This is the accepted secret-environment risk recorded in
`SECURITY-MODEL.md`; the stub adds no production authority.

## Plaintext loopback rationale

The stub speaks plaintext HTTP on an ephemeral loopback port. There is no TLS
terminator on `127.0.0.1:0`, the traffic never leaves the host, and the only
credential is synthetic. The test client enforces the scheme, host, exact
path, and absence of userinfo/query/fragment, and never follows a redirect.
Production provider adapters are unchanged: they keep HTTPS and the live test
(`just test-live`) remains the only path that contacts a real provider.

## What this does not prove

- This provider-stub test does not inspect execution audit output. The
  `tests/real_host_fixture.lua` audit section (CTX-0030) does inspect the local
  JSONL, but independent reviewer inspection remains open.
- Asynchronous cancellation is not implemented; only timeout and process-group
  cleanup are covered elsewhere. Gate 2 cancellation evidence remains open.
- No Bitty panel or terminal presentation run was performed. Gate 2 remains
  open for panel presentation with recorded host and tool versions.
- No external network, TLS verification, proxy, or live-provider behavior is
  exercised.

See `SECURITY-MODEL.md` Gate 2 for the current evidence inventory and open
items.

## Reproducing

```sh
just test-provider-stub   # offline; requires python3 and a Lua interpreter
just check                # includes the provider-stub gate
```

`just test-live` stays separate and is the only recipe that reads a real
provider credential.
