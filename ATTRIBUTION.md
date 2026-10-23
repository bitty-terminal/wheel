# Caller attribution

Wheel can declare an optional caller identity on OpenAI-compatible provider
requests. The mechanism is caller-declared, never inferred: a caller chooses an
application identity, and Wheel translates it into the headers an
OpenRouter-style gateway aggregates on.

Attribution is **opt-in and off by default**. An adapter constructed without an
`attribution` block sends no identity headers, so default traffic remains
private and unattributed. Wheel hardcodes no product URL, title, or category.

## Header contract

| Field        | Header                        | Required | Validation                                                                                                                            |
| ------------ | ----------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `referer`    | `HTTP-Referer`                | yes      | Absolute `http`/`https` URL with a valid host and optional numeric port `1..65535`; printable ASCII, no userinfo, at most 2048 bytes. |
| `title`      | `X-OpenRouter-Title`          | yes      | Printable ASCII, no leading or trailing whitespace, at most 120 bytes.                                                                |
| `categories` | `X-OpenRouter-Categories`     | no       | Array of one or two lowercase tokens matching `[a-z0-9-]{1,30}`; the joined header is at most 61 bytes.                               |
| `visibility` | `X-OpenRouter-App-Visibility` | no       | Only `hidden`.                                                                                                                        |

`referer` is the application identity and the key a gateway merges usage on.
`title` only sets the display name. `categories` is optional metadata supplied
as an array; Wheel's intended category is `{ "cli-agent" }`. `visibility =
"hidden"` opts a newly created application out of the public ranking and has no
effect on an existing one.

## Opt-in configuration

Pass the block when constructing the adapter, or through the provider factory
for the `openai` and `deepseek` routes:

```lua
local adapter = WheelProvider.OpenAIAdapter.new({
  api_key = api_key,
  base_url = "https://openrouter.ai/api/v1",
  model = model,
  attribution = {
    referer = "https://wheel.bitty.run", -- future identity; see below
    title = "Wheel",
    categories = { "cli-agent" },
    visibility = "hidden",
  },
  http_client = client,
})
```

```lua
local adapter = WheelProvider.create(
  { provider = "openai", model = model },
  { api_key = api_key, attribution = attribution, http_client = client }
)
```

Omit `attribution` to send no attribution headers. Other provider routes do
not consume the block or send these headers. There is deliberately no
environment-variable default: a local test, a fork, or an unrelated caller
must not claim Wheel's identity by accident.

## Identity, title, and icon

- The icon is associated with the `referer` application identity (or generated
  when no icon is available), not with the title.
- Changing only `title` keeps the existing application and its current
  temporary icon.
- Changing `referer` creates a different application identity, so the title
  and icon switch with it.
- Wheel therefore keeps no default `referer`. The formal
  [wheel.bitty.run](https://wheel.bitty.run) identity is wired only after the
  site and a Wheel-only favicon/logo exist, in a task that owns that switch.
  Until then, callers that need attribution supply their own identity and
  should use hidden visibility for test applications.

## Validation and failure behavior

Validation is fail-closed and runs before any request is sent:

- A missing, empty, oversized, non-string, or non-printable field is rejected.
- A `referer` that is not an absolute `http`/`https` URL, lacks a valid host,
  contains userinfo, or contains characters outside RFC 3986 is rejected. The
  complete authority is parsed: the host must be a valid DNS name, IPv4
  address, or bracketed IPv6 address, and an optional port must be numeric in
  `1..65535`. Empty labels, dot-only hosts, invalid IPv4, malformed IPv6,
  trailing bytes after a bracketed host, and text or out-of-range ports are
  rejected. CR, LF, tabs, and other control characters can never reach a
  header.
- `categories` must be an array of one or two lowercase strings matching
  `[a-z0-9-]{1,30}`. A comma-separated string, uppercase or non-ASCII entries,
  empty entries, more than two entries, sparse arrays, and extra keys are
  rejected. The joined comma-separated value is at most 61 bytes.
- Unknown fields fail closed, so a misspelled key cannot silently produce
  unattributed traffic. The block must be a plain table (no metatable).
- `visibility` accepts only `hidden`; other values, including booleans, are
  rejected.

Failures use the typed `E_ARGS_INVALID` code with class `validation`. The
message is bounded, static, and never echoes the rejected value.
`OpenAIAdapter.new` raises the typed error; `WheelProvider.create` returns
`nil, err` without contacting the HTTP client.

Attribution headers are adapter-owned. Caller-supplied `request.headers` or
`opts.headers` maps are not a header channel, so they cannot inject or override
`HTTP-Referer`, the OpenRouter headers, `Authorization`, or `Content-Type`.

## Testing and application creation

Tests use the reserved `attribution.example` identity (or another reserved
domain) and never a real credential or live provider call. When a test would
create a real OpenRouter application, it must declare
`visibility = "hidden"` and must not pollute public rankings. No CI path
creates an application.

The opt-in code path is covered by `just test`: default absence, a full valid
block, hidden visibility, categories, invalid forms, and the
`Authorization`/`Content-Type` regression.

## Status

This document describes the opt-in code path only. It does not create an
OpenRouter application, does not switch Wheel to the formal identity, and does
not close the broader attribution decision. The
[wheel.bitty.run](https://wheel.bitty.run) referral and Wheel-only logo switch
remain tracked separately.
