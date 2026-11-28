<div align="center">

# godot-to-aurora

### Porting a Godot 4 game to Aurora OS with an AI agent

**Copy this directory into your project and tell Claude, GPT, Copilot, or another
AI agent in any harness to "port the game to Aurora OS." You get a signed RPM for
both the emulator and a device, without learning the Aurora SDK by hand.**

[![CI](https://github.com/infernogood/godot-to-aurora/actions/workflows/ci.yml/badge.svg)](https://github.com/infernogood/godot-to-aurora/actions/workflows/ci.yml)
![Version](https://img.shields.io/badge/version-1.1.2-blue)
![Godot](https://img.shields.io/badge/Godot-4.7-478CBF?logo=godotengine&logoColor=white)
![Aurora OS](https://img.shields.io/badge/Aurora_OS-5.2%2B-1f6feb)
![Agent-ready](https://img.shields.io/badge/AGENTS.md-agent--ready-8957e5)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[Quick Start](#quick-start) ·
[Compatibility matrix](#compatibility-matrix) ·
[Manual Build](#manual-build) ·
[Requirements](#requirements) ·
[Parameters](#package-parameters) ·
[Common Issues](#common-issues) ·
[Русский README](README.md)

</div>

---

## One Phrase to a Ready RPM

Place the kit in the root of your game:

```bash
cd /path/to/your-godot-game
git clone https://github.com/infernogood/godot-to-aurora godot-to-aurora
touch godot-to-aurora/.gdignore
```

Then give the agent exactly one instruction:

```text
Study godot-to-aurora/AGENTS.md and port my game to Aurora OS.
```

The agent follows the playbook in [`AGENTS.md`](AGENTS.md):

| # | What the agent does | How it is verified |
|---|---|---|
| 1 | **Audit** the project: resolution, orientation, fonts, saves, input, pause, network, plugins | Reads `project.godot`, scenes, and UI scripts |
| 2 | Writes **`PLAN.md`**: "problem → change → file → risk"; ambiguous decisions are left for approval | You review the plan before the first change |
| 3 | Makes **minimal edits**: `.ttf` fonts, safe area, saves in `user://`, lifecycle, orientation | Leaves gameplay and graphics untouched |
| 4 | Builds the `.pck` and RPM (`x86_64` for the emulator, `aarch64` for the phone) | `--check` → `--pck-only` → full build |
| 5 | Signs, installs, and starts the app in the emulator, then reads `journalctl` | Checks the installed `VERSION-RELEASE` |
| 6 | Returns a **report**: changes made, checks performed, and remaining questions | You decide what to accept |

The kit can also check itself; these commands work without SDK, Docker, or network access:

```bash
$ ./godot-to-aurora/scripts/build_x86_64_rpm.sh --version
godot-to-aurora 1.1.2
```

No agent access? Follow the [manual four-step path](#manual-build).

---

## Why an Agent Kit Instead of a Build Template?

Most "Aurora ports" are sets of instructions that a person must read, understand, and execute.
**godot-to-aurora** takes a different approach: **an AI agent performs the routine porting
work, while a person makes the decisions**.

Experience from real ports is encoded for the agent to read:

- 📘 **`AGENTS.md`** — an agent-readable playbook covering process, strict invariants,
  a checklist, a "symptom → check" table, and the rule to ask before changing architecture.
- 🧪 **Scripts with `--check`** — the agent diagnoses the environment before building.
  Exit codes and messages are clear for both people and models.
- 🧱 **Ready modules** — `AuroraLifecycle`, `SaveService`, `AuroraSafeArea`, and embedded
  fonts are copied into the game instead of rewritten.
- 🔒 **Protection from common agent mistakes** — engine SHA-256 verification, template
  ELF-architecture verification, and protection against committing critical build files.

### Compared with Manual Builds Through `sfdk`

| | Manually through Aurora SDK | With godot-to-aurora |
|---|---|---|
| Learning SDK 5.2 | Required: `tools/run`, Docker image, Sailjail, APM, `rpmsign-external` | Encoded in scripts and `AGENTS.md` |
| Adapting the game | Search for why glyphs are empty, HUD controls overflow, or saves do not write | Audit and ready modules: fonts, safe area, `user://` |
| Building the RPM | Create a custom export, packaging, and signing chain | `build_x86_64_rpm.sh` / `build_aarch64_rpm.sh` |
| Installing in the emulator | Signing, `device exec`, D-Bus, and version checks | `deploy_emulator.sh` performs all steps and verifies the version |
| Who performs routine work | You | Your agent |

---

## Quick Start

Set up the environment once; see [Requirements](#requirements) and
[Starting from Scratch](#starting-from-scratch). Two usage paths are available:

### Build with an Agent

Use any agent that can read files and run commands: **Claude Code, Codex/GPT,
Copilot**, or another compatible agent.

First, copy the repository into the root of the project:

```bash
cd /path/to/your-godot-game
git clone https://github.com/infernogood/godot-to-aurora godot-to-aurora
touch godot-to-aurora/.gdignore
```

Then use this prompt:

```text
Study godot-to-aurora/AGENTS.md and port my game to Aurora OS.
```

The agent creates `PLAN.md`, updates UI, fonts, saves, and lifecycle code, builds
the RPM, and tests the game in the emulator.

> Create `godot-to-aurora/.gdignore` **before** opening Godot for the first time.
> Otherwise, the engine scans `modules/*.gd` and reports
> `Class "AuroraSafeArea" hides a global script class`. Keep the directory name
> `godot-to-aurora/`; documentation and commands refer to it.

### Manual Build

**1. Copy the modules** (the only canonical integration path):

```bash
mkdir -p scripts/aurora assets/fonts
cp godot-to-aurora/modules/*.gd          scripts/aurora/
cp godot-to-aurora/modules/fonts/*.ttf   assets/fonts/
cp godot-to-aurora/modules/fonts/LICENSE assets/fonts/
```

Add the autoloads to `project.godot`:

```ini
[autoload]
AuroraLifecycle="*res://scripts/aurora/aurora_lifecycle.gd"
SaveService="*res://scripts/aurora/save_service.gd"
```

> Do not reference `res://godot-to-aurora/modules/...`: fonts will be imported twice,
> and `class_name` produces the same `AuroraSafeArea` error. `AuroraSafeArea` is a
> static helper and does not need an autoload.

**2. Prepare the engine** (Aurora editor and templates):

```bash
./godot-to-aurora/scripts/fetch_engine.sh --from-dir /path/to/engine   # local binaries
./godot-to-aurora/scripts/fetch_engine.sh                              # from GitHub Releases
```

`SHA256SUMS` verification is mandatory for every source, including `--from-dir`.
Without a checksum file or when a hash does not match, the script exits with an
error. Publishing instructions are in [docs/RELEASES_GUIDE.md](docs/RELEASES_GUIDE.md).

**3. Build the RPM:**

```bash
export ORG_NAME=ru.example APP_NAME=mygame APP_TITLE="My Game"
./godot-to-aurora/scripts/build_x86_64_rpm.sh --check
./godot-to-aurora/scripts/build_x86_64_rpm.sh
```

**4. Sign, install, and run** using the emulator's application menu icon:

```bash
./godot-to-aurora/scripts/deploy_emulator.sh
sfdk -c device="Aurora OS Emulator 5.2.1.200" device exec journalctl -f -t ru.example.mygame
```

Deployment discovers the emulator, signs the RPM with the SDK test keys, creates
`~/Downloads` in the emulator, installs the package through APM, and compares the
installed `VERSION-RELEASE` with the built package. The default SSH key is
`~/AuroraOS/vmshare/ssh/private_keys/sdk`; override it with `AURORA_SSH_KEY`.

---

## Requirements

An `x86_64` Linux host with access to `/dev/kvm`.

| Component | Purpose | Check |
|---|---|---|
| Docker | Build RPMs in the `aurora-build-tools-*` image | `docker --version` |
| Aurora SDK 5.2.x | Emulator, sysroot, `tools/run`, signing keys | `~/AuroraOS/bin/sfdk --version` |
| Aurora Godot 4.7.x editor | Export `.pck` and RPM | `./scripts/fetch_engine.sh --check` |
| `git`, `curl`, `unzip` | Clone the kit and unpack engine releases | `git --version` |
| `rpm` (`rpmbuild`, `rpm -qp`) | Build and inspect the package on the host | `rpm --version` |
| `ssh`, `scp` (`openssh-clients`) | Deliver RPMs to the emulator or device | `ssh -V` |
| `timeout`, `realpath` (coreutils) | SDK call timeouts and path canonicalization | `timeout --version` |
| `patchelf` | RPATH for the private `libxkbcommon` library (x86_64 only) | `patchelf --version` |
| `readelf` (binutils) | Check template and package ELF architecture | `readelf --version` |
| `magick` or `rsvg-convert` | Generate `86/108/128/172` icons from `icon.svg` | `magick -version` |
| `python3` + `pip` | Required only when building the x86_64 template | `python3 --version` |

```bash
sudo dnf install -y docker git curl unzip rpm openssh-clients coreutils \
  patchelf binutils ImageMagick python3          # Fedora
```

The SDK 5.2 emulator is **QEMU/KVM**; no X11 wrapper is required. Run this from
the game root to validate the complete environment:

```bash
./godot-to-aurora/scripts/build_x86_64_rpm.sh --check
```

It lists detected components, rejects a stock Godot build without the `AuroraOS`
platform, and explains missing dependencies. With `--strict`, it returns exit code
1 if a build is not possible.

### Starting from Scratch

Perform this setup once on a clean machine; skip it if `--check` passes.

1. **SDK.** Install Aurora SDK 5.2.1.200 with `SDKMaintenanceTool` and verify
   `~/AuroraOS/bin/sfdk --version`. Set `AURORA_SDK_HOME` if the SDK is in another
   directory. The kit supports the `5.2.x` series: SDK `5.1.x`/`5.3.x` prints a
   warning, while `--strict-sdk` returns an error. Layout details are in
   [docs/SDK_5_2_ARCHITECTURE.md § 1](docs/SDK_5_2_ARCHITECTURE.md#1-что-установлено-и-где-лежит).
2. **Docker and image.** The SDK installer downloads
   `sdk-build-tools-5.2.1.200-x86_64.tar` and tags the image
   `aurora-build-tools-<user>:5.2.1.200`. Check:

   ```bash
   docker images --format '{{.Repository}}:{{.Tag}}' | grep '^aurora-build-tools'
   ```

   If the image is missing, reinstall the Build Tools SDK component. Set
   `AURORA_BUILD_IMAGE` for a nonstandard image name.
3. **KVM.** Run `ls -l /dev/kvm`, then
   `sudo modprobe kvm_intel` (or `kvm_amd`) and
   `sudo setfacl -m u:$USER:rw /dev/kvm`.
4. **Emulator and keys.** Start the emulator from the SDK. `sfdk device list` should
   show `Aurora OS Emulator 5.2.1.200` (`defaultuser@127.0.0.1:2223`). Test signing
   keys are in `~/AuroraOS/package-signing/`; deployment finds them automatically.
   Never copy signing keys into the repository.

---

## Compatibility matrix

SDK and fork versions are synchronized with [`versions.env`](versions.env).

| Component | Supported variant | Status | Notes |
|---|---|---|---|
| Aurora OS / SDK | `5.2.x` (verified on `5.2.1.200`) | ✅ Supported | `5.1.x` / `5.3.x` warn (`--strict-sdk` blocks the build) |
| Godot Engine | Fork `4.7.2-auroraos1` (`savegame/godot`) | ✅ Supported | Stock Godot cannot export for Aurora OS |
| Rendering and display | `gl_compatibility` (GLES3) + Wayland | ✅ Supported | Vulkan and X11 are unavailable on Aurora |
| Scripts and extensions | GDScript | ✅ Supported | C# / .NET and third-party GDExtensions require a native build |
| `x86_64` architecture | QEMU/KVM emulator | ✅ Verified | Full cycle: build, signing, APM, Sailjail, saves in `user://` |
| `aarch64` architecture | Smartphones / tablets | ⚠️ Partial | RPM build and ELF checks work; physical-device testing awaits feedback |
| Host OS | Linux `x86_64` (Docker + KVM) | ✅ Supported | Windows and macOS are not supported |

## Project Structure

```text
godot-to-aurora/
├── AGENTS.md            Agent playbook: audit → PLAN.md → code → RPM → verification
│
├── versions.env         KIT_VERSION, engine/SDK tags and SHAs, SCons/xkbcommon versions
│
├── scripts/             fetch_engine, build_x86_64_rpm (--arch x86_64|aarch64),
│                        build_aarch64_rpm, deploy_emulator, lib/common.sh
│
├── templates/           AuroraOS preset, .desktop (Sailjail), .spec
│
├── modules/             aurora_lifecycle.gd, safe_area_helper.gd, save_service.gd,
│                        fonts/ (Liberation + LICENSE, SIL OFL 1.1)
│
├── tests/               CLI tests, module headless tests, fixture
│
├── .github/workflows/   CI: shellcheck, bash -n, CLI and headless tests
│
└── docs/                SDK 5.2, engine publishing, release contents
```

| Module | What it provides |
|---|---|
| `AuroraLifecycle` | Application lifecycle, pause, and orientation agreement |
| `SaveService` | Atomic saves in `user://` (`tmp` + `rename`), recovery, version migration |
| `AuroraSafeArea` | Screen-cutout and corner offsets without hardcoded pixels |
| `fonts/` | Liberation Sans/Mono: on Aurora, `fontconfig=no` and system fonts are unavailable |

The kit adapts platform integration without rewriting gameplay or graphics.

---

## Package Parameters

Precedence: environment variables → `export_presets.cfg` → `project.godot` → default.
The full package name is `<ORG_NAME>.<APP_NAME>`: it appears in the RPM, `.desktop`,
`Exec`, icons, and sandbox path `~/.local/share/<org>/<app>/`.

| Variable | Purpose / example |
|---|---|
| `ORG_NAME` | `ru.example` (dotted, lowercase) |
| `APP_NAME` | `mygame` (`[a-z0-9_]`) |
| `APP_TITLE` | `My Game` |
| `APP_VERSION` / `APP_RELEASE` | `0.1.0` / `1` |
| `PERMISSIONS` | `Audio,Internet,Camera` (Sailjail) |
| `ORIENTATION` | `Landscape`, `Portrait`, `Dynamic` (or `0/2/4`, `1/3/5`, `6`) |
| `APP_COMMENT` / `APP_CATEGORIES` | `My Game` / `Game` |
| `RPM_LICENSE` | `Proprietary` (default), `MIT` |
| `ICON_SVG` | Master icon (default: `<project>/icon.svg`) |

<details>
<summary><b>Extended environment variables</b></summary>

| Variable | Purpose / example |
|---|---|
| `AURORA_PRESET` | Preset name; empty means the first `platform="AuroraOS"` preset |
| `BUILD_DIR` | Build directory (default: `<project>/build`) |
| `GODOT_BIN` | Explicit path to the Aurora editor |
| `AURORA_TEMPLATE_X86_64` / `AURORA_TEMPLATE_AARCH64` | Explicit template paths (legacy `AURORA_TEMPLATE` applies to both architectures) |
| `AURORA_KIT_ENGINE_DIR` | Directory where `fetch_engine.sh` placed binaries |
| `AURORA_SDK_HOME` | SDK root, default: `~/AuroraOS` |
| `AURORA_BUILD_IMAGE` | `aurora-build-tools-*` image name for nonstandard installations |
| `AURORA_EXTRA_DIR` | Prepared `extra/` directory for building the x86_64 template |
| `AURORA_ARM64_LIB_DIR` | ARM64 libraries for the aarch64 package |
| `AURORA_SSH_KEY` | Private SSH key; default: `~/AuroraOS/vmshare/ssh/private_keys/sdk` |
| `AURORA_SSH_HOST` / `AURORA_SSH_PORT` / `AURORA_SSH_USER` | Device SSH settings (default values come from `sfdk`) |
| `AURORA_DEVICE` / `AURORA_EMULATOR` | Equivalent to `--device` / `--emulator` |
| `AURORA_SIGN_KEY` / `AURORA_SIGN_CERT` | Custom signing key and certificate |

</details>

### Versions

Kit, engine, SDK, SCons, and xkbcommon versions live in [`versions.env`](versions.env):
`KIT_VERSION`, `GODOT_AURORA_TAG`, the fork commit SHA (`GODOT_AURORA_SHA`),
engine release binary SHA-256 values, `SDK_SUPPORTED_PREFIX`, `SCONS_VERSION`,
and `XKBCOMMON_VERSION`. Edit them there instead of changing scripts.

When building the x86_64 template, SCons (a SHA-256-verified wheel) and the
`libxkbcommon` archive from [xkbcommon.org](https://xkbcommon.org/) are downloaded;
that archive is also checksum-verified. The `libxkbcommon` version is read from the
build image. Known versions are listed in `XKBCOMMON_KNOWN_VERSIONS`; add unknown
versions to the list or pass `build_x86_64_rpm.sh --skip-checksum` to explicitly
disable verification.

---

## Modes and Artifacts

```bash
./scripts/build_x86_64_rpm.sh --version        # godot-to-aurora <KIT_VERSION>
./scripts/build_x86_64_rpm.sh --pck-only       # quickly verify packaging
./scripts/build_x86_64_rpm.sh --skip-template  # template already built
./scripts/build_x86_64_rpm.sh --force-preset   # recreate the AuroraOS preset
./scripts/build_x86_64_rpm.sh --no-xkbcommon   # omit private libxkbcommon
./scripts/build_x86_64_rpm.sh --strict-sdk     # fail unless SDK is 5.2.x
./scripts/build_x86_64_rpm.sh --skip-checksum  # disable xkbcommon/SCons SHA-256 checks
./scripts/fetch_engine.sh --check --print-paths
./scripts/deploy_emulator.sh --check           # inspect RPM, device, and key state
./scripts/deploy_emulator.sh --sign-only       # sign only
```

`--version` prints `godot-to-aurora <KIT_VERSION>` and works without
`project.godot`, SDK, network access, or Docker.

```text
build/<org>.<app>.pck
build/icons/{86,108,128,172}.png                       # icons are only in build/
build/rpmbuild/RPMS/x86_64/<org>.<app>-<version>-<release>.x86_64.rpm
build/backups/export_presets.cfg.bak.<timestamp>       # if the preset was created or changed
```

Icons are generated in `$BUILD_DIR/icons/` and do not pollute the game tree.
Signing keys are copied to a temporary `$BUILD_DIR/.signing.XXXXXX` directory and
removed after signing; they do not remain in the project or Git.

### Preset and `.pck`

If `AURORA_PRESET` is unset and `--preset` is not supplied, the kit uses the
**first existing preset with `platform="AuroraOS"`**, regardless of its name, and
reads `package/organization` and `package/name` from it. Existing presets are not
overwritten. A new preset is created only when no `AuroraOS` preset exists;
`--force-preset` recreates it explicitly.

Only `build/*` and the kit directory relative to the project (for example,
`godot-to-aurora/*`) are added to `exclude_filter`. `tools/`, `addons/`, and
`docs/` are not excluded because the game may need them. Matching uses exact
tokens (`mybuild/*` is not `build/*`).

---

## Building for a Real Device (aarch64)

The standard Aurora exporter in the Godot fork invokes `sfdk engine exec sb2`,
which SDK 5.2 no longer provides. The kit therefore packages an aarch64 RPM
natively with the `auroraos_release.arm64` template and
`rpmbuild --target aarch64-meego-linux-gnu`:

```bash
./godot-to-aurora/scripts/build_aarch64_rpm.sh     # = build_x86_64_rpm.sh --arch aarch64
./godot-to-aurora/scripts/deploy_emulator.sh \
  --rpm build/rpmbuild/RPMS/aarch64/<pkg>-*.aarch64.rpm --device "<name>"
```

Before packaging, the script verifies the template ELF architecture with
`readelf -h`. `fetch_engine.sh` installs arm64 templates in
`~/.local/share/godot/export_templates/`, making them available to the Aurora editor.
The private `libxkbcommon` is not included in the package by default because it is
system-provided on the device. Set `AURORA_ARM64_LIB_DIR` if needed. Enable
developer mode on the phone.

---

## Common Issues

| Symptom | What to check |
|---|---|
| `sfdk: Unknown command 'engine'` | Normal: SDK 5.2 has no sb2; builds use `<sdk>/tools/run` and Docker |
| `/dev/kvm` is unavailable | `sudo modprobe kvm_intel` (or `kvm_amd`) and `sudo setfacl -m u:$USER:rw /dev/kvm` |
| APM does not install the package | RPM is unsigned or its architecture does not match the device |
| The game appears portrait | Align `orientation` in `project.godot`, `Orientation=` in `.desktop`, and launch from the application menu instead of a shell |
| Empty glyphs | `.ttf` files in `res://assets/fonts/` (Aurora has `fontconfig=no`); do not use `SystemFont` |
| HUD outside the screen | Use offsets from `AuroraSafeArea`, not the PC monitor's safe area |
| `SamePackageIsInstalled` | Increase `APP_RELEASE` |
| Kit files appear in the PCK | Check `exclude_filter` and exact tokens `build/*` and `godot-to-aurora/*` |

The complete table is in [AGENTS.md § 5](AGENTS.md#5-траблшутинг) and
[docs/SDK_5_2_ARCHITECTURE.md](docs/SDK_5_2_ARCHITECTURE.md).

---

## Tests and CI

```bash
bash tests/test_cli.sh                                # no network, Godot, Docker, or SDK
GODOT_BIN=/path/to/Godot bash tests/run_modules.sh    # headless modules
```

CLI tests cover flags, `--check` without SDK, mandatory `SHA256SUMS`, the
`AuroraOS` preset, escaping of `%`/`"`/`\`, `exclude_filter` tokens, and custom
`BUILD_DIR`. Headless tests cover safe area, atomic writes and save recovery,
Cyrillic slot collisions, version migration, and lifecycle behavior. CI runs
`shellcheck`, `bash -n`, and both test suites.

---

## Engine Releases

Without `--from-dir`, `fetch_engine.sh` downloads the prepared bundle from
[this repository's GitHub Release](https://github.com/infernogood/godot-to-aurora/releases/tag/engine-4.7.2-auroraos1).
The `engine-4.7.2-auroraos1` release includes the Aurora Godot editor, templates
for the emulator and devices, `SHA256SUMS`, and licenses. This is where the
SDK 5.2-built x86_64 template required for emulator RPMs is published.

The upstream fork has a separate [`savegame/godot` release](https://github.com/savegame/godot/releases/tag/4.7.2-auroraos1).
It contains the editor and ARM templates, but is not the default source used by
`fetch_engine.sh` and does not include the ready-to-use x86_64 template.
Instructions for publishing both sets of artifacts are in
[docs/RELEASES_GUIDE.md](docs/RELEASES_GUIDE.md).

---

## Ecosystem and Documentation

* [`AGENTS.md`](AGENTS.md) — Agent playbook: process, invariants, checklist.
* [`docs/SDK_5_2_ARCHITECTURE.md`](docs/SDK_5_2_ARCHITECTURE.md) — SDK 5.2:
  `tools/run`, emulator, Sailjail, `rpmsign-external`, APM.
* [`docs/RELEASES_GUIDE.md`](docs/RELEASES_GUIDE.md) — Publishing engine binaries.
* [`docs/ENGINE_RELEASE_4.7.2-auroraos1.md`](docs/ENGINE_RELEASE_4.7.2-auroraos1.md) —
  Engine release contents and checksums.
* [`CHANGELOG.md`](CHANGELOG.md) — Changes between kit versions.
* [`savegame/godot`](https://github.com/savegame/godot) — The Aurora port of the
  Godot engine (`4.7.2-auroraos1`) used by this kit.

---

## License

Kit code, scripts, and templates are MIT ([LICENSE](LICENSE)). Liberation fonts in
`modules/fonts/` are SIL OFL 1.1; `modules/fonts/LICENSE` applies to all font styles.

The Aurora build of Godot (`savegame/godot`, tag `4.7.2-auroraos1`) is MIT. Engine
binaries are distributed through Releases and are not committed to Git. Copyright
notices and the full MIT text are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
