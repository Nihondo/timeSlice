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

private enum CaptureViewerFocusTarget: Hashable {
    case searchInput
    case captureList
}

struct CaptureViewerView: View {
    @Bindable var appState: AppState

    @AppStorage(AppSettingsKey.captureViewerTimeSortOrder)
    private var selectedTimeSortOrderRawValue = CaptureViewerTimeSortOrder.ascending.rawValue
    @State private var captureViewerDate = Date()
    @State private var selectedCaptureArtifactID: UUID?
    @State private var displayedArtifacts: [CaptureRecordArtifact] = []
    @State private var displayedArtifactsByID: [UUID: CaptureRecordArtifact] = [:]
    @State private var isOCRSectionExpanded = false
    @State private var selectedApplicationFilter: CaptureViewerApplicationFilter = .all
    @State private var selectedCaptureTriggerFilter: CaptureViewerCaptureTriggerFilter = .all
    @State private var searchInputText = ""
    @State private var confirmedSearchQueryText = ""
    @State private var lastAppliedExternalSearchRequestSequence: UInt64 = 0
    @FocusState private var focusedControl: CaptureViewerFocusTarget?

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
                    refreshDisplayedArtifacts()
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
                    refreshDisplayedArtifacts()
                }

                Picker("viewer.label.capture_trigger_filter", selection: $selectedCaptureTriggerFilter) {
                    Text("viewer.value.filter_all_triggers")
                        .tag(CaptureViewerCaptureTriggerFilter.all)
                    Text("viewer.value.filter_manual_only")
                        .tag(CaptureViewerCaptureTriggerFilter.manualOnly)
                }
                .pickerStyle(.menu)
                .onChange(of: selectedCaptureTriggerFilter) { _, _ in
                    refreshDisplayedArtifacts()
                }

                TextField("viewer.placeholder.search_text", text: $searchInputText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220, idealWidth: 300, maxWidth: 360)
                    .focused($focusedControl, equals: .searchInput)
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
                .focused($focusedControl, equals: .captureList)
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
            let didApplyExternalSearchRequest = applyExternalSearchRequestIfNeeded()
            guard appState.captureViewerArtifacts.isEmpty else {
                synchronizeApplicationFilterIfNeeded()
                refreshDisplayedArtifacts()
                if didApplyExternalSearchRequest == false {
                    focusCaptureList()
                }
                return
            }
            loadCaptureViewerArtifacts()
            if didApplyExternalSearchRequest == false {
                focusCaptureList()
            }
        }
        .onChange(of: selectedCaptureArtifactID) { _, _ in
            isOCRSectionExpanded = false
        }
        .onChange(of: appState.captureViewerSearchRequestSequence) { _, _ in
            applyExternalSearchRequestIfNeeded()
        }
        .onChange(of: appState.captureViewerArtifacts) { _, _ in
            synchronizeApplicationFilterIfNeeded()
            refreshDisplayedArtifacts()
        }
    }

    private var availableApplicationNames: [String] {
        let uniqueApplicationNames = Set(appState.captureViewerArtifacts.map(\.record.applicationName))
        return uniqueApplicationNames.sorted { leftName, rightName in
            leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
        }
    }

    private var selectedCaptureArtifact: CaptureRecordArtifact? {
        guard let selectedCaptureArtifactID else {
            return nil
        }
        return displayedArtifactsByID[selectedCaptureArtifactID]
    }

    private func resolveDisplayedArtifacts() -> [CaptureRecordArtifact] {
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
        let matchesBrowserURL = (artifact.record.browserURL ?? "").range(
            of: normalizedSearchQueryText,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        let matchesDocumentPath = (artifact.record.documentPath ?? "").range(
            of: normalizedSearchQueryText,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        return matchesWindowTitle || matchesOCRText || matchesComment || matchesBrowserURL || matchesDocumentPath
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

    private func resolveDisplayText(_ text: String) -> Text {
        if normalizedSearchQueryText.isEmpty {
            Text(text)
        } else {
            Text(resolveHighlightedText(text))
        }
    }

    private func loadCaptureViewerArtifacts() {
        let targetDate = captureViewerDate
        Task { @MainActor in
            await appState.loadCaptureViewerArtifacts(on: targetDate)
            synchronizeApplicationFilterIfNeeded()
            refreshDisplayedArtifacts()
        }
    }

    private func refreshDisplayedArtifacts() {
        let refreshedArtifacts = resolveDisplayedArtifacts()
        displayedArtifacts = refreshedArtifacts
        displayedArtifactsByID = Dictionary(
            uniqueKeysWithValues: refreshedArtifacts.map { artifact in
                (artifact.id, artifact)
            }
        )
        synchronizeSelectedCaptureArtifactIfNeeded()
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
            isOCRSectionExpanded = false
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

            resolveDisplayText(windowTitleText)
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
                    Text("\(L10n.string("viewer.field.window_title")): \(resolveDisplayText(windowTitleText))")
                    if let browserURL = artifact.record.browserURL, browserURL.isEmpty == false {
                        Text("\(L10n.string("viewer.field.browser_url")): \(resolveDisplayText(browserURL))")
                    }
                    if let documentPath = artifact.record.documentPath, documentPath.isEmpty == false {
                        Text("\(L10n.string("viewer.field.document_path")): \(resolveDisplayText(documentPath))")
                    }
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

                DisclosureGroup(isExpanded: $isOCRSectionExpanded) {
                    if isOCRSectionExpanded {
                        if artifact.record.ocrText.isEmpty {
                            Text("viewer.value.empty_text")
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            resolveDisplayText(artifact.record.ocrText)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } label: {
                    Text("viewer.section.ocr")
                        .font(.headline)
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
        refreshDisplayedArtifacts()
    }

    @discardableResult
    private func applyExternalSearchRequestIfNeeded() -> Bool {
        let requestedSequence = appState.captureViewerSearchRequestSequence
        guard requestedSequence != lastAppliedExternalSearchRequestSequence else {
            return false
        }
        lastAppliedExternalSearchRequestSequence = requestedSequence
        searchInputText = appState.captureViewerSearchQuery
        applyCaptureViewerSearchQuery()
        focusedControl = .searchInput
        return true
    }

    private func focusCaptureList() {
        Task { @MainActor in
            focusedControl = .captureList
        }
    }

    @ViewBuilder
    private func captureViewerCommentTextView(comment: String?) -> some View {
        if let comment, comment.isEmpty == false {
            resolveDisplayText(comment)
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
        } else if let imageFileURL = artifact.imageFileURL {
            AsyncImage(url: imageFileURL) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: 160, alignment: .center)
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                case .failure:
                    Text("viewer.message.image_load_failed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                @unknown default:
                    Text("viewer.message.image_load_failed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
