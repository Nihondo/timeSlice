# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

timeSlice is a macOS menu bar app that periodically captures the frontmost window, runs OCR, and stores results locally for automated work report generation. Privacy-first design: all data stays local.

## Build & Run Commands

Package.swift has been removed — this project uses **Xcode only**.

```bash
# Build (Xcode project)
xcodebuild -project timeSlice.xcodeproj -scheme timeSlice -configuration Debug -derivedDataPath ./.xcode-derived build

# Run the built .app
open ./.xcode-derived/Build/Products/Debug/timeSlice.app

# Run tests (via Xcode)
xcodebuild -project timeSlice.xcodeproj -scheme timeSlice -configuration Debug -derivedDataPath ./.xcode-derived test

# Run a single test class or method
xcodebuild -project timeSlice.xcodeproj -scheme timeSlice -configuration Debug -derivedDataPath ./.xcode-derived test -only-testing:TimeSliceCoreTests/TestClassName/testMethodName
```

**Note:** `swift build` / `swift test` / `swift run` do NOT work (no Package.swift).

## Architecture

**Xcode project (swift-tools-version: 6.2, macOS 14+)** with two targets:

- `TimeSliceCore` — library containing all business logic, fully testable
- `timeSliceApp` — thin executable with SwiftUI MenuBarExtra UI (`.menu` style), depends on TimeSliceCore

### Capture Pipeline

```
CaptureScheduler (actor, periodic loop)
  → ScreenCapturing protocol → ScreenCaptureManager (ScreenCaptureKit)
  → TextRecognizing protocol → OCRManager (Vision Framework)
  → DuplicateDetector (actor, hash-based consecutive dedup)
  → DataStore (JSON) + ImageStore (PNG)
```

`CaptureScheduler.performCaptureCycle()` returns `CaptureCycleOutcome` enum (.saved/.skipped/.failed) — the single entry point for the pipeline.

### Report Pipeline

```
ReportGenerator (struct, orchestrator)
  → DataStore.loadRecords(on:) — loads daily CaptureRecords
  → PromptBuilder.buildDailyReportPrompt() — constructs prompt with {{DATE}}, {{JSON_GLOB_PATH}}, {{RECORD_COUNT}} placeholders
  → CLIExecutor (runs external AI CLI, e.g. gemini -p "...")
  → saves markdown to reports/YYYY/MM/DD/report.md
```

- **CLIExecutor** runs with cwd set to `data/` directory so the AI CLI can read `./YYYY/MM/DD/*.json` directly
- Handles SIGPIPE, PATH injection for GUI context, `-p`/`--prompt` trailing-flag auto-fill, and configurable timeout
- **PromptBuilder** uses file-reference strategy (not inline JSON embedding) with a customizable template

### Storage Layout

App Sandbox is enabled for both Debug and Release builds (code signing enabled in both). All data goes to `~/Library/Containers/com.dmng.timeslice.timeSlice/Data/Library/Application Support/timeSlice/`.

Stored structure:
- `data/YYYY/MM/DD/HHMMSS_xxxx.json` — CaptureRecord (30-day retention)
- `images/YYYY/MM/DD/HHMMSS_xxxx.png` — screenshots (3-day retention)
- `reports/YYYY/MM/DD/` — generated reports

`StoragePathResolver` builds all paths. `DataStore` and `ImageStore` handle persistence and expiry cleanup.

### App Layer (timeSliceApp)

- **`AppState`** (`@MainActor @Observable`): owns all core instances, coordinates UI state, handles capture start/stop and report generation
- **`AppSettings`**: `AppSettingsKey` enum for UserDefaults keys + `AppSettingsResolver` enum with static resolver functions (defaults, clamping, parsing). All settings persisted via `@AppStorage`.
- **`SettingsView`**: `Form` + `grouped` style with 4 tabs (General / Capture / Report / CLI)
- **Menu bar**: `MenuBarExtra` with `.menu` style — standard dropdown (start/stop, single capture, generate report, settings, quit)

### Key Design Patterns

- **Protocol-based DI**: `ScreenCapturing`, `TextRecognizing`, `CLIExecutable` protocols enable mock injection for tests
- **Actor isolation**: `CaptureScheduler` and `DuplicateDetector` are actors for thread safety
- **`@unchecked Sendable`**: Used on `DataStore`, `ImageStore`, `StoragePathResolver`, `CLIExecutor` (value-type structs or classes with only Sendable-safe internal state)

### Concurrency Notes

- Swift 6 strict concurrency mode is active
- The Xcode project has `SWIFT_DEFAULT_ACTOR_ISOLATION` removed from the Core target — only the app target uses `@MainActor` explicitly on UI types
- Code signing is enabled for both Debug and Release builds (App Sandbox active in all configurations)

### Screen Capture Permission

Running via terminal binds screen capture permission to Terminal/iTerm. Build and launch the `.app` bundle for proper permission binding.

## Not Yet Implemented

- `ReportPreviewView` (markdown preview, copy, open in Finder)
- Unit tests for report generation (`PromptBuilder` / `ReportGenerator`)

See `docs/scalable-meandering-mountain.md` for the full plan and `docs/implementation-todo.md` for task checklist.
