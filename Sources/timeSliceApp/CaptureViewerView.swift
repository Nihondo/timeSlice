import AppKit
import Observation
import SwiftUI

private enum CaptureViewerTimeSortOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String {
        rawValue
    }
}

private enum CaptureViewerApplicationFilter: Hashable {
    case all
    case application(String)
}

private enum CaptureViewerCaptureTriggerFilter: String, CaseIterable, Identifiable {
    case all
    case manualOnly

    var id: String {
        rawValue
    }
}

struct CaptureViewerView: View {
    @Bindable var appState: AppState

    @AppStorage(AppSettingsKey.captureViewerTimeSortOrder)
    private var selectedTimeSortOrderRawValue = CaptureViewerTimeSortOrder.ascending.rawValue
    @State private var captureViewerDate = Date()
    @State private var selectedCaptureArtifactID: UUID?
    @State private var selectedApplicationFilter: CaptureViewerApplicationFilter = .all
    @State private var selectedCaptureTriggerFilter: CaptureViewerCaptureTriggerFilter = .all
    @State private var searchInputText = ""
    @State private var confirmedSearchQueryText = ""

    private var normalizedSearchQueryText: String {
        confirmedSearchQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedTimeSortOrder: CaptureViewerTimeSortOrder {
        get {
            CaptureViewerTimeSortOrder(rawValue: selectedTimeSortOrderRawValue) ?? .ascending
        }
        nonmutating set {
            selectedTimeSortOrderRawValue = newValue.rawValue
        }
    }

    private var selectedTimeSortOrderBinding: Binding<CaptureViewerTimeSortOrder> {
        Binding(
            get: {
                selectedTimeSortOrder
            },
            set: { updatedSortOrder in
                selectedTimeSortOrder = updatedSortOrder
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DatePicker(
                    L10n.string("viewer.label.target_date"),
                    selection: $captureViewerDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .onChange(of: captureViewerDate) { _, _ in
                    loadCaptureViewerArtifacts()
                }

                Picker("viewer.label.sort_order", selection: selectedTimeSortOrderBinding) {
                    Text("viewer.value.sort_ascending")
                        .tag(CaptureViewerTimeSortOrder.ascending)
                    Text("viewer.value.sort_descending")
                        .tag(CaptureViewerTimeSortOrder.descending)
                }
                .pickerStyle(.menu)
                .onChange(of: selectedTimeSortOrderRawValue) { _, _ in
                    synchronizeSelectedCaptureArtifactIfNeeded()
                }

                Picker("viewer.label.application_filter", selection: $selectedApplicationFilter) {
                    Text("viewer.value.filter_all_applications")
                        .tag(CaptureViewerApplicationFilter.all)
                    ForEach(availableApplicationNames, id: \.self) { applicationName in
                        Text(applicationName)
                            .tag(CaptureViewerApplicationFilter.application(applicationName))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedApplicationFilter) { _, _ in
                    synchronizeSelectedCaptureArtifactIfNeeded()
                }

                Picker("viewer.label.capture_trigger_filter", selection: $selectedCaptureTriggerFilter) {
                    Text("viewer.value.filter_all_triggers")
                        .tag(CaptureViewerCaptureTriggerFilter.all)
                    Text("viewer.value.filter_manual_only")
                        .tag(CaptureViewerCaptureTriggerFilter.manualOnly)
                }
                .pickerStyle(.menu)
                .onChange(of: selectedCaptureTriggerFilter) { _, _ in
                    synchronizeSelectedCaptureArtifactIfNeeded()
                }

                TextField("viewer.placeholder.search_text", text: $searchInputText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220, idealWidth: 300, maxWidth: 360)
                    .onSubmit {
                        applyCaptureViewerSearchQuery()
                    }

                Button("viewer.button.reload") {
                    loadCaptureViewerArtifacts()
                }
                .disabled(appState.isLoadingCaptureViewerArtifacts)

                if appState.isLoadingCaptureViewerArtifacts {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Text(L10n.format("viewer.label.record_count", displayedArtifacts.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.captureViewerStatusMessage.isEmpty == false {
                Text(appState.captureViewerStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HSplitView {
                List(selection: $selectedCaptureArtifactID) {
                    ForEach(displayedArtifacts) { artifact in
                        captureViewerRowView(artifact: artifact)
                            .tag(artifact.id)
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)

                Group {
                    if let selectedCaptureArtifact {
                        captureViewerDetailView(artifact: selectedCaptureArtifact)
                    } else {
                        Text("viewer.placeholder.select_record")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .onAppear {
            guard appState.captureViewerArtifacts.isEmpty else {
                synchronizeApplicationFilterIfNeeded()
                synchronizeSelectedCaptureArtifactIfNeeded()
                return
            }
            loadCaptureViewerArtifacts()
        }
        .onChange(of: appState.captureViewerArtifacts) { _, _ in
            synchronizeApplicationFilterIfNeeded()
            synchronizeSelectedCaptureArtifactIfNeeded()
        }
    }

    private var availableApplicationNames: [String] {
        let uniqueApplicationNames = Set(appState.captureViewerArtifacts.map(\.record.applicationName))
        return uniqueApplicationNames.sorted { leftName, rightName in
            leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
        }
    }

    private var displayedArtifacts: [CaptureRecordArtifact] {
        let captureTriggerFilteredArtifacts = appState.captureViewerArtifacts.filter { artifact in
            switch selectedCaptureTriggerFilter {
            case .all:
                return true
            case .manualOnly:
                return artifact.record.captureTrigger == .manual
            }
        }
        let applicationFilteredArtifacts = captureTriggerFilteredArtifacts.filter { artifact in
            switch selectedApplicationFilter {
            case .all:
                return true
            case let .application(applicationName):
                return artifact.record.applicationName == applicationName
            }
        }
        let searchFilteredArtifacts = applicationFilteredArtifacts.filter(matchesSearchQuery)
        return searchFilteredArtifacts.sorted(by: compareCaptureArtifactsByTime)
    }

    private var selectedCaptureArtifact: CaptureRecordArtifact? {
        guard let selectedCaptureArtifactID else {
            return nil
        }
        return displayedArtifacts.first { $0.id == selectedCaptureArtifactID }
    }

    private func compareCaptureArtifactsByTime(_ leftArtifact: CaptureRecordArtifact, _ rightArtifact: CaptureRecordArtifact) -> Bool {
        if leftArtifact.record.capturedAt == rightArtifact.record.capturedAt {
            switch selectedTimeSortOrder {
            case .ascending:
                return leftArtifact.record.id.uuidString < rightArtifact.record.id.uuidString
            case .descending:
                return leftArtifact.record.id.uuidString > rightArtifact.record.id.uuidString
            }
        }
        switch selectedTimeSortOrder {
        case .ascending:
            return leftArtifact.record.capturedAt < rightArtifact.record.capturedAt
        case .descending:
            return leftArtifact.record.capturedAt > rightArtifact.record.capturedAt
        }
    }

    private func matchesSearchQuery(_ artifact: CaptureRecordArtifact) -> Bool {
        guard normalizedSearchQueryText.isEmpty == false else {
            return true
        }

        let matchesWindowTitle = artifact.record.windowTitle?.range(
            of: normalizedSearchQueryText,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        let matchesOCRText = artifact.record.ocrText.range(
            of: normalizedSearchQueryText,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        let matchesComment = (artifact.record.comments ?? "").range(
            of: normalizedSearchQueryText,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        return matchesWindowTitle || matchesOCRText || matchesComment
    }

    private func resolveHighlightedText(_ text: String) -> AttributedString {
        var highlightedText = AttributedString(text)
        guard normalizedSearchQueryText.isEmpty == false else {
            return highlightedText
        }

        var searchRange = text.startIndex..<text.endIndex
        while
            let matchedRange = text.range(
                of: normalizedSearchQueryText,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            ),
            let attributedMatchedRange = Range(matchedRange, in: highlightedText)
        {
            highlightedText[attributedMatchedRange].backgroundColor = Color.yellow.opacity(0.35)
            highlightedText[attributedMatchedRange].foregroundColor = .primary
            searchRange = matchedRange.upperBound..<text.endIndex
        }

        return highlightedText
    }

    private func loadCaptureViewerArtifacts() {
        let targetDate = captureViewerDate
        Task { @MainActor in
            await appState.loadCaptureViewerArtifacts(on: targetDate)
            synchronizeApplicationFilterIfNeeded()
            synchronizeSelectedCaptureArtifactIfNeeded()
        }
    }

    private func synchronizeApplicationFilterIfNeeded() {
        switch selectedApplicationFilter {
        case .all:
            return
        case let .application(applicationName):
            let isApplicationPresent = availableApplicationNames.contains(applicationName)
            if isApplicationPresent == false {
                selectedApplicationFilter = .all
            }
        }
    }

    private func synchronizeSelectedCaptureArtifactIfNeeded() {
        guard displayedArtifacts.isEmpty == false else {
            selectedCaptureArtifactID = nil
            return
        }

        let hasSelectedArtifact = displayedArtifacts.contains { artifact in
            artifact.id == selectedCaptureArtifactID
        }
        if hasSelectedArtifact {
            return
        }
        selectedCaptureArtifactID = displayedArtifacts.first?.id
    }

    @ViewBuilder
    private func captureViewerRowView(artifact: CaptureRecordArtifact) -> some View {
        let windowTitleText = artifact.record.windowTitle?.isEmpty == false
            ? artifact.record.windowTitle ?? ""
            : L10n.string("viewer.value.no_window_title")

        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(Self.captureViewerTimeFormatter.string(from: artifact.record.capturedAt))
                    .font(.system(.body, design: .monospaced))

                captureViewerManualIndicatorView(for: artifact.record.captureTrigger)

                Spacer()

                Label(
                    resolveCaptureImageLinkStateText(artifact.imageLinkState),
                    systemImage: resolveCaptureImageLinkStateIconName(artifact.imageLinkState)
                )
                .labelStyle(.iconOnly)
                .foregroundStyle(resolveCaptureImageLinkStateColor(artifact.imageLinkState))
            }

            Text(artifact.record.applicationName)
                .lineLimit(1)

            Text(resolveHighlightedText(windowTitleText))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func captureViewerDetailView(artifact: CaptureRecordArtifact) -> some View {
        let windowTitleText = artifact.record.windowTitle?.isEmpty == false
            ? artifact.record.windowTitle ?? ""
            : L10n.string("viewer.value.no_window_title")

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.captureViewerDateTimeFormatter.string(from: artifact.record.capturedAt))
                        .font(.headline)
                    captureViewerManualIndicatorView(for: artifact.record.captureTrigger)
                    Spacer(minLength: 0)
                }

                captureViewerSectionSeparator

                Group {
                    Text("\(L10n.string("viewer.field.application_name")): \(artifact.record.applicationName)")
                    Text("\(L10n.string("viewer.field.window_title")): \(Text(resolveHighlightedText(windowTitleText)))")
                }
                .font(.subheadline)

                captureViewerSectionSeparator

                VStack(alignment: .leading, spacing: 8) {
                    Text("viewer.section.image")
                        .font(.headline)
                    captureViewerImagePreview(artifact: artifact)
                }

                captureViewerSectionSeparator

                VStack(alignment: .leading, spacing: 8) {
                    Text("viewer.section.comments")
                        .font(.headline)
                    captureViewerCommentTextView(comment: artifact.record.comments)
                        .font(.body)
                        .textSelection(.enabled)
                }

                captureViewerSectionSeparator

                VStack(alignment: .leading, spacing: 8) {
                    Text("viewer.section.ocr")
                        .font(.headline)
                    if artifact.record.ocrText.isEmpty {
                        Text("viewer.value.empty_text")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(resolveHighlightedText(artifact.record.ocrText))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                captureViewerSectionSeparator

                VStack(alignment: .leading, spacing: 8) {
                    Text("viewer.section.files")
                        .font(.headline)

                    Text(artifact.jsonFileURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    HStack {
                        Button("viewer.button.open_json") {
                            appState.openCaptureViewerFile(artifact.jsonFileURL)
                        }
                        Button("viewer.button.reveal_json") {
                            appState.revealCaptureViewerFile(artifact.jsonFileURL)
                        }
                    }

                    if let imageFileURL = artifact.imageFileURL {
                        Text(imageFileURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        HStack {
                            Button("viewer.button.open_image") {
                                appState.openCaptureViewerFile(imageFileURL)
                            }
                            .disabled(artifact.imageLinkState != .available)

                            Button("viewer.button.reveal_image") {
                                appState.revealCaptureViewerFile(imageFileURL)
                            }
                            .disabled(artifact.imageLinkState != .available)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var captureViewerSectionSeparator: some View {
        Divider()
            .frame(maxWidth: .infinity)
    }

    private func applyCaptureViewerSearchQuery() {
        confirmedSearchQueryText = searchInputText
        synchronizeSelectedCaptureArtifactIfNeeded()
    }

    @ViewBuilder
    private func captureViewerCommentTextView(comment: String?) -> some View {
        if let comment, comment.isEmpty == false {
            Text(resolveHighlightedText(comment))
        } else {
            Text(resolveCaptureCommentText(comment))
        }
    }

    @ViewBuilder
    private func captureViewerManualIndicatorView(for captureTrigger: CaptureTrigger) -> some View {
        if captureTrigger == .manual {
            Text("viewer.value.trigger_manual")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.orange.opacity(0.16))
                )
        }
    }

    @ViewBuilder
    private func captureViewerImagePreview(artifact: CaptureRecordArtifact) -> some View {
        if artifact.imageLinkState == .notCaptured {
            Text("viewer.message.image_not_captured")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if artifact.imageLinkState == .missingOrExpired {
            Text("viewer.message.image_missing_or_expired")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if
            let imageFileURL = artifact.imageFileURL,
            let image = NSImage(contentsOf: imageFileURL)
        {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Text("viewer.message.image_load_failed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resolveCaptureImageLinkStateText(_ imageLinkState: CaptureImageLinkState) -> String {
        switch imageLinkState {
        case .available:
            L10n.string("viewer.value.image_available")
        case .notCaptured:
            L10n.string("viewer.value.image_not_captured")
        case .missingOrExpired:
            L10n.string("viewer.value.image_missing_or_expired")
        }
    }

    private func resolveCaptureImageLinkStateIconName(_ imageLinkState: CaptureImageLinkState) -> String {
        switch imageLinkState {
        case .available:
            "photo"
        case .notCaptured:
            "photo.slash"
        case .missingOrExpired:
            "exclamationmark.triangle"
        }
    }

    private func resolveCaptureImageLinkStateColor(_ imageLinkState: CaptureImageLinkState) -> Color {
        switch imageLinkState {
        case .available:
            .green
        case .notCaptured:
            .secondary
        case .missingOrExpired:
            .orange
        }
    }

    private func resolveCaptureCommentText(_ comment: String?) -> String {
        guard let comment else {
            return L10n.string("viewer.value.no_comment")
        }
        if comment.isEmpty {
            return L10n.string("viewer.value.empty_comment")
        }
        return comment
    }

    private static let captureViewerTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let captureViewerDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

