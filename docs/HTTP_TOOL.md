# HTTP Request tool (`dev.http`)

This tool sends requests you write yourself to endpoints you control, for
example a local mod server, a game's debug API or a development backend. It is
the only Developer Tool that uses the network. It is available only when
`Capability.networkRequests` is supported, and it never contacts anything
except the URL in the URL field.

## Sending a request

| Field | Behaviour |
| --- | --- |
| Method | GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS. GET and HEAD are sent without a body. |
| URL | Must be `http://` or `https://` with a host. Validation runs as you type, and errors show their line and column. A missing scheme (`example.com/x`, `localhost:8080`), other schemes, spaces, control characters, malformed `%` escapes, characters that must be encoded and ports outside 1-65535 are all rejected. |
| Headers | Rows of name and value, each with an enable checkbox. Names must be RFC 9110 tokens. Values may not contain CR, LF or NUL, which prevents header injection. Enabled duplicates are merged with `, ` (`; ` for Cookie). A menu adds common headers. |
| Body | **Raw text** or **JSON**. JSON is validated as you type, with the error position, and **Format JSON** pretty-prints it. Unless you set a `Content-Type` header, the tool sends `application/json; charset=utf-8` or `text/plain; charset=utf-8`. |
| Timeout | 1-120 s, default 20. It covers the whole exchange: connecting, headers and body. |
| Follow redirects | On by default, up to 5 hops. The final URL is shown. |

**Send** (Ctrl+Enter) runs the request as a tracked, cancellable operation on
the Activity panel. The operation title is `HTTP <METHOD> <host><path>` and never
includes the query string. **Cancel** stops the exchange immediately and closes
the connection. Cancelling from the Activity panel does the same.

Transport: `package:http`'s `IOClient` on top of `dart:io` `HttpClient`, with a new client for each
request (connection timeout = request timeout). The client is closed when the
request finishes, times out or is cancelled.

## Response

* A status badge shows the code and reason phrase, with an icon and text for the status class:
  2xx OK, 3xx info, 4xx warning, 5xx error.
* Timing tiles show the total time (Stopwatch from send to last byte), the time to response
  headers, and the body size.
* The response headers table lists every header. Sensitive ones (such as
  `Set-Cookie`, `Authorization` or anything containing token or session) are
  masked as `••••` until you tap reveal.
* Body views:
  * **Pretty JSON** appears when the content type contains `json` or the body starts with `{` or
    `[`. Bodies over 256 KB are formatted in a background isolate. Invalid JSON falls back to text
    with a note.
  * **Text** is decoded as UTF-8, or Latin-1 when the charset says so.
  * **Hex** gives a binary summary with the file type detected from magic bytes.
  * The display is capped at **2 MiB** and virtualised. **Save full body** writes every byte
    received via the normal save/export flow, with an extension guessed from the content type.
* Reading stops at a 64 MiB safety limit, which protects memory. If a body hits
  it, the response is marked.

## Errors

| Kind | Shown as |
| --- | --- |
| Timeout | "Timed out after N s" plus a hint |
| Cancelled | "Cancelled" (info) |
| Connection refused / DNS / unreachable | "Could not connect", with the localhost guidance below |
| TLS / certificate | "TLS / certificate problem". Nothing can be bypassed; see the next section. |
| Protocol / redirect loop | "Request failed" with the underlying message |

## TLS

Certificate verification is **always on**. The tool never sets
`HttpClient.badCertificateCallback` and never installs a trust override, so
self-signed or invalid certificates fail. A test (`test/features/dev_tools/security_test.dart`)
checks that `badCertificateCallback` appears nowhere in `lib/`. For a local
server, either use plain `http://` (development only) or a certificate the
device trusts.

## Redaction and history

Sensitive **header names**:
* `Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie` and `X-Api-Key`;
* any name containing `token`, `secret`, `password`, `api-key`, `apikey`,
  `api_key` or `session` (case-insensitive).

In the editor their values are masked (`••••`) and have a reveal toggle. They
are marked **SENSITIVE - masked, never saved**.

Sensitive **query parameter names** are any that contain `token`, `key`,
`secret`, `password`, `auth` or `sig`, for example `access_token`, `api_key`,
`X-Amz-Signature` or `auth`. The rule over-matches harmless names such as
`monkey`; that is intended, since over-redacting is safe.

The **history** keeps the last **50** requests, newest first. It is stored in
`features.json` under the key `dev_tools.http_history` as
`{"v":1,"items":[...]}`. Each item stores:

* id, time, method;
* the URL, **redacted**. Sensitive query and fragment values become `REDACTED`,
  and `user:password@` becomes `REDACTED@`;
* status and reason, or the error message; elapsed ms and response size;
* the headers as name, value and enabled. Sensitive values are stored as `••••`
  and are never saved in clear text;
* the request body, but **only** if none of these apply:
  * the request carried an enabled sensitive header;
  * the body looks like it holds credentials (keys such as `password`, `secret`,
    `token`, `access_token`, `refresh_token`, `api_key`, `client_secret`,
    `authorization`);
  * the body is larger than 32 KiB.

  A note records why a body was left out.

Redaction happens when an entry is created, and again when history is loaded
from disk (defence in depth). Response bodies and response headers are never
stored.

**Replay**: tapping a history entry loads its method, URL, headers and body into the
editor. Masked header values are cleared and flagged **VALUE REQUIRED**, and
Send refuses to run until they are re-entered or the row is disabled. If the
URL still contains `REDACTED`, a warning asks you to replace those placeholders.

**Export log** writes the redacted history as plain text through Save/Export.
It includes method, redacted URL, status or error, time, size, redacted headers
and the stored bodies. **Clear history** asks for confirmation.

## Phone localhost vs your computer

The panel is also built into the tool.

* On a **phone or tablet**, `localhost` and `127.0.0.1` refer to the device
  itself. A server running on your computer cannot be reached that way.
* The **Android emulator** reaches the host computer at **`10.0.2.2`**, for
  example `http://10.0.2.2:8080/`.
* The **iOS simulator** shares the Mac's network, so `localhost` works there.
* A **physical device** needs the computer's **LAN IP**, for example
  `http://192.168.1.23:8080/`. Also:
  * bind the server to **`0.0.0.0`**, not `127.0.0.1`, so it accepts connections from other devices;
  * allow the port in the computer's **firewall**;
  * keep both devices on the **same network** (Wi-Fi). Guest networks often isolate clients.
* **iOS** may ask for **Local Network** access the first time the app contacts
  a LAN address. Allow it, or LAN requests fail.
* Cleartext `http://` is for such development servers only. Real services
  should use `https://`. The tool shows a warning whenever you enter an
  `http://` URL.

To find the LAN IP: on Windows run `ipconfig` and read the IPv4 address. On
Linux run `ip addr`. On macOS use `ipconfig getifaddr en0`.
