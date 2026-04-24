# Logos Module Cheatsheet

A one-pager for building `.lgx` modules. Pair with [workshop.md](workshop.md)
for the full walk-through.

## Core concepts

| Term            | In one line                                                                  |
| --------------- | ---------------------------------------------------------------------------- |
| **Module**      | A Qt plugin (`.so`/`.dylib`) loaded dynamically by a Logos runtime.          |
| **`.lgx`**      | Zipped package: plugin binary + `manifest.json` + per-platform variants.     |
| **`core`**      | Backend module (C++ only). What this workshop builds.                        |
| **`ui_qml`**    | UI module (QML, optionally with a C++ backend running in `ui-host`).         |
| **`LogosAPI`**  | The IPC bridge — how modules discover and call each other at runtime.        |
| **`logoscore`** | Headless runtime. Loads modules, makes calls from the CLI.                   |
| **`lgpm`**      | Package manager. Installs/lists/removes `.lgx` packages in a modules dir.    |
| **`lm`**        | Inspects a compiled plugin — dumps metadata and its `Q_INVOKABLE` methods.   |

## Two module shapes

**`ui_qml` — QML-only UI module.** No compile step.

```
my_ui/
├── flake.nix          # inputs: logos-module-builder → mkLogosQmlModule
├── metadata.json      # type: "ui_qml", view: "Main.qml"
└── Main.qml           # the UI
```

**`core` — C++ backend module.** Exposes methods other modules call.

```
my_core/
├── flake.nix          # inputs: logos-module-builder → mkLogosModule
├── metadata.json      # type: "core", main: "my_core_plugin"
├── CMakeLists.txt     # logos_module(NAME ... SOURCES ...)
└── src/
    ├── my_core_interface.h   # pure virtual interface (Q_INVOKABLE methods)
    ├── my_core_plugin.h      # QObject + interface; Q_OBJECT / Q_PLUGIN_METADATA
    └── my_core_plugin.cpp    # implementations
```

Four rules to keep straight:

1. `name` in `metadata.json` == `name()` in C++ == CMake `NAME`. Mismatch ⇒
   install fails with a confusing error.
2. UI modules go in Basecamp's `plugins/` dir, core modules in `modules/`.
3. Supported IPC types: `int`, `bool`, `QString`, `QByteArray`, `QVariant`,
   `QJsonArray`, `QStringList`, `LogosResult`.
4. `initLogos(LogosAPI*)` is `Q_INVOKABLE`, **not** `override`, and must
   assign to the global `logosAPI` (from the SDK) — not a member variable.

## Essential commands

```bash
# Scaffold
nix flake init -t github:logos-co/logos-module-builder               # default (core)
nix flake init -t github:logos-co/logos-module-builder#ui-qml        # QML-only UI
nix flake init -t github:logos-co/logos-module-builder#ui-qml-backend  # UI + C++

# One-time git dance (flakes need a repo)
git init && git add -A && nix flake update && git add flake.lock

# Build + package
nix build '.#lib'                                      # just the plugin (.so/.dylib)
nix build '.#lgx'          --out-link result           # local LGX (paths ref /nix/store)
nix build '.#lgx-portable' --out-link result-portable  # portable LGX — use this for Basecamp

# Always single-quote '.#foo' — zsh eats the # otherwise.

# Inspect (core modules only)
lm metadata result/lib/my_module_plugin.so
lm methods  result/lib/my_module_plugin.so
lm methods  result/lib/my_module_plugin.so --json

# Peek inside a .lgx
tar -tzf result-portable/*.lgx

# Install into Basecamp (GUI)
#   Modules → Install LGX Package → select the .lgx

# Install into Basecamp (manual — macOS)
BASECAMP_DIR="$HOME/Library/Application Support/Logos/LogosBasecamp"
#   Linux: BASECAMP_DIR="$HOME/.local/share/Logos/LogosBasecamp"
SUBDIR=plugins   # ui_qml / ui-qml-backend modules
# SUBDIR=modules # core modules
mkdir -p "$BASECAMP_DIR/$SUBDIR/my_module" /tmp/lgx && \
  tar xzf result-portable/*.lgx -C /tmp/lgx && \
  cp /tmp/lgx/variants/darwin-arm64/* "$BASECAMP_DIR/$SUBDIR/my_module/" && \
  cp /tmp/lgx/manifest.json            "$BASECAMP_DIR/$SUBDIR/my_module/" && \
  echo "darwin-arm64" >                 "$BASECAMP_DIR/$SUBDIR/my_module/variant"
# Restart Basecamp.

# Headless run (core modules only)
lgpm --modules-dir ./modules install --file result/*.lgx
logoscore -D -m ./modules &
logoscore load-module my_module
logoscore call my_module someMethod arg1 arg2
logoscore stop
```

Fetch the CLIs once per machine:

```bash
nix build 'github:logos-co/logos-module#lm'                  --out-link ./lm
nix build 'github:logos-co/logos-logoscore-cli'              --out-link ./logos
nix build 'github:logos-co/logos-package-manager#cli'        --out-link ./pm
```

## Icons

Basecamp sidebar tabs show a PNG icon next to the name.

1. Put a PNG at `icons/<name>.png` in your module repo (128×128 works well).
2. In `metadata.json`: `"icon": "icons/<name>.png"`.
3. Rebuild `.#lgx-portable`. The builder flattens the icon path into the
   manifest automatically.

SVG not supported — use PNG.

## `metadata.json` — ui_qml

```json
{
  "name": "my_ui",
  "version": "0.1.0",
  "type": "ui_qml",
  "category": "example",
  "description": "…",
  "view": "Main.qml",
  "icon": null,
  "dependencies": [],
  "nix": {
    "packages": { "build": [], "runtime": [] },
    "external_libraries": [],
    "cmake": { "find_packages": [], "extra_sources": [], "extra_include_dirs": [], "extra_link_libraries": [] }
  }
}
```

## `Main.qml` skeleton

```qml
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    width: 480; height: 320

    ColumnLayout {
        anchors.centerIn: parent
        Text   { text: "Hello, world!" }
        Button {
            text: "Call core module"
            onClicked: {
                const r = logos.callModule("my_core", "someMethod", ["arg"])
                console.log(r)
            }
        }
    }
}
```

## Minimal core module interface

```cpp
#include <QObject>
#include <QString>
#include "interface.h"

class MyInterface : public PluginInterface {
public:
    virtual ~MyInterface() = default;
    Q_INVOKABLE virtual QString hello(const QString& name) = 0;
};

#define MyInterface_iid "org.logos.MyInterface"
Q_DECLARE_INTERFACE(MyInterface, MyInterface_iid)
```

## Minimal plugin skeleton

```cpp
#include "my_interface.h"
#include "logos_api.h"
#include "logos_sdk.h"

class MyPlugin : public QObject, public MyInterface {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID MyInterface_iid FILE "metadata.json")
    Q_INTERFACES(MyInterface PluginInterface)

public:
    QString name()    const override { return "my_module"; }   // must match metadata.json
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api) { logosAPI = api; }
    Q_INVOKABLE QString hello(const QString& n) override { return "hi " + n; }

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);
};
```

## Linking extra Qt modules into a core plugin

`logos_module()` links the Qt modules the SDK needs. To add more (e.g. Sql,
Network, Concurrent, WebSockets), `find_package` + `target_link_libraries`
**against the target `<NAME>_module_plugin`** (not the file name!):

```cmake
find_package(Qt6 REQUIRED COMPONENTS Sql)

logos_module(NAME todo SOURCES ...)

# CMake target = <NAME>_module_plugin
# Output file  = <NAME>_plugin.dylib
target_link_libraries(todo_module_plugin PRIVATE Qt6::Sql)
```

Using the file name (`todo_plugin`) fails with *"Cannot specify link
libraries for target 'todo_plugin' which is not built by this project."*

## Persisting state — SQLite in 5 lines

```cpp
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QDir>

// In initLogos():
const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
QDir().mkpath(dir);
QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "my-module");
db.setDatabaseName(dir + "/my-module.db");
db.open();
QSqlQuery(db).exec("CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, ...)");
```

Use a named connection (`"my-module"`) per plugin so handles don't clash.
Inspect the DB with `sqlite3 ~/Library/Application\ Support/*/my-module.db`.

## Emitting an event

```cpp
emit eventResponse("somethingHappened", QVariantList{ id, payload });
```

Subscribers receive `(eventName, args)` — UIs via `logos.onModuleEvent(...)`,
other modules via the SDK.

## Calling another module

In `metadata.json`:

```json
"dependencies": ["other_module"]
```

In `flake.nix` inputs (name must match the dependency's `metadata.json` name):

```nix
other_module.url = "github:someone/logos-other-module";
```

In C++:

```cpp
auto result = logosAPI->callModule("other_module", "someMethod",
                                   QVariantList{ arg1, arg2 });
```

## `metadata.json` — core

```json
{
  "name": "my_core",
  "version": "0.1.0",
  "type": "core",
  "category": "example",
  "description": "…",
  "main": "my_core_plugin",
  "dependencies": [],
  "nix": {
    "packages": { "build": [], "runtime": [] },
    "external_libraries": [],
    "cmake": { "find_packages": [], "extra_sources": [], "extra_include_dirs": [], "extra_link_libraries": [] }
  }
}
```

## Troubleshooting in one table

| Symptom                                    | Likely cause                                                                    |
| ------------------------------------------ | ------------------------------------------------------------------------------- |
| `LogosModule.cmake not found`              | Running `cmake` directly — use `nix build '.#lib'`.                             |
| `nix build` built the wrong thing silently | Missing quotes around `'.#lib'` — zsh treated `#` as a comment.                 |
| `lm methods` shows no methods              | Missing `Q_OBJECT`, `Q_INVOKABLE`, or IID mismatch between interface and plugin.|
| Install fails with "plugin not found"      | `name`/`main` in `metadata.json` disagree with CMake `NAME` or `name()` in C++. |
| `logoscore call` hangs                     | Daemon not running, or pointing at a different modules dir.                     |
| First build takes forever                  | Normal. Qt + SDK is ~2–3 GB. Nix caches everything after.                       |

## Calling another core module (`delivery_module` example)

Pattern for any cross-module RPC — `getClient` → `invokeRemoteMethod` →
`requestObject` + `onEvent` for signals.

```cpp
#include "logos_api_client.h"
#include "logos_object.h"

// Members:
LogosAPIClient* m_deliveryClient = nullptr;
LogosObject*    m_deliveryObject = nullptr;   // NOT QObject* — type mismatch

void Plugin::initLogos(LogosAPI* api) { logosAPI = api; }

void Plugin::wireUp() {
    m_deliveryClient = logosAPI->getClient("delivery_module");

    // Synchronous RPC. Returns QVariant — check .isValid() + .toBool().
    m_deliveryClient->invokeRemoteMethod("delivery_module", "createNode", cfgJson);

    // Register event handlers BEFORE start() — events fire during start
    m_deliveryObject = m_deliveryClient->requestObject("delivery_module");
    m_deliveryClient->onEvent(m_deliveryObject, "messageReceived",
        [this](const QString&, const QVariantList& data) { /* ... */ });

    m_deliveryClient->invokeRemoteMethod("delivery_module", "start");
    m_deliveryClient->invokeRemoteMethod("delivery_module", "subscribe", topic);

    // Publish
    m_deliveryClient->invokeRemoteMethod("delivery_module", "send", topic, payload);
}
```

Flake + metadata glue:

```nix
# flake.nix
inputs.delivery_module.url = "github:logos-co/logos-delivery-module";
```

```json
// metadata.json
"dependencies": ["delivery_module"]
```

## `delivery_module` event data layouts

```
messageReceived         [hash,     contentTopic, payload_base64, timestamp_ns]
messageSent             [requestId, messageHash, timestamp]
messagePropagated       [requestId, messageHash, timestamp]        // delivered to neighbors
messageError            [requestId, messageHash, error,    timestamp]
connectionStateChanged  [statusStr, timestamp]                      // "Connected" / "Connecting" / ...
```

`data[2]` on `messageReceived` is always base64 — single `QByteArray::fromBase64`
gets your payload back. Content topic format: `/<app>/<ver>/<sub>/<json|proto>`.

## `delivery_module` easy-mode config

```json
{ "logLevel": "INFO", "mode": "Core", "preset": "logos.dev" }
```

Preset = cluster 2, built-in bootstrap nodes, auto-sharded, mix enabled.
Override individual keys alongside `preset` to change anything
(`tcpPort`, `discv5UdpPort`, `logLevel`, `rlnRelay`, etc).

## Running two Basecamps on one Mac (same-machine multi-peer demo)

Ports collide (TCP 60000 + UDP 9000). Have your plugin read an env var:

```cpp
const int customPort = qEnvironmentVariableIntValue("POLLING_TCPPORT");
if (customPort > 0) {
    cfgObj["tcpPort"]       = customPort;
    cfgObj["discv5UdpPort"] = 9000 + (customPort - 60000);  // keep them paired
}
```

Launch two instances:

```bash
# A — defaults (60000 / 9000)
nohup open -W -n "/path/to/Basecamp.app" \
  --stdout /tmp/bc-A.log --stderr /tmp/bc-A.log > /dev/null 2>&1 &

# B — overridden (60001 / 9001)
nohup open -W -n "/path/to/Basecamp.app" \
  --stdout /tmp/bc-B.log --stderr /tmp/bc-B.log \
  --env POLLING_TCPPORT=60001 > /dev/null 2>&1 &
```

## Common delivery_module gotchas

- **`requestObject` returns `LogosObject*`**, not `QObject*`. Include
  `logos_object.h` or the compiler will reject `onEvent(m_obj, ...)`.
- **Status race.** `connectionStateChanged` fires *during* `start()`, not
  after. Set any "connecting" status BEFORE start, not after, or the event
  handler's "Connected" update gets clobbered.
- **Register event handlers BEFORE `start()`.** Events fired during start
  get dropped if no handler is registered yet.
- **Single base64 vs double base64.** Plain-JSON payloads need one
  `fromBase64` on receive. Protobuf payloads that you base64-encoded
  yourself on send need two.
- **First build is slow.** `logos-delivery-module`'s source closure pulls
  Nim + libp2p + zerokit + libpq. 15–30 min first time, seconds after.

## Log capture for Basecamp on macOS

```bash
# Relaunch with captured stderr (fresh, won't lose lines on detach)
pkill -9 -f "LogosBasecamp.bin"
sleep 1
nohup open -W -n "/path/to/Basecamp.app" \
  --stdout /tmp/bc.log --stderr /tmp/bc.log > /dev/null 2>&1 &

# Useful greps
grep 'Calling method "' /tmp/bc.log                        # every RPC from QML
grep 'DeliveryModulePlugin::' /tmp/bc.log                  # every delivery call
grep 'eventType.*message_' /tmp/bc.log                     # send lifecycle
grep 'dispatching event.*callback' /tmp/bc.log             # inbound events
```
