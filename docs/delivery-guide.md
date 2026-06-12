# Using `delivery_module` in a Logos Project

This is the operating manual for integrating `delivery_module` — Logos's
pub/sub messaging core module — into any Logos project. It assumes you've
already built a basic Logos core module (if not, start with
[workshop.md](workshop.md) Parts 1–2).

Everything here is the distilled "project knowledge" — what you'd wish you'd
known before wiring this up yourself.

## Table of contents

- [What `delivery_module` is](#what-delivery_module-is)
- [Where it sits in the stack](#where-it-sits-in-the-stack)
- [Minimum viable integration](#minimum-viable-integration)
- [API reference](#api-reference)
- [Event reference](#event-reference)
- [Config schema](#config-schema)
- [Content topic conventions](#content-topic-conventions)
- [Payload encoding](#payload-encoding)
- [Cookbook](#cookbook)
- [Gotchas](#gotchas)
- [Testing strategies](#testing-strategies)
- [Running two peers on one machine](#running-two-peers-on-one-machine)
- [References](#references)

---

## What `delivery_module` is

- A **Logos core module** that wraps the
  [`logos-delivery`](https://github.com/logos-messaging/logos-delivery)
  library (Nim), which implements the Waku v2 family of pub/sub
  protocols.
- Source: [logos-co/logos-delivery-module](https://github.com/logos-co/logos-delivery-module).
  Shipped pre-installed with Basecamp — you **consume it, you don't build it**.
- Gives your module: *publish a message on a content topic; subscribe to a
  content topic and receive every message anyone else publishes on it*.

In one sentence: **your Logos module gets Waku pub/sub by calling a
dozen methods on `delivery_module` via `LogosAPI`.**

## Where it sits in the stack

```
  ┌──────────────────────┐     ┌──────────────────────┐
  │  your_core_module    │     │ another_peer_module  │
  │  (your C++ plugin)   │     │ (remote machine)     │
  └──────────┬───────────┘     └──────────┬───────────┘
             │ invokeRemoteMethod                 │
             ▼                                    │
  ┌──────────────────────┐                        │
  │   delivery_module    │                        │
  │ (Qt plugin, C++)     │                        │
  └──────────┬───────────┘                        │
             │                                    │
             ▼                                    │
  ┌──────────────────────┐                        │
  │  liblogosdelivery    │ ← gossipsub over libp2p ▶
  │  (Nim / FFI)         │                        │
  └──────────────────────┘                        ▼
             ▲                               the Waku network
             │ (same stack on every peer)    (logos.dev / twn / your own)
```

Your code only ever touches the `your_core_module → delivery_module` arrow.
Everything below it is the library's job.

## Minimum viable integration

The smallest usable integration has **seven steps**. Copy this as a
starting point, rename "polling" to your module name.

### 1. Declare the dependency

`flake.nix`:

```nix
{
  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    delivery_module.url      = "github:logos-co/logos-delivery-module";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
```

`metadata.json`:

```json
{
  "name": "your_module",
  "type": "core",
  "main": "your_module_plugin",
  "dependencies": ["delivery_module"],
  "nix": { "packages": {"build":[],"runtime":[]}, "external_libraries":[], "cmake":{"find_packages":[],"extra_sources":[],"extra_include_dirs":[],"extra_link_libraries":[]} }
}
```

Both are needed: **the flake input lets the SDK generate interop headers,
the metadata dep lets Basecamp load `delivery_module` before loading you.**

### 2. Include the SDK headers

```cpp
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"   // for LogosObject* — NOT QObject*
#include "logos_sdk.h"
```

### 3. Hold the client + object on your plugin

```cpp
class YourPlugin : public QObject, public YourInterface {
    // ...
private:
    LogosAPIClient* m_deliveryClient = nullptr;
    LogosObject*    m_deliveryObject = nullptr;
    int             m_connectionState = 0;   // 0=off, 1=connecting, 2=connected, 3=error
};
```

### 4. Initialise once (get a client, create a node, register handlers, start)

```cpp
bool YourPlugin::bringUpDelivery()
{
    m_deliveryClient = logosAPI->getClient("delivery_module");
    if (!m_deliveryClient) return false;

    // A — Create the node
    const QString cfg = R"({"logLevel":"INFO","mode":"Core","preset":"logos.dev"})";
    m_deliveryClient->invokeRemoteMethod("delivery_module", "createNode", cfg);

    // B — Get the object and register handlers BEFORE starting
    m_deliveryObject = m_deliveryClient->requestObject("delivery_module");

    m_deliveryClient->onEvent(m_deliveryObject, "messageReceived",
        [this](const QString&, const QVariantList& data) {
            handleMessage(data);
        });

    m_deliveryClient->onEvent(m_deliveryObject, "connectionStateChanged",
        [this](const QString&, const QVariantList& data) {
            if (data.isEmpty()) return;
            // Match "Connected" AND "PartiallyConnected" — current
            // liblogosdelivery emits both depending on per-shard connectivity.
            if (data[0].toString().contains("Connected", Qt::CaseInsensitive)) {
                m_connectionState = 2;
            }
        });

    // C — Start
    m_deliveryClient->invokeRemoteMethod("delivery_module", "start");
    return true;
}
```

### 5. Subscribe to a topic

```cpp
m_deliveryClient->invokeRemoteMethod(
    "delivery_module", "subscribe", "/yourapp/1/main/json");
```

### 6. Publish a message

```cpp
const QString topic   = "/yourapp/1/main/json";
const QString payload = R"({"hello":"world"})";
m_deliveryClient->invokeRemoteMethod(
    "delivery_module", "send", topic, payload);
```

### 7. Handle incoming messages

```cpp
void YourPlugin::handleMessage(const QVariantList& data)
{
    // messageReceived: [hash, contentTopic, payload_base64, timestamp_ns]
    if (data.size() < 3) return;

    const QString    topic   = data[1].toString();
    const QByteArray payload = QByteArray::fromBase64(data[2].toString().toUtf8());

    const QJsonDocument doc = QJsonDocument::fromJson(payload);
    if (!doc.isObject()) return;

    // ... do something with doc.object() ...
}
```

That's the complete cycle. Everything else is variations on this shape.

---

## API reference

Every method is `Q_INVOKABLE`, synchronous (RPC over Qt Remote Objects),
and callable via `client->invokeRemoteMethod("delivery_module", <name>, ...)`.
A call that returns `void` in the table returns an empty `QVariant` — check
`.isValid()` to detect RPC failure.

| Method | Args | Returns | Purpose |
| --- | --- | --- | --- |
| `createNode` | `QString cfg` | `bool` / `LogosResult` | Initialise the node from a JSON config. Call **exactly once per process** before anything else (see Gotcha #8 for Stop+Start). |
| `start` | — | `bool` / `LogosResult` | Connect to peers, start the gossipsub engine. Emits `connectionStateChanged` as the connection progresses. |
| `stop` | — | `bool` / `LogosResult` | Disconnect. Safe to `start()` again afterwards. |
| `subscribe` | `QString topic` | `bool` / `LogosResult` | Start receiving `messageReceived` events for this content topic. Multiple subscribes are fine; duplicates are deduped internally. |
| `unsubscribe` | `QString topic` | `bool` / `LogosResult` | Stop receiving for this topic. |
| `send` | `QString topic, QString payload` | `LogosResult` | Publish a message. Returns a result with a `requestId` you can correlate with later `message_sent` / `message_propagated` / `message_error` events. Via `invokeRemoteMethod` it comes back as a `QVariant` — `.isValid() == false` means the RPC itself failed (not the send). |
| `getAvailableConfigs` | — | `QString` | List available preset names (e.g. `["logos.dev", "twn"]`). |
| `getAvailableNodeInfoIDs` | — | `QString` | IDs of introspection data you can query. |
| `getNodeInfo` | `QString nodeInfoId` | `QString` | JSON blob of diagnostic info (peer count, node id, etc.). |
| `initLogos` | `LogosAPI*` | `void` | Called by the host when the plugin is loaded. Not user-facing. |

**Lifecycle contract** (from the plugin's header docstring):

```
createNode (once) → start → [subscribe/send/unsubscribe]* → stop
```

Calling `send`/`subscribe` before `createNode` returns `false` with the log
line *"Cannot … — context not initialized. Call createNode first."*

**Return-type evolution.** Older `delivery_module` builds returned a plain
`bool` from `createNode` / `start` / `stop` / `subscribe` / `unsubscribe`.
Newer builds return a `LogosResult` struct from these too (matching `send`).
The QVariant comes back wrapping whichever the current build uses, and
`QVariant::toBool()` always evaluates to `false` on the wrapped struct — so
calling `.toBool()` directly will silently look like a failure. Unwrap
safely with `canConvert<LogosResult>()` and fall back to the bool path:

```cpp
const QVariant r = client->invokeRemoteMethod("delivery_module", "start");
if (!r.isValid()) { /* RPC itself failed */ }
else if (r.canConvert<LogosResult>()) {
    const LogosResult lr = r.value<LogosResult>();
    if (!lr.success) { /* lr.error has the reason */ }
} else if (!r.toBool()) {
    /* legacy bool return — call failed */
}
```

---

## Event reference

`delivery_module` emits all async state via its `eventResponse(QString
eventName, QVariantList data)` signal. Subscribe to a specific event with
`client->onEvent(deliveryObject, eventName, callback)`.

| Event | `data[]` layout | Meaning |
| --- | --- | --- |
| `messageReceived` | `[hash, contentTopic, payload_base64, timestamp_ns]` | A message arrived on one of your subscribed topics. |
| `messageSent` | `[requestId, messageHash, timestamp]` | The send service accepted and queued your message. |
| `messagePropagated` | `[requestId, messageHash, timestamp]` | Your message was **delivered to neighboring peers on the network**. This is the "receipt" that proves the broadcast went out. |
| `messageError` | `[requestId, messageHash, error, timestamp]` | A send failed — `error` is a human-readable reason. |
| `connectionStateChanged` | `[statusString, timestamp]` | Connection state changed. `statusString` is `"Connected"` / `"PartiallyConnected"` / `"Connecting"` / `"Disconnected"`. `"PartiallyConnected"` was added when the Waku node started surfacing per-shard connectivity independently — treat it as a healthy state. Use `contains("Connected", Qt::CaseInsensitive)` to match both green states in one check. |

**Typical lifecycle of a send**:

```
send()  ──►  message_sent         (library accepted your payload)
         └► message_propagated    (delivered to N peers)
```

or

```
send()  ──►  message_sent
         └► message_error        (propagation failed — e.g. no peers)
```

Timestamps on inbound events are **nanoseconds since epoch**; on outbound
lifecycle events they're local ISO-8601 strings.

---

## Config schema

The `createNode` argument is a single flat JSON object. Full field
documentation lives in `DeliveryModulePlugin::createNode`'s docstring. The
keys you'll actually touch:

| Key | Type | Default | Use when |
| --- | --- | --- | --- |
| `preset` | string | `""` | You want sane network defaults. `"logos.dev"` for dev/workshops, `"twn"` for the production RLN-protected Waku network. |
| `mode` | string | `"noMode"` | Always `"Core"` unless you know why you want an Edge node. |
| `logLevel` | string | `"INFO"` | `"TRACE"` / `"DEBUG"` for diagnostics. |
| `clusterId` | u16 | `0` | Override the preset's cluster (rarely needed). |
| `entryNodes` | []string | `[]` | Custom bootstrap peers (enrtree / multiaddress). Override the preset's. |
| `relay` | bool | `false` | Participate in relaying messages for other peers. Preset turns this on. |
| `rlnRelay` | bool | `false` | Enable RLN rate-limit nullifier (required on `twn`). |
| `tcpPort` | u16 | `60000` | P2P TCP listen port. **Override for multi-peer on one machine** — see below. |
| `discv5UdpPort` | u16 | `9000` | Discv5 UDP listen port. Pair it with `tcpPort` overrides. |
| `numShardsInNetwork` | u16 | `1` | Auto-sharding count. Preset sets this to 8 for logos.dev. |
| `maxMessageSize` | string | `"150KiB"` | Upper bound on payload size. |

**Rule:** individual keys supplied alongside a `preset` **override** the
preset's values. You can always start from a preset and tweak.

**Presets at a glance**:

- `"logos.dev"` — cluster 2, 8 auto-shards, built-in bootstrap nodes, mix
  enabled, p2p reliability on. **Use for everything non-production.**
- `"twn"` — The RLN-protected Waku Network (cluster 1). Requires RLN
  credentials; not suitable for casual dev.

---

## Content topic conventions

Format: `/<app>/<version>/<subtopic>/<format>`

Real-world examples from the Logos ecosystem:

| Topic | Module |
| --- | --- |
| `/simplechat/1/messages/json` | simplechat |
| `/tictactoe/1/moves/proto` | tictactoe core (C++ UI path) |
| `/tictactoe/1/moves/json` | tictactoe core (QML UI path) |
| `/polling/1/poll-<id>/json` | polling (the one we built) |

**Guidelines:**

- `<app>` = your module name or product name. Short, lowercase.
- `<version>` = integer, bump when the payload format changes in a
  non-backward-compatible way.
- `<subtopic>` = what this topic carries. Can be a fixed string
  (`messages`, `moves`) or include a parameter (`poll-<id>`).
- `<format>` = `json` if your payload is JSON text, `proto` if protobuf,
  etc. This is a social convention, not enforced by the network — but it
  lets any peer seeing the topic name know what to expect.

See the
[Logos Improvement Proposal on content topics](https://lip.logos.co/messaging/informational/23/topics.html#content-topics)
for the formal spec.

---

## Payload encoding

`send(topic, payload)` takes a **`QString`**, not `QByteArray`. That shapes
how you encode.

**If your payload is text (JSON, plaintext chat):** send it directly.

```cpp
const QString payload = QString::fromUtf8(
    QJsonDocument(myObject).toJson(QJsonDocument::Compact));
client->invokeRemoteMethod("delivery_module", "send", topic, payload);
```

**On receive** — `data[2]` is always base64-encoded by the delivery
module's wire format. One `fromBase64` gets your bytes back:

```cpp
const QByteArray payload = QByteArray::fromBase64(data[2].toString().toUtf8());
const QJsonDocument doc  = QJsonDocument::fromJson(payload);
```

**If your payload is binary (protobuf, raw bytes):** base64-encode it
yourself before `send`, so it survives the `QString` round-trip. Then on
receive you `fromBase64` **twice** — once for the wire format, once for
your own encoding.

```cpp
// Send
std::string serialized;
myProto.SerializeToString(&serialized);
const QString payload = QString::fromLatin1(
    QByteArray(serialized.data(), serialized.size()).toBase64());
client->invokeRemoteMethod("delivery_module", "send", topic, payload);

// Receive
const QByteArray wire  = QByteArray::fromBase64(data[2].toString().toUtf8());
const QByteArray bytes = QByteArray::fromBase64(wire);    // <-- second decode
myProto.ParseFromArray(bytes.data(), bytes.size());
```

A good way to remember it: **single-decode if what you sent was already
text; double-decode if what you sent was binary.**

---

## Cookbook

### Pattern: "broadcast + local-echo ignored"

Many apps don't want to receive their own messages back (they already
applied the effect locally). Filter on sender id in your payload:

```cpp
struct Payload { QString senderId; QString body; };

void MyPlugin::handleMessage(const QVariantList& data) {
    const auto obj = /* decode JSON ... */;
    if (obj["senderId"].toString() == m_myId) return;   // skip our own echo
    applyRemote(obj);
}
```

### Pattern: "dedup by sender id, latest wins"

If the same sender can legitimately send multiple messages but you only
want the most recent one counted (the polling module does this for "change
your vote"), key state by sender id:

```cpp
QHash<QString, QVariant> m_latest;   // senderId -> latest payload

void MyPlugin::handleMessage(const QVariantList& data) {
    const auto obj = /* ... */;
    m_latest.insert(obj["senderId"].toString(), obj["value"].toVariant());
    emit somethingChanged();
}
```

Duplicate deliveries of the same message are harmless — same key, same
value, net effect zero.

### Pattern: "request / response over pub/sub"

Use two topics:

```
/myapp/1/requests/json          ← clients publish asks here
/myapp/1/responses/<reqId>/json ← servers publish replies here
```

Clients subscribe to their response topic, publish to requests with a
`reqId`, and wait for a matching reply. No request/response primitive in
libp2p pubsub — you build it on top.

### Pattern: "lazy initialisation"

Most apps don't need delivery up at module load — bring it up on first use
and tear down when nobody's watching:

```cpp
bool MyPlugin::doThing() {
    if (!m_started && !bringUpDelivery()) return false;
    // ... use delivery ...
    return true;
}
```

Upsides: startup is fast, Nim runtime isn't loaded until needed.
Downsides: first call is slower (createNode + start take ~1–5 seconds).

### Pattern: "graceful shutdown"

Destructor / stopDelivery should unsubscribe then stop, in that order:

```cpp
void MyPlugin::tearDownDelivery() {
    for (const auto& topic : m_subscribedTopics) {
        m_deliveryClient->invokeRemoteMethod(
            "delivery_module", "unsubscribe", topic);
    }
    m_deliveryClient->invokeRemoteMethod("delivery_module", "stop");
    m_deliveryObject = nullptr;
    m_started        = false;
}
```

Skipping the unsubscribe isn't catastrophic (stopping tears everything
down) but gives cleaner logs.

---

## Gotchas

### 1. `requestObject` returns `LogosObject*`, not `QObject*`

Compile error looks like:

```
incompatible pointer types assigning to 'QObject *' from 'LogosObject *'
```

Fix: `#include "logos_object.h"` and declare the member as
`LogosObject* m_deliveryObject`.

### 2. The connection-status race

`start()` is synchronous. But during the call, the Qt event loop can drain
incoming events, including `connectionStateChanged`. So if your code is:

```cpp
client->invokeRemoteMethod("delivery_module", "start");   // event fires inside here
m_status = "connecting";                                   // ← overwrites the "Connected" update
```

…you'll be stuck on "connecting" forever even though you're actually
connected. Fix: set "connecting" **before** `start()`, and let the event
handler own the upgrade to "connected":

```cpp
m_status = "connecting";
client->invokeRemoteMethod("delivery_module", "start");
// No status write here — the handler already did.
```

### 3. Register handlers BEFORE `start()`

Events fire during `start()`. Any handler not yet registered misses them,
and `connectionStateChanged` is usually the one most easily missed.

### 4. Port collision between two instances on one machine

Both `tcpPort` (60000) and `discv5UdpPort` (9000) need different values
for a second instance. Override both — see the next section.

The env var name is **per-app** — whatever the plugin reads via
`qEnvironmentVariableIntValue(...)`. There is no shared "Basecamp port
override"; if your second instance still fails with `failed to open udp
port: (48) Address already in use`, the env var you set is being read by
some other plugin (or none), not the one you're trying to move. Check
the plugin's source to confirm the var name. Some plugins (e.g. the
workshop's `shared_color`) additionally hard-code a binary
Instance A / Instance B model — only two same-machine instances are
supported, distinguished by whether the env var is set.

### 5. First build is slow

`logos-delivery-module`'s source closure pulls the Nim toolchain,
`nim-libp2p`, `zerokit` (Rust), `liblogosdelivery`, and `libpq`. Budget
**15–30 minutes** for the first build on a cold Nix cache; seconds
thereafter.

### 6. `"Cannot subscribe — context not initialized"` in logs

You called `subscribe`/`send` before `createNode`. Check your init order.

### 7. Base64 decode count

One decode for text payloads, two for binary. See
[Payload encoding](#payload-encoding).

### 8. `createNode` is once-per-process — even across Stop+Start

The "exactly once per process" rule isn't just at startup. After a `stop()`,
calling `createNode` a second time returns an error ("context already
initialized") and surfaces as a user-visible error toast. Track a `bool
m_createNodeDone` on your plugin and skip `createNode` on subsequent
`start()` cycles — go straight to registering handlers and calling
`start()`:

```cpp
if (!m_createNodeDone) {
    if (!invokeBool("createNode", "createNode", cfg)) { /* … */ }
    m_createNodeDone = true;
}
// register handlers, then start()
```

### 9. Don't call back into `delivery_module` from inside its event handler

If a `messageReceived` callback needs to publish a reply (e.g. a
request/response pattern over pub/sub), invoking `send` *synchronously*
from inside the handler re-enters `delivery_module` while it's still
dispatching the inbound event — and deadlocks the main thread. Defer the
reply with `QTimer::singleShot(0, …)` so the dispatch can finish first:

```cpp
QTimer::singleShot(0, this, [this, topic, payload]() {
    m_deliveryClient->invokeRemoteMethod(
        "delivery_module", "send", topic, payload);
});
```

### 10. `logos.dev` preset's bootstrap peers don't currently handshake

As of this writing, the `logos.dev` preset ships with bootstrap peer IDs
that no longer match the running peers' actual IDs, so the libp2p noise
handshake fails and Waku drops them. `connectionStateChanged` therefore
never reaches `"Connected"` against the public `logos.dev` network even
though `start()` itself succeeds.

If your UX needs a green light to unblock the user, optimistically flip
your local state to "connected" right after `start()` returns and let
the event handler upgrade or downgrade later if peers actually arrive:

```cpp
if (!invokeBool("start", "start")) { setDeliveryStatus(3); return false; }
m_started = true;
if (m_deliveryStatus < 2) setDeliveryStatus(2);   // optimistic
```

Self-echo over gossipsub still works (you receive your own publishes),
so a single-peer workshop demo functions fine; you just don't see real
remote peers until upstream rotates the preset's bootstrap IDs.

---

## Testing strategies

### Solo: self-echo via the log

Gossipsub broadcasts your own messages back to you. If you vote/send in a
single instance, the `messageReceived` handler fires with your own data
— that proves send *and* receive both work without needing a second peer.

```bash
# Capture Basecamp's stderr
nohup open -W -n "/path/to/Basecamp.app" \
  --stdout /tmp/bc.log --stderr /tmp/bc.log > /dev/null 2>&1 &

# Trigger a send from your UI, then:
grep -E 'DeliveryModulePlugin::send|eventType.*message_|dispatching event' /tmp/bc.log
```

Look for the chain: `send called` → `message_sent` → `message_propagated`
→ `messageReceived` dispatched to 1 callback. If all four show up, your
module works end-to-end.

### Headless: `logoscore call`

Your module's `Q_INVOKABLE` methods are callable from the CLI without a
UI:

```bash
logoscore -D -m "$HOME/Library/Application Support/Logos/LogosBasecamp/modules" &
logoscore load-module your_module
logoscore call your_module bringUpDelivery
logoscore call your_module sendSomething "hello"
logoscore stop
```

Handy for integration tests and CI.

### Multi-peer: two machines

The canonical test — two laptops on the same network, same `.lgx`
installed, join the same topic. Votes / chats / whatever flow between
them within a second or two of any action.

### Multi-peer: two Basecamps on one machine

See below.

---

## Running two peers on one machine

Useful for demos and development. Only the P2P ports collide between
instances; data dir can be shared as long as your modules' persistent
state doesn't conflict.

### Make your module port-overridable

Read an env var at `createNode` time:

```cpp
QJsonObject cfgObj;
cfgObj["logLevel"] = "INFO";
cfgObj["mode"]     = "Core";
cfgObj["preset"]   = "logos.dev";

const int customPort = qEnvironmentVariableIntValue("YOURAPP_TCPPORT");
if (customPort > 0) {
    cfgObj["tcpPort"]       = customPort;
    cfgObj["discv5UdpPort"] = 9000 + (customPort - 60000);   // keep TCP and UDP paired
}

const QString cfg = QString::fromUtf8(
    QJsonDocument(cfgObj).toJson(QJsonDocument::Compact));
client->invokeRemoteMethod("delivery_module", "createNode", cfg);
```

### Launch two instances

```bash
# Instance A — defaults
nohup open -W -n "/path/to/Basecamp.app" \
  --stdout /tmp/bc-A.log --stderr /tmp/bc-A.log > /dev/null 2>&1 &

sleep 2

# Instance B — overridden ports (60001 TCP, 9001 UDP)
nohup open -W -n "/path/to/Basecamp.app" \
  --stdout /tmp/bc-B.log --stderr /tmp/bc-B.log \
  --env YOURAPP_TCPPORT=60001 > /dev/null 2>&1 &
```

`open --env` passes the env var into the launched bundle and its child
processes, including the `logos_host` that runs your module.

### Caveats

- Both Basecamps share `~/Library/Application Support/Logos/LogosBasecamp/`.
  Fine for modules whose state is in-memory; may conflict for modules
  persisting to SQLite / filesystem with shared paths.
- Each Basecamp spins up its own `logos_host` processes for every loaded
  module, so plugin-level state is naturally isolated.
- Qt Remote Object registry names are instance-scoped (Basecamp generates
  unique suffixes), so RPC routing doesn't clash.

---

## References

- **This guide's companion documents** (in this repo):
  - [workshop.md](workshop.md) — walks through building a polling module
    from scratch (Part 3)
  - [cheatsheet.md](cheatsheet.md) — condensed command reference

- **Upstream source**:
  - [logos-co/logos-delivery-module](https://github.com/logos-co/logos-delivery-module)
    — the Qt plugin (what you call)
  - [logos-messaging/logos-delivery](https://github.com/logos-messaging/logos-delivery)
    — the Nim library it wraps
  - [DeliveryModulePlugin header](https://github.com/logos-co/logos-delivery-module/blob/master/src/delivery_module_plugin.h)
    — authoritative docstring for every method and event (read this before
    asking anyone questions)

- **Spec**:
  - [LIP-23: Content topics](https://lip.logos.co/messaging/informational/23/topics.html)

- **Reference implementations**:
  - [fryorcraken/logos-module-tictactoe](https://github.com/fryorcraken/logos-module-tictactoe)
    (PR #5 in particular — the multiplayer branch is the cleanest
    end-to-end example)
  - [logos-co/eth-lez-atomic-swaps](https://github.com/logos-co/eth-lez-atomic-swaps)
    (delivery-dogfooding.md documents Rust-binding papercuts — worth
    skimming if you're running into oddities)
