#!/usr/bin/env python3
"""Key-free offline tests for the live provider selector.

Covers ``WHEEL_LIVE_PROVIDER`` resolution, the credential environment and host
binding for each provider, and the fail-closed diagnostics. It never reads a
real credential and never reaches the network: request validation rejects
before the HTTP opener is built, and ``main`` tests replace ``fetch`` with a
stub. Run by ``just test-live`` and the offline ``just check`` aggregate.
"""

from __future__ import annotations

import io
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.dont_write_bytecode = True

import live_http_client as client

FAKE_KEY = "not-a-real-key"
OPENROUTER = client.PROVIDERS["openrouter"]
COMMANDCODE = client.PROVIDERS["commandcode"]
OPENAI_CACHE = client.PROVIDERS["openai-cache"]


class _BinarySink:
    def __init__(self) -> None:
        self.data = b""

    def write(self, data: bytes) -> int:
        self.data += data
        return len(data)

    def flush(self) -> None:
        pass


class _FakeStdin:
    def __init__(self, data: bytes) -> None:
        self.buffer = io.BytesIO(data)


class _FakeStdout:
    def __init__(self) -> None:
        self.buffer = _BinarySink()


def _wire_spec(url: str) -> dict[str, Any]:
    return {
        "url": url,
        "method": "POST",
        "headers": {"Content-Type": "application/json"},
        "body": "{}",
    }


def _make_fake_fetch(captured: list[dict[str, Any]]) -> Any:
    def _fake_fetch(
        spec: dict[str, Any],
        api_key: str,
        allowed_host: str,
        require_https: bool = True,
    ) -> tuple[int, bytes]:
        captured.append(
            {
                "spec": spec,
                "api_key": api_key,
                "allowed_host": allowed_host,
                "require_https": require_https,
            }
        )
        return 200, b'{"ok":true}'

    return _fake_fetch


def _expect_invalid_request(
    spec: dict[str, Any],
    allowed_host: str,
    require_https: bool = True,
) -> None:
    try:
        client.fetch(
            spec,
            FAKE_KEY,
            allowed_host=allowed_host,
            require_https=require_https,
        )
    except client.InvalidRequest:
        return
    raise AssertionError(f"client accepted an invalid request for {spec['url']!r}")


# 1. Default and case-insensitive selection.
assert client.select_provider(None) is OPENROUTER
assert client.select_provider("") is OPENROUTER
assert client.select_provider("   ") is OPENROUTER
assert client.select_provider("openrouter") is OPENROUTER
assert client.select_provider("OpenRouter") is OPENROUTER
assert client.select_provider(" commandcode ") is COMMANDCODE
assert client.select_provider("CommandCode") is COMMANDCODE
assert client.select_provider(" OPENAI-CACHE ") is OPENAI_CACHE
print("PASS live provider selector defaults to OpenRouter and is case-insensitive")

# 2. Unknown values fail closed instead of falling back to another provider.
assert client.select_provider("openrouter ") is OPENROUTER
for _value in ("bogus", "open router", "command-code"):
    try:
        client.select_provider(_value)
    except client.InvalidRequest as error:
        message = str(error)
        assert client.PROVIDER_SELECTOR_ENV in message
        assert all(name in message for name in client.PROVIDERS)
        assert _value not in message, "diagnostic must not echo the rejected value"
    else:
        raise AssertionError(f"selector accepted unknown value {_value!r}")
print("PASS live provider selector fails closed on unknown values")

# 3. Each provider host is bound to the selected provider and HTTPS only.
_expect_invalid_request(
    _wire_spec("https://openrouter.ai/api/v1/chat/completions"),
    allowed_host=COMMANDCODE.allowed_host,
)
_expect_invalid_request(
    _wire_spec("https://api.openai.com/v1/chat/completions"),
    allowed_host=COMMANDCODE.allowed_host,
)
_expect_invalid_request(
    _wire_spec("https://api.commandcode.ai/provider/v1/chat/completions"),
    allowed_host=OPENAI_CACHE.allowed_host,
)
_expect_invalid_request(
    _wire_spec("https://api.commandcode.ai/provider/v1/chat/completions"),
    allowed_host=OPENROUTER.allowed_host,
)
_expect_invalid_request(
    _wire_spec("http://api.commandcode.ai/provider/v1/chat/completions"),
    allowed_host=COMMANDCODE.allowed_host,
)
_expect_invalid_request(
    _wire_spec("https://api.commandcode.ai:8443/provider/v1/chat/completions"),
    allowed_host=COMMANDCODE.allowed_host,
)
_expect_invalid_request(
    _wire_spec("https://user:secret@api.commandcode.ai/provider/v1/chat/completions"),
    allowed_host=COMMANDCODE.allowed_host,
)
_expect_invalid_request(
    _wire_spec("https://api.commandcode.ai.example/provider/v1/chat/completions"),
    allowed_host=COMMANDCODE.allowed_host,
)
print("PASS live HTTP client binds HTTPS requests to the selected provider host")

# 4. main() reads the selected provider's key environment and host, never the
#    other provider's key, and never echoes the key.
for _provider in client.PROVIDERS.values():
    captured: list[dict[str, Any]] = []
    fake_stdout = _FakeStdout()
    stderr = io.StringIO()
    request_spec = json.dumps(
        {
            "url": f"https://{_provider.allowed_host}/api/v1/chat/completions",
            "body": "{}",
        }
    ).encode("utf-8")
    with (
        mock.patch.object(client, "fetch", side_effect=_make_fake_fetch(captured)),
        mock.patch.dict(
            os.environ,
            {
                client.PROVIDER_SELECTOR_ENV: _provider.name,
                _provider.api_key_env: FAKE_KEY,
                **{
                    other.api_key_env: "wrong-provider-key"
                    for other in client.PROVIDERS.values()
                    if other is not _provider
                },
            },
        ),
        mock.patch.object(sys, "stdin", _FakeStdin(request_spec)),
        mock.patch.object(sys, "stdout", fake_stdout),
        mock.patch.object(sys, "stderr", stderr),
    ):
        exit_code = client.main()

    assert exit_code == 0, f"{_provider.name} main failed: {stderr.getvalue()}"
    assert len(captured) == 1
    assert captured[0]["api_key"] == FAKE_KEY
    assert captured[0]["allowed_host"] == _provider.allowed_host
    assert captured[0]["require_https"] is True
    assert fake_stdout.buffer.data == b'STATUS 200\n{"ok":true}'
    assert FAKE_KEY not in fake_stdout.buffer.data.decode("utf-8", "replace")
    assert stderr.getvalue() == ""
print("PASS live HTTP client uses the selected provider key and host")

# 5. An unset selected-provider key produces a clear, key-free failure even
#    when the other provider's key is present.
for _provider in client.PROVIDERS.values():
    fake_stdout = _FakeStdout()
    stderr = io.StringIO()
    with (
        mock.patch.object(client, "fetch") as fetch_mock,
        mock.patch.dict(
            os.environ,
            {
                client.PROVIDER_SELECTOR_ENV: _provider.name,
                _provider.api_key_env: "",
                **{
                    other.api_key_env: FAKE_KEY
                    for other in client.PROVIDERS.values()
                    if other is not _provider
                },
            },
        ),
        mock.patch.object(sys, "stdin", _FakeStdin(b"{}")),
        mock.patch.object(sys, "stdout", fake_stdout),
        mock.patch.object(sys, "stderr", stderr),
    ):
        exit_code = client.main()

    fetch_mock.assert_not_called()
    assert exit_code == 1
    assert stderr.getvalue() == (
        f"{_provider.api_key_env} is not set in the helper environment\n"
    )
    assert FAKE_KEY not in stderr.getvalue()
    assert fake_stdout.buffer.data == b""
print(
    "PASS live HTTP client reports an unset selected-provider key without cross-provider fallback"
)

# 6. The key-presence probe uses only a fixed marker and never reads the live
# request or contacts a provider when the selected key is absent.
fake_stdout = _FakeStdout()
stderr = io.StringIO()
with (
    mock.patch.object(client, "fetch") as fetch_mock,
    mock.patch.dict(
        os.environ,
        {
            client.PROVIDER_SELECTOR_ENV: OPENAI_CACHE.name,
            OPENAI_CACHE.api_key_env: "",
        },
    ),
    mock.patch.object(sys, "argv", ["live_http_client.py", "--check-key"]),
    mock.patch.object(sys, "stdin", _FakeStdin(b"must remain unread")),
    mock.patch.object(sys, "stdout", fake_stdout),
    mock.patch.object(sys, "stderr", stderr),
):
    exit_code = client.main()

fetch_mock.assert_not_called()
assert exit_code == 0
assert fake_stdout.buffer.data == b"KEY_ABSENT OPENAI_API_KEY\n"
assert stderr.getvalue() == ""
print("PASS key-presence probe skips without reading request data or contacting a host")

# 7. An unsupported selector fails before reading stdin or contacting a host.
fake_stdout = _FakeStdout()
stderr = io.StringIO()
with (
    mock.patch.object(client, "fetch") as fetch_mock,
    mock.patch.dict(
        os.environ,
        {
            client.PROVIDER_SELECTOR_ENV: "bogus",
            OPENROUTER.api_key_env: FAKE_KEY,
            COMMANDCODE.api_key_env: FAKE_KEY,
        },
    ),
    mock.patch.object(sys, "stdin", _FakeStdin(b"{}")),
    mock.patch.object(sys, "stdout", fake_stdout),
    mock.patch.object(sys, "stderr", stderr),
):
    exit_code = client.main()

fetch_mock.assert_not_called()
assert exit_code == 1
message = stderr.getvalue()
assert message == (
    "unsupported WHEEL_LIVE_PROVIDER value; expected openrouter or commandcode or openai-cache\n"
)
assert FAKE_KEY not in message
assert fake_stdout.buffer.data == b""
print("PASS live HTTP client fails closed on an unsupported selector")

# 8. The Lua selector fails closed with exit 2 before invoking the helper.
lua = next(
    (candidate for candidate in ("lua5.1", "luajit", "lua") if shutil.which(candidate)),
    None,
)
if lua is None:
    print("SKIP Lua selector exit-code check: no Lua interpreter")
else:
    repo_root = Path(__file__).resolve().parents[1]
    env = dict(os.environ)
    env[client.PROVIDER_SELECTOR_ENV] = "bogus"
    env.pop(OPENROUTER.api_key_env, None)
    env.pop(COMMANDCODE.api_key_env, None)
    env.pop(OPENAI_CACHE.api_key_env, None)
    result = subprocess.run(
        [lua, "tests/test_live_provider.lua"],
        cwd=repo_root,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 2, (
        f"Lua unknown-provider exit must be 2, got {result.returncode}"
    )
    assert FAKE_KEY not in result.stdout and FAKE_KEY not in result.stderr
    assert client.PROVIDER_SELECTOR_ENV in result.stderr
    print("PASS live provider Lua selector fails closed with exit 2")

    env[client.PROVIDER_SELECTOR_ENV] = "openai-cache"
    result = subprocess.run(
        [lua, "tests/test_live_provider.lua"],
        cwd=repo_root,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, (
        f"Lua OpenAI cache test must skip without its key, got {result.returncode}"
    )
    assert "SKIP test-live: OPENAI_API_KEY is not set" in result.stdout
    assert result.stderr == ""
    print("PASS live OpenAI cache test skips cleanly without its key")

print("PASS live provider selection")
