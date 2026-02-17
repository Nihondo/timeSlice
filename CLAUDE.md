# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

timeSlice is a macOS menu bar app that periodically captures the frontmost window, runs OCR, and stores results locally for automated work report generation. Privacy-first design: all data stays local.

## Build & Run Commands

This project uses **Xcode only** (no Package.swift).

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

**Note:** `swift build` / `swift test` / `swift run` do NOT work.

## Architecture

**Xcode project (swift-tools-version: 6.2, macOS 14+)** with two targets:

- `TimeSliceCore` — library containing all business logic, fully testable
- `timeSliceApp` — thin executable with SwiftUI MenuBarExtra UI (`.menu` style), depends on TimeSliceCore

### Capture Pipeline

```
CaptureScheduler (actor, periodic loop)
  → ScreenCapturing protocol → ScreenCaptureManager (ScreenCaptureKit)
    → CapturedWindow { image, windowTitle? }
  → TextRecognizing protocol → OCRManager (Vision Framework)
  → DuplicateDetector (actor, hash-based consecutive dedup)
  → DataStore (JSON) + ImageStore (PNG)
```

- `CaptureScheduler.performCaptureCycle(captureTrigger:)` returns `CaptureCycleOutcome` enum (.saved/.skipped/.failed)
- `CaptureTrigger` enum: `.scheduled` (periodic loop) / `.manual` ("Capture Now" button)
- `CaptureRecord` includes: `windowTitle: String?` and `captureTrigger: CaptureTrigger`

### Report Pipeline

```
ReportGenerator (struct, orchestrator)
  → DataStore.loadRecords(on:) — loads daily CaptureRecords
  → PromptBuilder.buildDailyReportPrompt(customTemplate:) — template with {{DATE}}, {{JSON_GLOB_PATH}}, {{RECORD_COUNT}}
  → CLIExecutor (runs external AI CLI, e.g. gemini -p "...")
  → saves markdown → GeneratedReport { reportDate, reportFileURL, markdownText, sourceRecordCount }
```

- **ReportGenerationConfiguration**: runtime params (command, arguments, timeout, outputFileName, outputDirectoryURL, promptTemplate)
- **CLIExecutor** runs with cwd set to `data/` directory so the AI CLI can read `./YYYY/MM/DD/*.json` directly
- Handles SIGPIPE, PATH injection for GUI context, `-p`/`--prompt` trailing-flag auto-fill, and configurable timeout
- **PromptBuilder** uses file-reference strategy with customizable template (localized default via `NSLocalizedString`)
- **Backup on re-generation**: existing `report.md` is backed up as `report-YYYY-MM-DD-HHmmss.md` before overwriting

### Report Scheduling

```
ReportScheduler (actor, daily auto-generation)
  → checks enabled + configured hour/minute
  → ReportGenerator.generate()
  → ReportSchedulerResult (.succeeded / .skippedNoRecords / .failed)
  → ReportNotificationManager (UNUserNotificationCenter)
```

- Configurable schedule (hour 0-23, minute 0-59), enable/disable toggle
- Notification on completion — clicking opens the generated `report.md`

### Storage Layout

App Sandbox is **disabled**. All data goes to `~/Library/Application Support/timeSlice/`.

Stored structure:
- `data/YYYY/MM/DD/HHMMSS_xxxx.json` — CaptureRecord (30-day retention)
- `images/YYYY/MM/DD/HHMMSS_xxxx.png` — screenshots (3-day retention)
- `reports/YYYY/MM/DD/report.md` — generated reports (custom output directory supported)

`StoragePathResolver` builds all paths. `DataStore` and `ImageStore` handle persistence and expiry cleanup.

### App Layer (timeSliceApp)

- **`AppState`** (`@MainActor @Observable`): owns all core instances including `ReportScheduler` and `ReportNotificationManager`, coordinates UI state, handles capture start/stop and report generation
- **`AppSettings`**: `AppSettingsKey` enum for UserDefaults keys + `AppSettingsResolver` enum with static resolver functions (defaults, clamping, parsing). All settings persisted via `@AppStorage`.
  - Report settings: `reportTargetDayOffset`, `reportAutoGenerationEnabled`, `reportAutoGenerationHour/Minute`, `reportOutputDirectoryPath`, `reportPromptTemplate`
- **`SettingsView`**: `Form` + `grouped` style with 4 tabs (General / Capture / CLI / Report)
- **Menu bar**: `MenuBarExtra` with `.menu` style — standard dropdown (start/stop, single capture, generate report, settings, quit)

### Key Design Patterns

- **Protocol-based DI**: `ScreenCapturing`, `TextRecognizing`, `CLIExecutable` protocols enable mock injection for tests
- **Actor isolation**: `CaptureScheduler`, `DuplicateDetector`, `ReportScheduler` are actors for thread safety
- **`@unchecked Sendable`**: Used on `DataStore`, `ImageStore`, `StoragePathResolver`, `CLIExecutor` (value-type structs or classes with only Sendable-safe internal state)

### Concurrency Notes

- Swift 6 strict concurrency mode is active
- The Xcode project has `SWIFT_DEFAULT_ACTOR_ISOLATION` removed from the Core target — only the app target uses `@MainActor` explicitly on UI types
- Code signing is enabled for both Debug and Release builds

### Screen Capture Permission

Running via terminal binds screen capture permission to Terminal/iTerm. Build and launch the `.app` bundle for proper permission binding.

## Not Yet Implemented

- `ReportPreviewView` (markdown preview, copy, open in Finder)
- Unit tests for report generation (`PromptBuilder` / `ReportGenerator`)

See `docs/scalable-meandering-mountain.md` for the full plan and `docs/implementation-todo.md` for task checklist.
