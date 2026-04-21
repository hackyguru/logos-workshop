# Building Logos Modules — A Live Coding Workshop

> **Three modules in one sitting.** A hello-world, a todo list, and a shared
> poll. By the end you will have built, packaged, installed and run your own
> `.lgx` files — with nothing more than Nix and a terminal.

This article is the companion to the live workshop. It is written so you can
either follow along during the session, or pick it up afterwards as a
self-contained tutorial.

---

## Table of contents

- [What is Logos?](#what-is-logos)
- [Modules vs plugins](#modules-vs-plugins)
- [What we'll build](#what-well-build)
- [Prerequisites](#prerequisites)
- [One-time setup](#one-time-setup)
- [From source to `.lgx` — how the build works](#from-source-to-lgx--how-the-build-works)
- [Part 1 — Hello World](#part-1--hello-world)
  - [1.1 Scaffold the project](#11-scaffold-the-project)
  - [1.2 A tour of the generated files](#12-a-tour-of-the-generated-files)
  - [1.3 Configure `metadata.json`](#13-configure-metadatajson)
  - [1.4 Write the UI](#14-write-the-ui)
  - [1.4.5 Give it an icon](#145-give-it-an-icon)
  - [1.5 Build the `.lgx`](#15-build-the-lgx)
  - [1.6 A peek inside the `.lgx`](#16-a-peek-inside-the-lgx)
  - [1.7 Install into Basecamp](#17-install-into-basecamp)
- [Part 2 — A Todo Module](#part-2--a-todo-module)
  - [2.1 Scaffold a core module](#21-scaffold-a-core-module)
  - [2.2 Design the interface](#22-design-the-interface)
  - [2.3 Implement in-memory storage](#23-implement-in-memory-storage)
  - [2.4 Emitting events](#24-emitting-events)
  - [2.5 Build and package](#25-build-and-package)
  - [2.6 Drive it headlessly with `logoscore`](#26-drive-it-headlessly-with-logoscore)
  - [2.7 Install it into Basecamp](#27-install-it-into-basecamp)
  - [2.8 Making it persist — swap in SQLite](#28-making-it-persist--swap-in-sqlite)
- [Part 3 — A Voting Module (with `logos-delivery`)](#part-3--a-voting-module-with-logos-delivery)
  - [3.1 What we're building](#31-what-were-building)
  - [3.2 A tour of `delivery_module`](#32-a-tour-of-delivery_module)
  - [3.3 Scaffold the voting core](#33-scaffold-the-voting-core)
  - [3.4 Design the interface](#34-design-the-interface)
  - [3.5 State and voter identity](#35-state-and-voter-identity)
  - [3.6 Wiring up `delivery_module`](#36-wiring-up-delivery_module)
  - [3.7 The status-race gotcha](#37-the-status-race-gotcha)
  - [3.8 Poll lifecycle: open, close, vote](#38-poll-lifecycle-open-close-vote)
  - [3.9 Receiving votes](#39-receiving-votes)
  - [3.10 Build, install, smoke test](#310-build-install-smoke-test)
  - [3.11 Proving multi-peer via the log](#311-proving-multi-peer-via-the-log)
  - [3.12 Two instances on one machine](#312-two-instances-on-one-machine)
  - [3.13 The voting UI](#313-the-voting-ui)
- [Wrap-up](#wrap-up)
- [Appendix — Troubleshooting](#appendix--troubleshooting)

---

## What is Logos?

**Logos** is a modular desktop application platform built in C++ on top of
Qt 6. Instead of shipping one monolithic app, Logos apps are made of many
small **modules** (plugins) that are loaded dynamically at runtime and
communicate through an IPC layer.

Three ideas carry most of the weight:

1. **A module is a Qt plugin.** You write a C++ class, mark some methods
   `Q_INVOKABLE`, and compile it into a shared library (`.so` / `.dylib`).
2. **`.lgx` is the package format.** A `.lgx` file bundles that shared
   library, its metadata, and any external libraries into a single installable
   artifact.
3. **Modules talk to each other via `LogosAPI`.** Instead of linking against
   one another, modules discover each other at runtime and call methods over
   Qt Remote Objects — so modules can live in separate processes and even
   separate languages down the road.

For this workshop you can ignore almost all of that machinery. We will write
three modules and let the tooling handle every other concern.

## Modules vs plugins

Logos uses two words that look similar and are easy to confuse. They aren't
interchangeable — they refer to different kinds of thing in different
contexts.

**"Module" as the umbrella term.** Every single thing you build with
`logos-module-builder` and package as a `.lgx` file is a *module*. The Nix
function is `mkLogosModule` / `mkLogosQmlModule`. The CMake macro is
`logos_module()`. Whenever a doc says "build a module", it means that
general thing — any unit of code that becomes a `.lgx`.

**Inside Basecamp, the word splits into two.** When a `.lgx` is installed,
Basecamp puts it into one of two sibling directories based on its `type`,
and the two directories are named differently on disk:

| Installed dir | Contains modules of type       | Built with         | What they do                                        |
| ------------- | ------------------------------ | ------------------ | --------------------------------------------------- |
| **`modules/`** | `core`                        | C++                | Backend-only. Expose methods. No visual UI.         |
| **`plugins/`** | `ui_qml`, `ui_qml_backend`    | QML (+ C++ optional) | Render a tab in the sidebar. Call into core modules. |

So in Basecamp's filesystem:

- **A "module"** is a backend C++ plugin that exposes `Q_INVOKABLE` methods.
  It has no tab, no UI — it sits in `modules/` waiting for callers.
- **A "plugin"** is a UI component that Basecamp shows as a sidebar tab. It
  is written in QML (optionally with a C++ backend running in its own
  `ui-host` process), and lives in `plugins/`.

The two languages correspond directly to the two templates:

- **`ui-qml` template** — pure QML. One `.qml` file, no compile step. Cannot
  expose methods to other code; it only *consumes* them.
- **`ui-qml-backend` template** — QML frontend + C++ backend. The backend
  compiles to a shared library and runs process-isolated via Qt Remote
  Objects; the QML talks to it through a generated typed replica.
- **default / core template** — C++ only. Compiles to a shared library. No
  UI. Exposes `Q_INVOKABLE` methods to anyone who asks.

In this workshop, Part 1 is a pure-QML **plugin**, Part 2 is a C++ **core
module** with no UI of its own, and Part 3 combines both.

When you see "module" in passing without a qualifier, it usually means "any
`.lgx` package, regardless of type." When you see "plugin" in the Basecamp
UI or filesystem, it specifically means a `ui_qml*`-type module.

## What we'll build

| Part | Module        | Type     | What it does                                              |
| ---- | ------------- | -------- | --------------------------------------------------------- |
| 1    | `hello_world` | `ui_qml` | A QML-only UI tab. Says hi, no backend.                   |
| 2    | `todo`        | `core` + `ui_qml` | In-memory todo list with add / list / complete / remove, with a QML UI on top. |
| 3    | `voting`      | `core` + `ui_qml` | Yes/no polls shared across peers via `logos-delivery` pub/sub. |

Each part ends with an `.lgx` package you install into Basecamp and actually
see running. Core modules (Part 2 onwards) are C++; UI modules are QML-only,
no compile step.

## Prerequisites

- **Nix** with flakes enabled — this is the only build tool you need.
- **git** — flakes require a git repo.
- Comfort with a terminal. You do **not** need prior Qt, CMake or C++ plugin
  experience; we will point at what each piece does as we go.

Install Nix from [nixos.org/download](https://nixos.org/download.html), then:

```bash
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
```

Verify:

```bash
nix --version
nix flake --help >/dev/null && echo "flakes OK"
```

## One-time setup

Two things to have in hand before the workshop:

**1. A working folder:**

```bash
mkdir -p ~/logos-workshop && cd ~/logos-workshop
```

**2. Basecamp.** This is the desktop app we install our modules into. Grab
the latest release for your platform from
[logos-basecamp releases](https://github.com/logos-co/logos-basecamp/releases)
(or an earlier prebuilt such as
[nicholasgasior's v0.1.1 AppImage](https://github.com/nicholasgasior/logos-basecamp/releases/tag/v0.1.1))
and confirm it launches.

**Optional — the CLI tools.** You'll need these from Part 2 onwards when we
start working with `core` (backend) modules:

```bash
# The plugin inspector — reads Qt meta-object info out of compiled plugins
nix build 'github:logos-co/logos-module#lm' --out-link ./lm

# The headless module runtime — runs core modules without a UI
nix build 'github:logos-co/logos-logoscore-cli' --out-link ./logos

# The Logos package manager — install/list/remove .lgx files on the CLI
nix build 'github:logos-co/logos-package-manager#cli' --out-link ./pm
```

Part 1 only needs Basecamp, so skip these if you want to get to something
visible faster.

---

## From source to `.lgx` — how the build works

Before we start, take a minute to understand what actually happens when you
run `nix build '.#lgx-portable'`. The magic isn't load-bearing, but knowing
the stages makes errors readable and configuration choices obvious.

### The files in every module repo

These are all the files you ever have to touch. Every module has some
subset of them.

| File / directory   | Role                                                                                                                                                                                                                                                                            | In a `ui_qml` module? | In a `core` module? |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- | ------------------- |
| **`flake.nix`**    | Nix build entry point. One input (`logos-module-builder`) and one call — either `mkLogosQmlModule` (UI) or `mkLogosModule` (core). Declares other module dependencies as flake inputs when needed.                                                                              | ✓                     | ✓                   |
| **`flake.lock`**   | Pinned versions of every flake input. Auto-generated by `nix flake update`. Check this in — it's how you get reproducible builds.                                                                                                                                               | ✓                     | ✓                   |
| **`metadata.json`**| The single source of truth. `name`, `version`, `type`, `category`, `description`, `icon`. For UI modules it points at a `view` (QML entry file); for core modules at a `main` (the plugin binary's base name). Also carries the `nix.*` block that configures the build itself. | ✓                     | ✓                   |
| **`icons/*.png`**  | Sidebar icon(s). Referenced from `metadata.json` as `"icon": "icons/<name>.png"`. The builder flattens the path into the installed manifest. Optional, but makes the module findable in Basecamp.                                                                               | usually               | rare                |
| **`Main.qml`**     | QML entry point. Free-form — declare any Qt Quick scene. `view` in `metadata.json` must point at this file's name.                                                                                                                                                              | ✓                     | ✗                   |
| **Additional `.qml` files, images, fonts** | Anything `Main.qml` imports or references. Bundled with the module.                                                                                                                                                                                                             | optional              | ✗                   |
| **`CMakeLists.txt`**| Build recipe for core modules. Includes `LogosModule.cmake` (shipped by the builder) and calls the `logos_module(NAME ... SOURCES ...)` macro. That one macro sets up the Qt plugin target, links the SDK, invokes moc, generates interop code and emits the install rules.    | ✗                     | ✓                   |
| **`src/*_interface.h`** | Pure-virtual interface declaring your module's `Q_INVOKABLE` methods. Inherits from `PluginInterface` (SDK). Declares the interface IID used by `Q_PLUGIN_METADATA`.                                                                                                            | ✗                     | ✓                   |
| **`src/*_plugin.h`**| Concrete plugin class. Inherits from `QObject` + the interface. Three Qt macros: `Q_OBJECT`, `Q_PLUGIN_METADATA(IID ... FILE "metadata.json")`, `Q_INTERFACES(...)`.                                                                                                            | ✗                     | ✓                   |
| **`src/*_plugin.cpp`** | The method implementations and `initLogos()` wiring.                                                                                                                                                                                                                          | ✗                     | ✓                   |
| **`lib/` (optional)** | Drop-in directory for pre-built or source-built C/C++ libraries the module wraps (e.g. a `.so`/`.dylib` plus its header). Referenced from `metadata.json`'s `nix.external_libraries` block.                                                                                    | ✗                     | optional            |
| **`.gitignore`**   | Keeps `result`, `result-*`, and `build/` out of git.                                                                                                                                                                                                                            | ✓                     | ✓                   |
| **`result-*/`**    | Build output symlinks into `/nix/store`. Never edit.                                                                                                                                                                                                                            | generated             | generated           |

### The build pipeline

`nix build '.#lgx-portable'` kicks off this chain:

1. **Nix fetches inputs.** `logos-module-builder` and everything it
   transitively depends on — Qt, the Logos SDK (`logos-cpp-sdk`), the SDK
   code generator, `nix-bundle-lgx`, `nixpkgs`. First build downloads ~2–3 GB
   and takes 5–15 min; after that, everything is cached.

2. **The builder reads `metadata.json`.** It uses the `nix.*` block to
   decide which Qt modules, external libraries and extra CMake settings
   apply. For a `ui_qml` module, this is mostly a no-op — there's nothing to
   compile. For a `core` module, this drives the CMake invocation.

3. **(Core only) CMake configure + compile.** The builder generates any
   required interop headers from your interface, then runs CMake. CMake
   includes `LogosModule.cmake`, which wires up Qt, moc, the SDK, and the
   plugin target. You get a single `lib<name>_plugin.so` / `.dylib` as
   output.

4. **(UI only) QML staging.** No compile — the builder simply collects
   `Main.qml` and any other assets into the module's install directory.

5. **Install.** The builder copies the built artefacts (`.dylib`, `.qml`,
   icons, metadata) into a Nix-store install directory with the layout
   Basecamp expects.

6. **Bundle into `.lgx`.** `nix-bundle-lgx` reads the install dir, generates
   a `manifest.json` (flattening paths like `icons/foo.png` → `foo.png`),
   computes SHA-256 hashes for integrity, wraps everything into a variant
   directory (`darwin-arm64`, `linux-amd64`, etc.), and tars the whole thing
   up with gzip. That tarball, renamed `.lgx`, is your output.

### `.#lgx` vs `.#lgx-portable`

Two flavours, differing only in how the binaries reference their
dependencies:

- **`.#lgx`** — paths inside the bundle still point to `/nix/store`.
  Fast to build, works on the machine that built it. Variant name has a
  `-dev` suffix (e.g. `darwin-arm64-dev`). Released Basecamp **ignores**
  dev variants.
- **`.#lgx-portable`** — dependencies are rewritten so the bundle is
  self-contained and runs on any machine with the same OS + architecture.
  Slightly slower to build. Variant name has no suffix (e.g.
  `darwin-arm64`). This is what you install into released Basecamp, ship
  to other people, upload to a registry.

Use `.#lgx-portable` for anything you want to see inside a distributed
Basecamp — which is basically everything in this workshop.

### Inside a `.lgx` file

```
manifest.json                    — top-level metadata + SHA-256 hashes of every variant
variants/
  darwin-arm64/                  — one directory per supported platform
    metadata.json                — the module's own metadata (per-variant copy)
    manifest.json                — same, with flattened icon paths and variant-specific fields
    Main.qml                     — ui_qml: the entry view
    <name>_plugin.dylib          — core: compiled plugin
    <icon>.png                   — optional sidebar icon (flattened from icons/)
    icons/<icon>.png             — same icon at its original path (kept for reference)
```

Feel free to `tar -tzf your-file.lgx` at any point to peek inside.

---

## Part 1 — Hello World

**Goal:** the smallest possible Logos module — one that shows up as a tab in
Basecamp. We use the `ui_qml` template: QML only, no C++, no compile step.
The focus is entirely on the scaffold → build → package → import loop so that
by the time we reach Part 2, the mechanics feel routine.

### 1.1 Scaffold the project

From `~/logos-workshop`:

```bash
mkdir hello_world && cd hello_world
nix flake init -t github:logos-co/logos-module-builder#ui-qml
```

The `ui-qml` template drops a ready-to-build skeleton — **three files**, no
`src/`, no `CMakeLists.txt`:

```
hello_world/
├── flake.nix          # Nix build config
├── metadata.json      # The single source of truth
└── Main.qml           # Your UI, in one file
```

If you want to skip the typing, the finished version of this part lives in
[`part1-hello-world/`](part1-hello-world/) — copy it into `hello_world/` and
move straight to the build step.

### 1.2 A tour of the generated files

Before editing anything, look at each file. These three are 100% of a
QML-only plugin (see [the full file reference above](#the-files-in-every-module-repo)
for the exhaustive table including core-module files).

- **`flake.nix`** — Nix build entry. One input (`logos-module-builder`),
  one call: `mkLogosQmlModule`. You edit this only to add dependencies on
  other modules.
- **`metadata.json`** — the single source of truth. For this part the
  fields that matter are:

  | Field         | Purpose                                                          |
  | ------------- | ---------------------------------------------------------------- |
  | `name`        | Module name. Must be a valid C identifier.                       |
  | `type`        | `ui_qml` — makes Basecamp install it into `plugins/`.            |
  | `view`        | Entry-point QML file relative to the repo root.                  |
  | `icon`        | Path to a PNG icon. Gets flattened by the builder. See §1.4.5.   |
  | `category`    | Free-form grouping. Shown in package managers.                   |
  | `description` | One-liner users see.                                             |

- **`Main.qml`** — the UI. A single QML file Basecamp loads and displays
  as a tab. That's the whole plugin: no headers, no build rules, no Qt
  macros.

> Core (backend) modules have a very different shape — C++ Qt plugins with
> `CMakeLists.txt` and a `src/` directory. We build one in Part 2. For now,
> revel in the fact that "ui_qml plugin" really does mean "one QML file plus
> two pieces of metadata".

### 1.3 Configure `metadata.json`

Replace the generated `metadata.json` with:

```json
{
  "name": "hello_world",
  "version": "0.1.0",
  "type": "ui_qml",
  "category": "example",
  "description": "Our very first Logos module — says hi from QML",
  "view": "Main.qml",
  "icon": null,
  "dependencies": [],

  "nix": {
    "packages": { "build": [], "runtime": [] },
    "external_libraries": [],
    "cmake": {
      "find_packages": [],
      "extra_sources": [],
      "extra_include_dirs": [],
      "extra_link_libraries": []
    }
  }
}
```

Only three fields really matter for this part: `name`, `type: "ui_qml"`, and
`view: "Main.qml"`. The `nix` block is boilerplate — leave it as is.

### 1.4 Write the UI

Replace the generated `Main.qml` with something slightly more fun than a
static greeting — a text field plus a button:

```qml
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    width: 480
    height: 320

    property string greetingText: "Hello, world!"

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 16
        width: 360

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: greetingText
            font.pixelSize: 22
        }

        TextField {
            id: nameField
            Layout.fillWidth: true
            placeholderText: "Your name"
            onAccepted: greetButton.clicked()
        }

        Button {
            id: greetButton
            Layout.alignment: Qt.AlignHCenter
            text: "Say hi"
            onClicked: {
                const name = nameField.text.trim()
                greetingText = name.length === 0
                    ? "Hello, world!"
                    : "Hello, " + name + "! Welcome to Logos."
            }
        }
    }
}
```

Three things to notice in the QML, if you haven't written QML before:

- **Declarative.** You describe the scene — `Item`, `ColumnLayout`, `Text`,
  `TextField`, `Button` — and QML keeps it alive. No render loop to write.
- **Properties are reactive.** `greetingText` is a property; anything that
  binds to it (`text: greetingText`) updates automatically when it changes.
- **`onSomething: { … }` is an event handler.** `onClicked` runs when the
  button is pressed; `onAccepted` runs when Return is pressed in a `TextField`.

That is the whole UI module. No C++, no compile step, no Qt meta-object
macros.

### 1.4.5 Give it an icon

By default your module shows up in Basecamp's sidebar as a text-only tab. A
PNG next to the name makes it much more discoverable — same as the
built-in `counter`, `package_manager_ui` and friends.

**Add an `icons/` directory with a PNG** (128×128 is a good size, though
Basecamp will scale whatever you give it):

```bash
mkdir icons
# put your icon at icons/hello_world.png
```

**Point `metadata.json` at it:**

```json
"icon": "icons/hello_world.png",
```

That's all. When you rebuild with `nix build '.#lgx-portable'`, the builder
does two things:

- Copies the icon into each variant directory (flattens `icons/hello_world.png`
  → `hello_world.png`).
- Rewrites the manifest's `icon` field to the flattened name.

You can verify with `tar -tzf result-portable/*.lgx` — you should see both
`variants/<platform>/icons/hello_world.png` and the flattened
`variants/<platform>/hello_world.png`. After reinstalling and restarting
Basecamp, the tab picks up the icon.

> **Don't have an icon handy?** Any 128×128 PNG works. One quick option is a
> one-off Python + Pillow script that renders two letters on a coloured
> rounded square — the one in `part1-hello-world/icons/hello_world.png` was
> made that way in ~20 lines. SVG is not currently supported by Basecamp's
> sidebar; stick to PNG.

### 1.5 Build the `.lgx`

Flakes require a git repo. One-time housekeeping:

```bash
cat > .gitignore <<'EOF'
result
result-*
build/
EOF

git init -q
git add -A
nix flake update
git add flake.lock
```

Now package:

```bash
nix build '.#lgx-portable' --out-link result-portable
```

> **Quoting matters.** `'.#lgx-portable'` with single quotes — zsh otherwise
> reads the `#` as a comment and builds the default attribute instead, which
> leaves you debugging a correct build for the wrong target.

> **`.#lgx` vs `.#lgx-portable`.** `'.#lgx'` produces a **local** package
> whose paths still point at `/nix/store` — fine for a locally-built
> Basecamp but not for a released/installed one. `'.#lgx-portable'` produces
> a self-contained package that works with any Basecamp, so we default to
> that for the workshop.

First build fetches Qt + the Logos SDK (5–15 minutes). Subsequent builds are
seconds — Nix caches everything.

When it's done:

```bash
ls -la result-portable/
# → logos-hello_world-module.lgx
```

### 1.6 A peek inside the `.lgx`

An `.lgx` is just a gzipped tarball. Let's see what our packager produced:

```bash
tar -tzf result-portable/*.lgx
```

```
manifest.json
variants/
variants/darwin-arm64/
variants/darwin-arm64/Main.qml
variants/darwin-arm64/metadata.json
```

One manifest, one platform variant, two files in it. The variant name
(`darwin-arm64` here) is how Basecamp knows this package is compatible with
your machine. The **portable** build produces variants like `darwin-arm64` /
`linux-amd64`; the local build would produce `darwin-arm64-dev` instead,
which release Basecamp ignores — that's why we pick `.#lgx-portable` for
distribution.

### 1.7 Install into Basecamp

Two ways — use the one that works for you.

**Option A — Basecamp's GUI.** Open Basecamp, go to **Modules → Install LGX
Package**, and select `result-portable/logos-hello_world-module.lgx`. A new
**hello_world** tab appears in the sidebar.

**Option B — Manual install.** Useful if the GUI import path fails (or
Basecamp silently doesn't pick the package up). Drop the files into
Basecamp's module directory directly:

```bash
# macOS
BASECAMP_DIR="$HOME/Library/Application Support/Logos/LogosBasecamp"

# Linux
# BASECAMP_DIR="$HOME/.local/share/Logos/LogosBasecamp"

mkdir -p "$BASECAMP_DIR/plugins/hello_world" /tmp/hw-lgx
tar xzf result-portable/*.lgx -C /tmp/hw-lgx
cp /tmp/hw-lgx/variants/darwin-arm64/* "$BASECAMP_DIR/plugins/hello_world/"
cp /tmp/hw-lgx/manifest.json            "$BASECAMP_DIR/plugins/hello_world/"
echo "darwin-arm64" >                    "$BASECAMP_DIR/plugins/hello_world/variant"
```

> **`modules/` vs `plugins/`.** Basecamp stores `core` modules under
> `modules/` and `ui_qml` modules under `plugins/`. We're installing a UI
> module, so it goes in `plugins/`. Same pattern for every UI module in the
> workshop.

Restart Basecamp. The **hello_world** tab is now in the sidebar — type your
name, hit **Say hi**, done.

That's a full Logos UI module end-to-end — scaffolded, packaged, and
installed. Everything else in the workshop is a variation on this loop.

---

## Part 2 — A Todo Module

Part 1 was pure QML — a UI module with no backend. Most real features have a
backend, and that is a different shape: a `core` module written in C++ that
exposes `Q_INVOKABLE` methods other modules can call. We will build one
(`todo`) and then put a QML UI on top of it that uses
`logos.callModule(...)` to talk to it.

The todo list is in-memory only — just a `QVector` behind the interface —
so we can keep the focus on the module mechanics, not on SQL or
filesystems.

The finished version of the core module lives in [`part2-todo/`](part2-todo/).

### 2.1 Scaffold a core module

This time we use the **`default`** template, not the `ui-qml` one. That
gives us a C++ plugin skeleton with a `src/` directory and a
`CMakeLists.txt`:

```bash
cd ~/logos-workshop
mkdir todo && cd todo
nix flake init -t github:logos-co/logos-module-builder
```

Generated structure:

```
todo/
├── flake.nix           ← same idea as Part 1, but calls mkLogosModule (not mkLogosQmlModule)
├── metadata.json       ← type: "core", main: "<plugin binary name>"
├── CMakeLists.txt      ← builds the C++ Qt plugin
└── src/
    ├── minimal_interface.h    ← pure-virtual API (Q_INVOKABLE methods)
    ├── minimal_plugin.h       ← the class declaration + Qt plugin macros
    └── minimal_plugin.cpp     ← the method implementations
```

We will rename the `minimal_*` sources to `todo_*`. The roles of the three
`src/` files are the big new idea here:

- **`todo_interface.h`** — a *pure-virtual* C++ class. It declares
  what your module exposes. Other modules include this header (generated
  for them by the SDK) and see your API.
- **`todo_plugin.h`** — the concrete class that actually implements the
  interface. Inherits from `QObject` (for Qt's signal/slot machinery) and
  your interface. Three macros make it a real plugin:
  - `Q_OBJECT` — Qt meta-object support.
  - `Q_PLUGIN_METADATA(IID ... FILE "metadata.json")` — declares this class
    as a Qt plugin and embeds the metadata file.
  - `Q_INTERFACES(...)` — registers which interfaces the class implements.
- **`todo_plugin.cpp`** — the method bodies plus `initLogos(LogosAPI*)`,
  the one function the Logos host calls when loading your module.

The `CMakeLists.txt` is usually three lines of interesting content — a
`logos_module(NAME ... SOURCES ...)` macro call that expands into the Qt
plugin target, linked SDK libraries, moc invocation, and install rules.
Everything else in the file is boilerplate you leave as-is.

### 2.2 Design the interface

This is where you spend most of your design time on a real module. Pick your
method set, pick your types. For a todo list:

```cpp
// src/todo_interface.h
#ifndef TODO_INTERFACE_H
#define TODO_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

class TodoInterface : public PluginInterface
{
public:
    virtual ~TodoInterface() = default;

    Q_INVOKABLE virtual int     addTodo(const QString& title) = 0;
    Q_INVOKABLE virtual QString listTodos() = 0;
    Q_INVOKABLE virtual bool    completeTodo(int id) = 0;
    Q_INVOKABLE virtual bool    removeTodo(int id) = 0;
    Q_INVOKABLE virtual int     clearAll() = 0;
};

#define TodoInterface_iid "org.logos.TodoInterface"
Q_DECLARE_INTERFACE(TodoInterface, TodoInterface_iid)

#endif
```

Notes on the shape:

- `addTodo` returns an `int` (the new id). Every item gets a monotonically
  increasing id; the caller uses that to reference it later.
- `listTodos` returns a `QString` — specifically, a JSON array we will
  build with `QJsonDocument`. Returning JSON strings is a common pattern
  because it keeps the IPC surface simple (string in, string out) while still
  carrying structured data.
- `completeTodo` and `removeTodo` return `bool` so the caller can distinguish
  "id didn't exist" from "done".
- `clearAll` returns the number of items removed — a nicer UX than a silent
  `void`.

### 2.3 Implement in-memory storage

`src/todo_plugin.h`:

```cpp
#ifndef TODO_PLUGIN_H
#define TODO_PLUGIN_H

#include <QObject>
#include <QString>
#include <QVector>
#include "todo_interface.h"
#include "logos_api.h"
#include "logos_sdk.h"

struct TodoItem {
    int     id;
    QString title;
    bool    completed;
};

class TodoPlugin : public QObject, public TodoInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID TodoInterface_iid FILE "metadata.json")
    Q_INTERFACES(TodoInterface PluginInterface)

public:
    explicit TodoPlugin(QObject* parent = nullptr);
    ~TodoPlugin() override;

    QString name() const override { return "todo"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    Q_INVOKABLE int     addTodo(const QString& title) override;
    Q_INVOKABLE QString listTodos() override;
    Q_INVOKABLE bool    completeTodo(int id) override;
    Q_INVOKABLE bool    removeTodo(int id) override;
    Q_INVOKABLE int     clearAll() override;

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    QVector<TodoItem> m_todos;
    int               m_nextId = 1;
};

#endif
```

`src/todo_plugin.cpp`:

```cpp
#include "todo_plugin.h"
#include "logos_api.h"
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

TodoPlugin::TodoPlugin(QObject* parent) : QObject(parent) {}
TodoPlugin::~TodoPlugin() = default;

void TodoPlugin::initLogos(LogosAPI* api) { logosAPI = api; }

int TodoPlugin::addTodo(const QString& title)
{
    const int id = m_nextId++;
    m_todos.append(TodoItem{ id, title, false });
    emit eventResponse("todoAdded", QVariantList{ id, title });
    return id;
}

QString TodoPlugin::listTodos()
{
    QJsonArray arr;
    for (const auto& t : m_todos) {
        QJsonObject obj;
        obj["id"]        = t.id;
        obj["title"]     = t.title;
        obj["completed"] = t.completed;
        arr.append(obj);
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

bool TodoPlugin::completeTodo(int id)
{
    for (auto& t : m_todos) {
        if (t.id == id) { t.completed = true;
                          emit eventResponse("todoCompleted", { id });
                          return true; }
    }
    return false;
}

bool TodoPlugin::removeTodo(int id)
{
    for (int i = 0; i < m_todos.size(); ++i) {
        if (m_todos[i].id == id) { m_todos.remove(i);
                                   emit eventResponse("todoRemoved", { id });
                                   return true; }
    }
    return false;
}

int TodoPlugin::clearAll()
{
    const int n = m_todos.size();
    m_todos.clear();
    emit eventResponse("todosCleared", { n });
    return n;
}
```

### 2.4 Emitting events

Notice how every mutating method emits `eventResponse` with a payload. This
is how UIs stay in sync without polling:

- `"todoAdded"` → `[id, title]`
- `"todoCompleted"` → `[id]`
- `"todoRemoved"` → `[id]`
- `"todosCleared"` → `[count]`

Any subscriber — another module, a QML UI, a test — can listen to these and
react. For the workshop we don't subscribe to them, but having them in place
from day one is cheap and pays off as soon as a UI gets involved.

### 2.5 Build and package

```bash
# Update metadata.json to: name=todo, main=todo_plugin, type=core
# Update CMakeLists.txt to point at the new source names

git init -q && git add -A
nix flake update && git add flake.lock

# Compiled plugin (.so/.dylib) — sanity check
nix build '.#lib'

# Portable .lgx for Basecamp (or for headless logoscore testing)
nix build '.#lgx-portable' --out-link result-portable
```

### 2.6 Drive it headlessly with `logoscore`

Before putting a UI on top, we can talk to the backend directly from the
terminal. This is invaluable while debugging — no UI moving parts.

```bash
mkdir -p modules
../pm/bin/lgpm --modules-dir ./modules install --file result-portable/*.lgx

../logos/bin/logoscore -D -m ./modules &

../logos/bin/logoscore call todo addTodo "Ship the workshop"
# → 1
../logos/bin/logoscore call todo addTodo "Record the video"
# → 2
../logos/bin/logoscore call todo listTodos
# → [{"completed":false,"id":1,"title":"Ship the workshop"}, ...]
../logos/bin/logoscore call todo completeTodo 1
# → true
../logos/bin/logoscore call todo removeTodo 99
# → false
../logos/bin/logoscore call todo clearAll
# → 2

../logos/bin/logoscore stop
```

Every method we defined on the interface is callable with
`logoscore call <module> <method> <args...>` — that is the whole model.

### 2.7 Install it into Basecamp

Core modules go in `modules/` (not `plugins/`). Via the GUI, use **Modules →
Install LGX Package** as before. Manually:

```bash
BASECAMP_DIR="$HOME/Library/Application Support/Logos/LogosBasecamp"  # macOS
# BASECAMP_DIR="$HOME/.local/share/Logos/LogosBasecamp"               # Linux

mkdir -p "$BASECAMP_DIR/modules/todo" /tmp/todo-lgx
tar xzf result-portable/*.lgx -C /tmp/todo-lgx
cp /tmp/todo-lgx/variants/darwin-arm64/* "$BASECAMP_DIR/modules/todo/"
cp /tmp/todo-lgx/manifest.json            "$BASECAMP_DIR/modules/todo/"
echo "darwin-arm64" >                     "$BASECAMP_DIR/modules/todo/variant"
```

After restart, the `todo` core module is loaded by Basecamp but has no UI of
its own — it just sits there waiting for callers. Next step: build a
`todo_ui` QML module that calls it. We will add that as **Part 2.5** in the
live session.

### 2.8 Making it persist — swap in SQLite

Our todos disappear on restart because they live in a `QVector` that dies
with the process. Real modules persist their state — we will keep
everything else identical and only replace the storage layer.

Logos core modules are full Qt plugins, so **any Qt module is fair game**.
Qt ships with a SQLite driver out of the box under `Qt6::Sql`; no external
dependencies, no server to run, just a file on disk. That is exactly what
we want for a single-user todo list.

#### Schema

One table. The only column worth thinking about is `created_at` — sorting
by insertion order is what a user expects.

```sql
CREATE TABLE IF NOT EXISTS todos (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  title      TEXT    NOT NULL,
  completed  INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)
```

`AUTOINCREMENT` lets SQLite assign ids, so the plugin no longer needs its
own `m_nextId` counter.

#### Linking `Qt6::Sql` into the build

`logos_module(...)` sets up the Qt plugin target but only links the modules
the SDK itself needs. To add Sql, tell CMake we want it and link it into
the generated plugin target:

```cmake
find_package(Qt6 REQUIRED COMPONENTS Sql)

logos_module(
    NAME todo
    SOURCES
        src/todo_interface.h
        src/todo_plugin.h
        src/todo_plugin.cpp
)

# logos_module() names the CMake target `<NAME>_module_plugin` (output file
# is `<NAME>_plugin.dylib`). That mismatch is intentional — we link the
# target, Basecamp loads the file.
target_link_libraries(todo_module_plugin PRIVATE Qt6::Sql)
```

> **Name trap.** The CMake *target* is `todo_module_plugin`, the compiled
> *file* is `todo_plugin.dylib`. Using the file name in
> `target_link_libraries` gives the error *"Cannot specify link libraries
> for target 'todo_plugin' which is not built by this project."* Always
> target `<NAME>_module_plugin` for `target_link_libraries`, `target_sources`,
> etc.

Same recipe works for any other Qt module — `Qt6::Network`,
`Qt6::Concurrent`, `Qt6::WebSockets`, whatever your plugin needs.

#### Open the database when the module loads

`initLogos()` is our one-shot init hook. We already use it to store the
`LogosAPI` pointer; now we also open SQLite there. The database file goes
under `QStandardPaths::AppDataLocation` — on macOS this is a writable dir
inside `~/Library/Application Support/...` that survives restarts.

```cpp
// src/todo_plugin.h — only the differences vs the in-memory version
class TodoPlugin : public QObject, public TodoInterface {
    // ... (name, version, Q_INVOKABLE methods all unchanged)

private:
    bool openDatabase();
    // No more `m_todos` or `m_nextId` — the DB is the storage.
};
```

```cpp
// src/todo_plugin.cpp — the new additions
#include <QDateTime>
#include <QDir>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QVariant>

static constexpr char CONNECTION[] = "logos-workshop-todo";

TodoPlugin::~TodoPlugin()
{
    if (QSqlDatabase::contains(CONNECTION)) {
        { QSqlDatabase db = QSqlDatabase::database(CONNECTION);
          if (db.isOpen()) db.close(); }
        QSqlDatabase::removeDatabase(CONNECTION);
    }
}

void TodoPlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    if (!openDatabase()) {
        qWarning() << "TodoPlugin: database init failed — todos won't persist";
    }
}

bool TodoPlugin::openDatabase()
{
    const QString dataDir =
        QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dataDir);
    const QString dbPath = dataDir + "/todo.db";

    QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", CONNECTION);
    db.setDatabaseName(dbPath);
    if (!db.open()) {
        qWarning() << "TodoPlugin: cannot open" << dbPath << db.lastError();
        return false;
    }

    QSqlQuery q(db);
    return q.exec("CREATE TABLE IF NOT EXISTS todos ("
                  "  id         INTEGER PRIMARY KEY AUTOINCREMENT,"
                  "  title      TEXT    NOT NULL,"
                  "  completed  INTEGER NOT NULL DEFAULT 0,"
                  "  created_at INTEGER NOT NULL"
                  ")");
}
```

Two things worth calling out:

- **Named connection.** `QSqlDatabase::addDatabase("QSQLITE", CONNECTION)` —
  if the host process opens other databases elsewhere, the unique
  `CONNECTION` string keeps our handle separate. Standard Qt SQL hygiene.
- **Destructor cleanup.** Closing and removing the connection on unload
  avoids a noisy "connection still in use" warning when the host tears the
  plugin down.

#### Rewrite each method as SQL

Every method we wrote in §2.3 becomes a prepared statement. The public
signatures and event emissions don't change — only the body does. That is
the whole point of the interface/implementation split.

```cpp
int TodoPlugin::addTodo(const QString& title)
{
    QSqlDatabase db = QSqlDatabase::database(CONNECTION);
    QSqlQuery q(db);
    q.prepare("INSERT INTO todos (title, completed, created_at) VALUES (?, 0, ?)");
    q.addBindValue(title);
    q.addBindValue(QDateTime::currentSecsSinceEpoch());
    if (!q.exec()) {
        qWarning() << "addTodo failed:" << q.lastError();
        return -1;
    }
    const int id = q.lastInsertId().toInt();
    emit eventResponse("todoAdded", QVariantList{ id, title });
    return id;
}

QString TodoPlugin::listTodos()
{
    QJsonArray arr;
    QSqlDatabase db = QSqlDatabase::database(CONNECTION);
    QSqlQuery q(db);
    if (q.exec("SELECT id, title, completed FROM todos ORDER BY created_at DESC")) {
        while (q.next()) {
            QJsonObject obj;
            obj["id"]        = q.value(0).toInt();
            obj["title"]     = q.value(1).toString();
            obj["completed"] = q.value(2).toBool();
            arr.append(obj);
        }
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

bool TodoPlugin::completeTodo(int id)
{
    QSqlDatabase db = QSqlDatabase::database(CONNECTION);
    QSqlQuery q(db);
    q.prepare("UPDATE todos SET completed = 1 WHERE id = ?");
    q.addBindValue(id);
    if (!q.exec() || q.numRowsAffected() == 0) return false;
    emit eventResponse("todoCompleted", QVariantList{ id });
    return true;
}

bool TodoPlugin::removeTodo(int id)
{
    QSqlDatabase db = QSqlDatabase::database(CONNECTION);
    QSqlQuery q(db);
    q.prepare("DELETE FROM todos WHERE id = ?");
    q.addBindValue(id);
    if (!q.exec() || q.numRowsAffected() == 0) return false;
    emit eventResponse("todoRemoved", QVariantList{ id });
    return true;
}

int TodoPlugin::clearAll()
{
    QSqlDatabase db = QSqlDatabase::database(CONNECTION);
    QSqlQuery q(db);
    if (!q.exec("DELETE FROM todos")) return 0;
    const int n = q.numRowsAffected();
    emit eventResponse("todosCleared", QVariantList{ n });
    return n;
}
```

The [`part2-todo/`](part2-todo/) folder ships with this version of the code
— if you were running the in-memory version from §2.3 live, swap it over
now.

#### Rebuild, reinstall, verify

```bash
git add -A
nix build '.#lgx-portable' --out-link result-portable

# Drop into Basecamp's core-module dir as before
BASECAMP_DIR="$HOME/Library/Application Support/Logos/LogosBasecamp"
rm -rf "$BASECAMP_DIR/modules/todo" /tmp/todo-lgx
mkdir -p "$BASECAMP_DIR/modules/todo" /tmp/todo-lgx
tar xzf result-portable/*.lgx -C /tmp/todo-lgx
cp /tmp/todo-lgx/variants/darwin-arm64/todo_plugin.dylib "$BASECAMP_DIR/modules/todo/"
cp /tmp/todo-lgx/manifest.json                            "$BASECAMP_DIR/modules/todo/"
echo "darwin-arm64" >                                      "$BASECAMP_DIR/modules/todo/variant"
```

> **Fully quit Basecamp first** (⌘Q, not just the red traffic-light button).
> `logos_host` child processes keep the current `.dylib` loaded otherwise,
> and you'll be debugging your old code for ten confusing minutes.

Relaunch Basecamp, add a few todos through `todo_ui`, quit with ⌘Q, relaunch
— the todos come back. The database file itself ends up roughly at:

```bash
ls -la "$HOME/Library/Application Support/"*/todo.db
```

which is a plain SQLite database — `sqlite3 <path>` opens it for ad-hoc
inspection.

The takeaway: swapping in persistence touched only the storage paths
(`m_todos` → SQL) and the CMake link line. The interface, the plugin
boilerplate, the event signal, the package/install flow — all unchanged.
That's exactly the separation the interface/implementation split was meant
to give us.

---

## Part 3 — A Voting Module (with `logos-delivery`)

Parts 1 and 2 were local — one machine, one user. Part 3 is where Logos
earns the "modular distributed app" framing: we plug into `delivery_module`,
the Logos wrapper around
[`logos-delivery`](https://github.com/logos-messaging/logos-delivery) (Waku
pub/sub under the hood), and end up with real-time polls that work across
every Basecamp peer connected to the same network.

### 3.1 What we're building

A voting module where:

- Any user can **open a poll** by picking an id (`fruit-best-2026`) and
  typing a question.
- Anyone who opens a poll with the **same id** joins that poll automatically
  and sees every vote flowing through.
- Votes are **yes/no**, broadcast over the network, deduplicated per voter
  so the same person can't double-count themselves.
- The tally updates live in everyone's UI as votes arrive.

No server. No database. The network *is* the state channel.

We split the work exactly the way Part 2 did: **`voting`** is the core
module (C++, owns the protocol), **`voting_ui`** is a QML plugin that
renders it. The finished versions live in [`part3-voting/`](part3-voting/)
and [`part3-voting-ui/`](part3-voting-ui/).

### 3.2 A tour of `delivery_module`

`delivery_module` is a `core` module like the ones we've already built, but
instead of a new protocol it wraps an existing one: Waku pub/sub. Basecamp
ships it pre-installed, so **we consume it, we don't build it.**

Its public interface (ten `Q_INVOKABLE` methods, one signal):

```
createNode(cfg)       → bool           // initialise a node from a JSON config
start() / stop()      → bool
subscribe(topic)      → bool           // start receiving messages on a content topic
unsubscribe(topic)    → bool
send(topic, payload)  → LogosResult    // publish a message
getAvailableConfigs() → QString        // preset names like "logos.dev"
...                                    // a few introspection helpers

eventResponse(eventName, data)         // how inbound events arrive
```

**Events you care about** (from `DeliveryModulePlugin`'s header docstring):

| Event name                | `data[]` layout                                            |
| ------------------------- | ---------------------------------------------------------- |
| `messageReceived`         | `[hash, contentTopic, payload_base64, timestamp_ns]`       |
| `messageSent`             | `[requestId, messageHash, timestamp]`                      |
| `messagePropagated`       | `[requestId, messageHash, timestamp]`                      |
| `messageError`            | `[requestId, messageHash, error, timestamp]`               |
| `connectionStateChanged`  | `[statusString, timestamp]` — status is `"Connected"` etc. |

**Calling it from another core module** uses the generic LogosAPI client
bridge you've seen in tictactoe-style setups:

```cpp
m_deliveryClient = logosAPI->getClient("delivery_module");
m_deliveryClient->invokeRemoteMethod("delivery_module", "createNode", cfg);
m_deliveryObject = m_deliveryClient->requestObject("delivery_module");
m_deliveryClient->onEvent(m_deliveryObject, "messageReceived",
    [](auto&, const QVariantList& data) { /* ... */ });
m_deliveryClient->invokeRemoteMethod("delivery_module", "send", topic, payload);
```

**Content topic convention** (same as Status / Waku in general):

```
/<app>/<version>/<subtopic>/<format>
```

For our poll-per-topic design that becomes `/voting/1/poll-<id>/json`. A
message on that topic is our JSON payload.

**The easy mode config** — use the pre-shipped `logos.dev` preset and
ignore every other field:

```json
{ "logLevel": "INFO", "mode": "Core", "preset": "logos.dev" }
```

Preset expands to cluster 2, auto-sharding across 8 shards, built-in
bootstrap nodes, mix enabled, p2p reliability on. Anything you want to
override — `tcpPort`, `discv5UdpPort`, fleet, logLevel — you just add
alongside the preset and it wins. (We'll use that later for two instances
on one machine.)

### 3.3 Scaffold the voting core

Same template as Part 2 — core module, C++ plugin:

```bash
cd ~/logos-workshop
mkdir voting && cd voting
nix flake init -t github:logos-co/logos-module-builder
```

The one thing that's different from Part 2: **our `flake.nix` now declares
`delivery_module` as an input**, and our `metadata.json` lists it under
`dependencies`. The build tooling uses both pieces — the flake input so the
SDK can generate interop headers, and the dependency field so Basecamp
loads `delivery_module` before loading us.

```nix
{
  description = "Voting — real-time yes/no polls over logos-delivery";

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

```json
{
  "name": "voting",
  "version": "0.1.0",
  "type": "core",
  "description": "Real-time yes/no polling via logos-delivery",
  "main": "voting_plugin",
  "dependencies": ["delivery_module"],

  "nix": { /* unchanged boilerplate */ }
}
```

> **First build fetches a large closure.** `delivery_module`'s source tree
> pulls in the Nim toolchain, `nim-libp2p`, `zerokit` (Rust), `liblogosdelivery`,
> and `libpq` before your plugin even compiles. Budget 15–30 minutes for the
> very first build. Every subsequent build is seconds.

`CMakeLists.txt` stays minimal — same `logos_module(NAME voting SOURCES ...)`
we used in Part 2. No `target_link_libraries` this time; we're not calling
`delivery_module` as a C++ library, we're calling it through the SDK.

### 3.4 Design the interface

The method set that popped out of wiring this up:

```cpp
// src/voting_interface.h
class VotingInterface : public PluginInterface {
public:
    virtual ~VotingInterface() = default;

    // Delivery lifecycle — 0=off, 1=connecting, 2=connected, 3=error
    Q_INVOKABLE virtual bool    startDelivery() = 0;
    Q_INVOKABLE virtual bool    stopDelivery() = 0;
    Q_INVOKABLE virtual int     deliveryStatus() = 0;

    // Polls — each poll is a content topic /voting/1/poll-<id>/json
    Q_INVOKABLE virtual bool    openPoll(const QString& pollId, const QString& question) = 0;
    Q_INVOKABLE virtual bool    closePoll(const QString& pollId) = 0;
    Q_INVOKABLE virtual bool    vote(const QString& pollId, bool yes) = 0;

    // Query (JSON strings — keeps the IPC surface simple)
    Q_INVOKABLE virtual QString listPolls() = 0;
    Q_INVOKABLE virtual QString tally(const QString& pollId) = 0;
    Q_INVOKABLE virtual QString myVoterId() = 0;
};

#define VotingInterface_iid "org.logos.VotingInterface"
Q_DECLARE_INTERFACE(VotingInterface, VotingInterface_iid)
```

A deliberate omission: no method to enumerate *all* polls on the network.
The voting module only sees polls **we've joined** (subscribed to). Other
peers could be voting on polls we know nothing about — that's the whole
point of pub/sub, it scales to any number of topics.

### 3.5 State and voter identity

Two pieces of local state:

```cpp
struct PollState {
    QString              question;
    QHash<QString, bool> votes;   // voterId → yes/no (latest wins)
};

// In VotingPlugin:
QString                   m_voterId;
QHash<QString, PollState> m_polls;
```

`m_voterId` is generated in the constructor using `QUuid::createUuid()` and
lives for the process lifetime. It's our stable "who am I" across every
vote we cast. When a vote arrives from the network, we key `m_polls[id].votes`
by the voter id — which means the same voter re-sending the same vote is a
no-op, and flipping yes→no just overwrites their entry. Dedup falls out for
free.

```cpp
VotingPlugin::VotingPlugin(QObject* parent)
    : QObject(parent)
    , m_voterId(QUuid::createUuid().toString(QUuid::WithoutBraces))
{}
```

### 3.6 Wiring up `delivery_module`

The full `startDelivery` sequence — this is the most interesting function
in the file:

```cpp
bool VotingPlugin::startDelivery()
{
    if (m_started) return true;

    setDeliveryStatus(1);   // "connecting" — set BEFORE anything that might fire events

    m_deliveryClient = logosAPI->getClient("delivery_module");
    if (!m_deliveryClient) { setDeliveryStatus(3); return false; }

    QJsonObject cfgObj;
    cfgObj["logLevel"] = "INFO";
    cfgObj["mode"]     = "Core";
    cfgObj["preset"]   = "logos.dev";
    // For same-machine two-instance demo: VOTING_TCPPORT=60001 env on the
    // second launch — see §3.12.
    const int customPort = qEnvironmentVariableIntValue("VOTING_TCPPORT");
    if (customPort > 0) {
        cfgObj["tcpPort"]       = customPort;
        cfgObj["discv5UdpPort"] = 9000 + (customPort - 60000);
    }
    const QString cfg = QString::fromUtf8(
        QJsonDocument(cfgObj).toJson(QJsonDocument::Compact));
    if (!invokeBool("createNode", "createNode", cfg)) {
        setDeliveryStatus(3); return false;
    }

    // Register event handlers BEFORE start so the first connectionStateChanged
    // is captured.
    m_deliveryObject = m_deliveryClient->requestObject("delivery_module");
    if (m_deliveryObject) {
        m_deliveryClient->onEvent(m_deliveryObject, "messageReceived",
            [this](const QString&, const QVariantList& data) {
                handleMessageReceived(data);
            });
        m_deliveryClient->onEvent(m_deliveryObject, "connectionStateChanged",
            [this](const QString&, const QVariantList& data) {
                if (data.isEmpty()) return;
                const QString status = data[0].toString();
                if (status.compare("Connected", Qt::CaseInsensitive) == 0)
                    setDeliveryStatus(2);
                else if (!status.isEmpty())
                    setDeliveryStatus(1);
            });
        m_deliveryClient->onEvent(m_deliveryObject, "messageError",
            [](const QString&, const QVariantList& data) {
                if (data.size() >= 3) qWarning() << "delivery send error:" << data[2];
            });
    }

    if (!invokeBool("start", "start")) {
        setDeliveryStatus(3); return false;
    }

    m_started = true;
    return true;
}
```

Five things worth internalising:

1. **`m_deliveryClient` is typed `LogosAPIClient*`.** The SDK header lives
   at `logos_api_client.h`.
2. **`requestObject` returns `LogosObject*`, not `QObject*`.** You need
   `#include "logos_object.h"` in both the header (for the member
   declaration) and the .cpp. Type mismatch here was a compile error I hit
   live — save yourself the 30s.
3. **Register event handlers *before* calling `start()`.** `connectionStateChanged`
   fires during start, and if no handler is registered yet the event is
   dropped.
4. **The config lives in `metadata.json`'s sibling module — not yours.**
   You don't link `delivery_module`; you call it. Whatever version of
   `delivery_module` Basecamp has installed is what you talk to.
5. **The `VOTING_TCPPORT` env var override** is there purely so two
   Basecamp instances can run on the same Mac for the demo in §3.12. On
   your attendees' machines it's irrelevant — they leave it unset.

### 3.7 The status-race gotcha

In my first pass I wrote `startDelivery` like this:

```cpp
// DON'T do this:
if (!invokeBool("start", "start")) { setDeliveryStatus(3); return false; }
m_started = true;
setDeliveryStatus(1);  // "connecting; event handler will upgrade to 2"  ← BUG
return true;
```

Looks innocent. **It's a race.** `invokeBool("start", ...)` is synchronous
from our point of view, but the delivery module's Qt event loop drains
incoming events *inside* the same call, including our own
`connectionStateChanged` handler. So the order is:

1. `start()` begins
2. Delivery establishes peers, fires `connectionStateChanged` with `"Connected"`
3. **Our handler runs, sets status to 2 ("Connected")**
4. `start()` returns `true`
5. **`setDeliveryStatus(1)` runs, downgrading status back to "Connecting"**
6. UI shows "Connecting…" forever

The fix is one line of reordering — set status to 1 **before** `start()`,
and let the event handler upgrade it to 2 whenever the network is ready:

```cpp
setDeliveryStatus(1);   // now; event handler might already be 2 by the time we return
// ... everything else ...
if (!invokeBool("start", "start")) { setDeliveryStatus(3); return false; }
m_started = true;
// No setDeliveryStatus here — handler owns the "upgrade to Connected" transition.
return true;
```

This is a useful mental model for any async SDK glue: **figure out which
code path is the source of truth for a given value, and don't let anyone
else overwrite it.**

### 3.8 Poll lifecycle: open, close, vote

The rest is straightforward — three methods, each a thin wrapper over a
single `delivery_module` call.

```cpp
static const QString TOPIC_PREFIX = "/voting/1/poll-";
static const QString TOPIC_SUFFIX = "/json";

QString VotingPlugin::topicFor(const QString& pollId) const {
    return TOPIC_PREFIX + pollId + TOPIC_SUFFIX;
}

bool VotingPlugin::openPoll(const QString& pollId, const QString& question)
{
    if (pollId.isEmpty()) return false;
    if (!m_started && !startDelivery()) return false;

    if (m_polls.contains(pollId)) {
        if (!question.isEmpty()) m_polls[pollId].question = question;
        emit eventResponse("pollOpened", { pollId, m_polls[pollId].question });
        return true;
    }

    m_polls.insert(pollId, PollState{ question, {} });
    if (!invokeBool("subscribe", "subscribe", topicFor(pollId))) {
        m_polls.remove(pollId);
        return false;
    }
    emit eventResponse("pollOpened", { pollId, question });
    return true;
}

bool VotingPlugin::vote(const QString& pollId, bool yes)
{
    if (!m_polls.contains(pollId) || !m_started) return false;

    // Optimistic local update — UI shows the change instantly.
    m_polls[pollId].votes.insert(m_voterId, yes);
    emit eventResponse("voteReceived", { pollId, m_voterId, yes });

    QJsonObject obj;
    obj["voter"] = m_voterId;
    obj["yes"]   = yes;
    const QString payload = QString::fromUtf8(
        QJsonDocument(obj).toJson(QJsonDocument::Compact));

    const QVariant r = m_deliveryClient->invokeRemoteMethod(
        "delivery_module", "send", topicFor(pollId), payload);
    return r.isValid();
}
```

`closePoll` is a mirror of `openPoll` — `unsubscribe` + drop from the hash.
`listPolls` / `tally` just walk `m_polls` and return JSON.

### 3.9 Receiving votes

The inbound side is a single event handler (registered in §3.6) that
parses the `messageReceived` event back into a vote and updates
`m_polls`:

```cpp
void VotingPlugin::handleMessageReceived(const QVariantList& data)
{
    // messageReceived: [hash, contentTopic, payload_base64, timestamp]
    if (data.size() < 3) return;

    const QString topic  = data[1].toString();
    const QString pollId = pollIdFromTopic(topic);
    if (pollId.isEmpty() || !m_polls.contains(pollId)) return;

    const QByteArray payload =
        QByteArray::fromBase64(data[2].toString().toUtf8());

    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(payload, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) return;

    const QJsonObject obj   = doc.object();
    const QString     voter = obj["voter"].toString();
    const bool        yes   = obj["yes"].toBool();
    if (voter.isEmpty()) return;

    m_polls[pollId].votes.insert(voter, yes);   // dedup by voter id
    emit eventResponse("voteReceived", { pollId, voter, yes });
}
```

**`data[2]` comes in base64-encoded** — that's the delivery module's wire
format, regardless of what you originally sent. One `fromBase64` gets you
back the exact bytes you passed to `send()`. Since we sent a JSON string
(text, no binary), no further unwrapping needed. (If you were sending
protobuf you'd base64-encode it yourself on the way out and base64-decode
twice on the way in — that's the tictactoe pattern.)

**Topic filtering matters.** Gossipsub broadcasts many topics across the
cluster; we only care about the ones whose topic matches our prefix and
whose pollId is in our `m_polls`. Anything else gets silently ignored.

### 3.10 Build, install, smoke test

Same dev loop as Parts 1 and 2:

```bash
cd ~/logos-workshop/voting
git init -q && git add -A && nix flake update && git add flake.lock
nix build '.#lgx-portable' --out-link result-portable

BASECAMP_DIR="$HOME/Library/Application Support/Logos/LogosBasecamp"
mkdir -p "$BASECAMP_DIR/modules/voting" /tmp/voting-lgx
tar xzf result-portable/*.lgx -C /tmp/voting-lgx
cp /tmp/voting-lgx/variants/darwin-arm64/voting_plugin.dylib "$BASECAMP_DIR/modules/voting/"
cp /tmp/voting-lgx/manifest.json                              "$BASECAMP_DIR/modules/voting/"
echo "darwin-arm64" >                                          "$BASECAMP_DIR/modules/voting/variant"
```

Do the same for `voting_ui` (we'll see its code in §3.13). Restart Basecamp
with ⌘Q + relaunch.

**Solo smoke test:**

1. Open **voting_ui** → click **Start** → wait for "Connected" (5–10s).
2. Type a poll id (or click **Random**) and a question. Click **Open / Join**.
3. Click **Vote Yes**. Yes count goes 0→1. Click again — stays at 1
   (voter dedup working). Click **Vote No** — flips you.

If all three work you've proven:

- `delivery_module` is reachable and starts cleanly
- `subscribe` + `send` are wired correctly
- The optimistic UI update path works
- Dedup logic works

### 3.11 Proving multi-peer via the log

Before reaching for a second machine, you can prove the network round-trip
works from one instance. The logos.dev gossipsub network **echoes your own
messages back to you** — they come in through your `messageReceived`
handler the same way another peer's messages would.

Launch Basecamp with captured stderr:

```bash
nohup open -W -n "/Users/guru/Desktop/LogosBasecamp.app" \
  --stdout /tmp/bc.log --stderr /tmp/bc.log > /dev/null 2>&1 &
```

Vote from the UI, then grep for the lifecycle:

```bash
grep -E 'DeliveryModulePlugin::(send|subscribe)|eventType.*message_(sent|propagated|received)|dispatching event "messageReceived"' /tmp/bc.log
```

You should see, in order:

- `DeliveryModulePlugin::subscribe called with contentTopic: "/voting/1/poll-.../json"`
- `DeliveryModulePlugin::send called ... payload: {"voter":"...","yes":true}`
- `event_callback message: {"eventType":"message_received", ...}` — the
  fleet echoed our own message back
- `event_callback message: {"eventType":"message_propagated", ...}` —
  **"delivered to neighboring nodes on the network"** per the spec
- `event_callback message: {"eventType":"message_sent", ...}`
- `Remote EventHelper: dispatching event "messageReceived" to 1 callback(s) (via IPC)`
  — our own handler receives the echo

That last line is the proof. If the network delivered your message back
to *you*, it delivered it to every other subscriber of the same topic too.

### 3.12 Two instances on one machine

For the live demo, you want to show two voters interacting — but two
Basecamps on one Mac can't both bind port 60000 (the `logos.dev` preset's
default P2P TCP port) or UDP port 9000 (discv5).

Our plugin already handles this: set `VOTING_TCPPORT` on the second launch
and the plugin picks both a new TCP port **and** a derived UDP port:

```cpp
const int customPort = qEnvironmentVariableIntValue("VOTING_TCPPORT");
if (customPort > 0) {
    cfgObj["tcpPort"]       = customPort;
    cfgObj["discv5UdpPort"] = 9000 + (customPort - 60000);
}
```

So `VOTING_TCPPORT=60001` puts the second instance on `tcpPort 60001` and
`discv5UdpPort 9001` — no collision.

**Launching both:**

```bash
# Instance A — default ports (60000 / 9000)
nohup open -W -n "/Users/guru/Desktop/LogosBasecamp.app" \
  --stdout /tmp/bc-A.log --stderr /tmp/bc-A.log > /dev/null 2>&1 &

sleep 2

# Instance B — override ports via open's --env flag
nohup open -W -n "/Users/guru/Desktop/LogosBasecamp.app" \
  --stdout /tmp/bc-B.log --stderr /tmp/bc-B.log \
  --env VOTING_TCPPORT=60001 > /dev/null 2>&1 &
```

Click Start in both. Both should reach "Connected". Open the **same poll
id** in both, vote from one — the other updates within a second.

Each instance has a **different voter id** (generated fresh per process),
shown in the UI under the header. That's how you tell them apart and how
dedup stays correct when you have a mix of local and remote votes.

> **Caveats of running two Basecamps on one machine.** They share the same
> `~/Library/Application Support/Logos/LogosBasecamp/` data directory.
> Voting state is in-memory so it doesn't collide, but other core modules
> that persist to disk (e.g. the todo module from Part 2) might. For a live
> demo that's limited to voting, this is fine. For serious development
> you'd want a second data dir.

### 3.13 The voting UI

The QML plugin (`voting_ui`, type `ui_qml`) is about 200 lines of
`Main.qml`. It:

- Reads `deliveryStatus()` and shows a coloured status dot.
- Polls `listPolls()` every 1.5s via a `Timer` and redraws the list.
- Provides a form at the bottom to open or join a poll.
- Renders each poll as a card with a progress bar, yes/no counts and
  percentages, a **Vote Yes / Vote No / Close** row, and highlights the
  button matching your previous vote.

The interesting bits — everything else is standard QML:

```qml
function callVoting(method, args) {
    if (typeof logos === "undefined" || !logos.callModule) return null
    return logos.callModule("voting", method, args)
}

function refresh() {
    deliveryStatus = callVoting("deliveryStatus", []) || 0
    if (voterId === "") voterId = callVoting("myVoterId", []) || ""
    const json = callVoting("listPolls", [])
    try { polls = JSON.parse(json) } catch (e) { polls = [] }
}

Button {
    text: "Vote Yes"
    onClicked: { callVoting("vote", [modelData.id, true]); refresh() }
}

Timer {
    interval: 1500
    running: true
    repeat: true
    onTriggered: refresh()
}
```

The polling loop is deliberately simple. A tighter UI would use
`logos.onModuleEvent("voting", "voteReceived", cb)` to update only on new
events — try it as a follow-up exercise. For a workshop demo where the
audience wants to see votes land, 1.5s polling is plenty.

The `metadata.json` declares `"dependencies": ["voting"]` — Basecamp loads
our core module before this plugin, so `logos.callModule("voting", ...)`
resolves correctly.

Build and install exactly like Part 2's `todo_ui`:

```bash
cd ~/logos-workshop/voting_ui
git init -q && git add -A
nix flake update && git add flake.lock
nix build --override-input voting path:../voting '.#lgx-portable' --out-link result-portable

mkdir -p "$BASECAMP_DIR/plugins/voting_ui" /tmp/voting-ui-lgx
tar xzf result-portable/*.lgx -C /tmp/voting-ui-lgx
cp /tmp/voting-ui-lgx/variants/darwin-arm64/Main.qml /tmp/voting-ui-lgx/variants/darwin-arm64/voting.png /tmp/voting-ui-lgx/variants/darwin-arm64/metadata.json "$BASECAMP_DIR/plugins/voting_ui/"
cp /tmp/voting-ui-lgx/manifest.json "$BASECAMP_DIR/plugins/voting_ui/"
echo "darwin-arm64" > "$BASECAMP_DIR/plugins/voting_ui/variant"
```

Restart Basecamp, click Start on the voting_ui tab, and you're running a
peer on the real logos.dev network.

---

## Wrap-up

What you picked up by running through this:

- **Two module shapes.** `ui_qml` modules are just `flake.nix` +
  `metadata.json` + a QML entry point — no compile step. `core` modules add
  `CMakeLists.txt` + a `src/` pair (`*_interface.h` + `*_plugin.{h,cpp}`)
  and compile to a shared library.
- **`metadata.json` is the single source of truth.** `name` / `type` /
  `view` (for UI) or `main` (for core) must line up with what the code
  actually says, or you get confusing load errors.
- **`Q_INVOKABLE` is the whole surface.** Anything marked `Q_INVOKABLE` on a
  core module's interface is callable from anywhere — other modules, QML
  UIs, `logoscore`.
- **Events travel through `eventResponse`.** Emit liberally; subscribe with
  `logos.onModuleEvent(...)` from QML.
- **`.lgx` is just a gzipped tarball** — `manifest.json` plus a
  `variants/<platform>/` directory. Use `'.#lgx'` for local dev,
  `'.#lgx-portable'` for release packages Basecamp accepts.
- **The dev loop is `nix build '.#lgx-portable'` → import into Basecamp.**
  For core modules you can also use `logoscore call` for headless testing.
- **Core modules compose through the LogosAPI.** `logosAPI->getClient(name)` +
  `invokeRemoteMethod(...)` + `onEvent(...)` is how any module talks to any
  other module — we used it to drive `delivery_module` in Part 3, and the
  same pattern scales to every built-in module on your system.

Where to go next:

- **Add a QML UI.** Scaffold a `ui_qml` module, call your todo from QML with
  `logos.callModule("todo", "listTodos")`, render it.
- **Talk to other modules.** Declare the other module in `metadata.json`'s
  `dependencies` and call it via `LogosAPI`.
- **Publish your `.lgx-portable`.** Share it, install it on another machine,
  have friends call your module.

---

## Appendix — Troubleshooting

**`flakes NOT enabled` / `experimental-features` errors**
Make sure `~/.config/nix/nix.conf` contains
`experimental-features = nix-command flakes` and reopen your shell.

**`LogosModule.cmake not found`**
You ran `cmake` directly. Use `nix build '.#lib'`; the Nix wrapper sets the
`LOGOS_MODULE_BUILDER_ROOT` environment variable that `CMakeLists.txt` keys
off.

**`nix build` silently builds the wrong target**
You probably wrote `nix build .#lib` without quotes. zsh ate the `#` as a
comment. Always quote attribute paths: `nix build '.#lib'`.

**Build finishes, but `lm methods` shows no methods**
The `Q_OBJECT` macro is missing, or `Q_INVOKABLE` isn't on the interface
methods, or the interface IID doesn't match between the interface header and
the plugin header's `Q_PLUGIN_METADATA`.

**`logoscore call` hangs**
The daemon isn't running, or it's pointing at a different modules dir.
`logoscore stop` then restart with `-D -m ./modules`.

**Install fails with "plugin not found"**
`name` in `metadata.json` disagrees with what `name()` returns in C++, or
`main` in `metadata.json` disagrees with the CMake `NAME`. They must all
match.

**First build takes forever**
It genuinely does — Qt + SDK dependencies are ~2–3 GB. After the first build
everything is cached and subsequent builds take seconds.
