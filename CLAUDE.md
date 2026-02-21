# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

timeSlice is a macOS menu bar app that periodically captures the frontmost window, runs OCR, and stores results locally for automated work report generation. Privacy-first design: all data stays local. Menu bar only (no Dock icon via `LSUIElement = YES`).

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
- `CaptureTrigger` enum: `.scheduled` (periodic loop) / `.manual` ("Capture Now" button or global hotkey)
- `CaptureRecord` includes: `windowTitle: String?` and `captureTrigger: CaptureTrigger`

### Report Pipeline

```
ReportGenerator (struct, orchestrator)
  → DataStore.loadRecords(on:timeRange:) — loads daily CaptureRecords (optionally filtered by time range)
  → PromptBuilder.buildDailyReportPrompt(...) — template with {{DATE}}, {{TIME_RANGE}}, {{JSON_GLOB_PATH}}, {{JSON_FILE_LIST}}, {{RECORD_COUNT}}
  → CLIExecutor (runs external AI CLI, e.g. gemini -p "...")
  → saves markdown → GeneratedReport { reportDate, reportFileURL, markdownText, sourceRecordCount, timeSlotLabel? }
```

- **ReportGenerationConfiguration**: runtime params (command, arguments, timeout, outputFileName, outputDirectoryURL, promptTemplate). `withOutputFileName()` returns a copy with different file name
- **CLIExecutor** runs with cwd set to `data/` directory so the AI CLI can read `./YYYY/MM/DD/*.json` directly
- Handles SIGPIPE, PATH injection for GUI context, `-p`/`--prompt` trailing-flag auto-fill, and configurable timeout
- **PromptBuilder** uses file-reference strategy with customizable template (localized default via `NSLocalizedString`)
- **Time slot mode**: always uses glob path (both `{{JSON_GLOB_PATH}}` and `{{JSON_FILE_LIST}}` resolve to same glob). Time filtering is delegated to the AI CLI via `{{TIME_RANGE}}` label (e.g. "08:00-12:00") in the prompt
- **Backup on re-generation**: existing report is backed up as `report-YYYY-MM-DD-HHmmss.md` before overwriting

### Report Scheduling

```
ReportScheduler (actor, auto-generation with time slot support)
  → checks enabled + configured schedule (single time or multiple time slots)
  → ReportGenerator.generate(on:configuration:timeRange:)
  → ReportSchedulerResult (.succeeded / .skippedNoRecords / .failed)
  → ReportNotificationManager (UNUserNotificationCenter)
```

- **Single-time mode**: traditional single daily execution at configured hour/minute
- **Time slot mode**: multiple executions per day, each slot triggers at its `endHour:endMinute`
- `ReportTimeSlot` (Codable, Identifiable): configurable time window with label, start/end times, enable/disable
- `ReportTimeRange`: lightweight filter struct with `contains(_:Date)` for record filtering
- Default slots: Morning (8-12), Afternoon (12-18), Evening (18-24)
- Output naming: `report-0800-1200.md` per slot, `report.md` for full-day
- `snapshot()` returns `ReportSchedulerState` (includes `timeSlots`, `nextTimeSlotLabel`) for UI status display
- Notification on completion — clicking opens the generated report file

### Global Keyboard Shortcuts

- **`GlobalHotKeyManager`** (in AppState.swift): registers system-wide hotkey using Carbon `RegisterEventHotKey` API
- User records shortcut in Settings → General tab via `CaptureNowShortcutRecorderView` (uses `NSEvent.addLocalMonitorForEvents`)
- Modifier key required (⌘/⌥/⌃/⇧). Esc cancels, Delete clears
- Settings keys: `captureNowShortcutKey`, `captureNowShortcutModifiers`, `captureNowShortcutKeyCode`
- Triggers manual capture + shows completion notification

### Notifications

- **Capture completion**: manual captures post notification with app name + window title (or fallback text)
- **Report generation**: both manual and scheduled, showing report file name + record count
- **`ReportNotificationManager`** (nested in AppState): manages `UNUserNotificationCenter` authorization and posting
- **`TimeSliceAppDelegate`** (in timeSliceApp.swift): handles notification click → opens report file via `/usr/bin/open`

### Localization

- Full i18n with `ja.lproj/Localizable.strings` and `en.lproj/Localizable.strings` in `Sources/Resources/`
- `Localization.swift` provides `L10n` enum with `string(_:)` and `format(_:args...)` helpers
- All UI strings, menu items, notifications, and error messages are localized

### Storage Layout

App Sandbox is **disabled** (Hardened Runtime is enabled). All data goes to `~/Library/Application Support/timeSlice/`.

Stored structure:
- `data/YYYY/MM/DD/HHMMSS_xxxx.json` — CaptureRecord (30-day retention)
- `images/YYYY/MM/DD/HHMMSS_xxxx.png` — screenshots (3-day retention)
- `reports/YYYY/MM/DD/report.md` — full-day report (custom output directory supported)
- `reports/YYYY/MM/DD/report-HHMM-HHMM.md` — time-slot report (e.g. `report-0800-1200.md`)

`StoragePathResolver` builds all paths. `DataStore` and `ImageStore` handle persistence and expiry cleanup.

### App Layer (timeSliceApp)

- **`AppState`** (`@MainActor @Observable`): owns all core instances including `ReportScheduler`, `ReportNotificationManager`, and `GlobalHotKeyManager`. Coordinates UI state, handles capture start/stop and report generation
- **`AppSettings`**: `AppSettingsKey` enum for UserDefaults keys + `AppSettingsResolver` enum with static resolver functions (defaults, clamping, parsing). All settings persisted via `@AppStorage`
  - Report settings: `reportTargetDayOffset`, `reportAutoGenerationEnabled`, `reportAutoGenerationHour/Minute`, `reportOutputDirectoryPath`, `reportPromptTemplate`, `reportTimeSlotsEnabled`, `reportTimeSlotsJSON`
  - Shortcut settings: `captureNowShortcutKey`, `captureNowShortcutModifiers`, `captureNowShortcutKeyCode`
  - Startup settings: `startCaptureOnAppLaunchEnabled`, `launchAtLoginEnabled`
- **`SettingsView`**: `Form` + `grouped` style with 4 tabs (General / Capture / CLI / Report). Uses `Window` scene with `defaultSize(width: 700, height: 640)`
- **Menu bar**: `MenuBarExtra` with `.menu` style — standard dropdown (settings, start/stop, capture now with optional keyboard shortcut, generate report, quit)

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
