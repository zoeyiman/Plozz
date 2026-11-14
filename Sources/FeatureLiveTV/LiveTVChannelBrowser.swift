#if os(tvOS)
import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

/// A channel list owns focus only; the existing playback coordinator owns tuning and renderer lifetime.
struct LiveTVChannelBrowser: View {
    let model: LiveTVPrototypeModel
    let imports: LiveTVPrototypeImportModel
    @Binding var selectedRow: LiveTVGuideRowID?
    let restoreFocusRequest: Int
    let isPresented: Bool
    let libraryCatalog: PrototypeLibraryCatalogRevision?
    let loadLibraryGuide: ((Set<String>, DateInterval) -> Void)?
    let select: (LiveTVGuideRowID) -> Void
    let watch: (LiveTVGuideRowID) -> Void
    let focusChanged: (Bool) -> Void
    let restored: (Int) -> Void
    @FocusState private var focused: LiveTVGuideRowID?
    @State private var pendingFocus: LiveTVGuideRowID?
    @State private var nativeFocusedRow: LiveTVGuideRowID?
    @Environment(\.themePalette) private var palette
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LiveTVGuidePreparationModel.self) private var guidePreparation: LiveTVGuidePreparationModel?
    private struct GuideRequest: Equatable {
        let server: PrototypeServerGuideRequest?
        let cached: PrototypeGuideWindowRequest?
        let library: PrototypeLibraryGuideRequest?
        let preparationRevision: Int
    }

    private var guideRequest: GuideRequest {
        let anchor = model.guideRowIDs.firstIndex(of: selectedRow ?? model.guideRowIDs.first ?? LiveTVGuideRowID(channelID: ""))
        let start = Date(timeIntervalSince1970: floor(model.now.timeIntervalSince1970 / 1800) * 1800)
        let end = start.addingTimeInterval(3 * 3600)
        let active = isPresented && scenePhase == .active
        let sources = Set(imports.serverSources.filter {
            $0.source.isEnabled && $0.availability?.supportsGuide == true && $0.guideFailure != .permissionDenied
        }.map(\.id))
        return GuideRequest(
            server: active ? PrototypeServerGuideRequest(rows: model.guideRowIDs, anchorIndex: anchor,
                references: imports.serverChannelReferences, enabledSourceIDs: sources, from: start, to: end) : nil,
            cached: active ? PrototypeGuideWindowRequest(rows: model.guideRowIDs, anchorIndex: anchor,
                from: start, to: end, sources: imports.guideSources, enabledSourceIDs: imports.enabledSourceIDs,
                mappings: imports.mappingOverrides) : nil,
            library: active ? libraryCatalog.flatMap { PrototypeLibraryGuideRequest(catalog: $0,
                rows: model.guideRowIDs, anchorIndex: anchor, from: start, to: end) } : nil,
            preparationRevision: guidePreparation?.completionRevision ?? 0
        )
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.guideChannels) { row in
                        if row.startsSection {
                            Text(row.section.title)
                                .font(.headline).foregroundStyle(palette.secondaryText)
                                .padding(.top, 12)
                        }
                        channelButton(row)
                    }
                }
                .padding(12)
            }
            .scrollClipDisabled()
            .task(id: restoreFocusRequest) {
                guard restoreFocusRequest > 0 else { return }
                let rows = model.guideChannels
                let target = selectedRow.flatMap { target in rows.first { $0.id == target }?.id } ?? rows.first?.id
                if let target {
                    pendingFocus = target
                    scroll.scrollTo(target, anchor: .center)
                    focused = target
                }
            }
            .onDisappear { focusChanged(false) }
        }
        .focusSection()
        .task(id: guideRequest) {
            let request = guideRequest
            guard request.server != nil || request.cached != nil || request.library != nil else { return }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch is CancellationError { return }
            catch { assertionFailure("Unexpected channel guide settling delay failure"); return }
            if let server = request.server {
                await imports.reloadServerGuides(channelIDs: server.channels.map(\.id), from: server.from,
                                                  to: server.to, into: model, force: false)
            }
            guard !Task.isCancelled else { return }
            if let cached = request.cached {
                await imports.loadGuideWindow(channelIDs: cached.channelIDs, range: cached.range, into: model)
            }
            guard !Task.isCancelled else { return }
            if let library = request.library { loadLibraryGuide?(library.channelIDs, library.range) }
        }
    }

    private func channelButton(_ row: LiveTVGuideChannel) -> some View {
        let channel = row.channel
        let current = model.currentProgram(for: channel.id)
        let next = model.programs(for: channel.id, from: model.now, hours: 6).first { $0.start > model.now }
        return Button { watch(row.id) } label: {
            HStack(spacing: 16) {
                Text(channel.number.formatted(.number.grouping(.never))).font(.caption.monospacedDigit())
                    .foregroundStyle(palette.secondaryText).frame(width: 56)
                PrototypeStationMark(channel: channel, size: 44)
                    .frame(width: 77, height: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: channel.name).font(.headline).lineLimit(1)
                    if let current {
                        Text(verbatim: current.title).font(.subheadline).lineLimit(1)
                        ProgressView(value: current.progress(at: model.now)).tint(palette.primaryText)
                    }
                    if let next {
                        Text(verbatim: next.start.formatted(.dateTime.hour().minute().locale(locale)) + "  " + next.title)
                            .font(.caption).foregroundStyle(palette.secondaryText).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
         .buttonStyle(PrototypeButtonStyle(selected: model.playingChannelID == channel.id, padded: false,
            focusChanged: { ownsFocus in
                guard ownsFocus else {
                    if nativeFocusedRow == row.id { nativeFocusedRow = nil; focusChanged(false) }
                    return
                }
                nativeFocusedRow = row.id
                focusChanged(true)
                selectedRow = row.id
                select(row.id)
                pendingFocus = nil
                restored(restoreFocusRequest)
            }))
        .focused($focused, equals: row.id)
        .id(row.id)
        .onAppear { if pendingFocus == row.id { focused = row.id } }
        .accessibilityIdentifier("live-tv-channel-\(channel.id)")
    }


}

struct LiveTVChannelProgrammeDetails: View {
    let model: LiveTVPrototypeModel
    let channel: LiveTVPrototypeChannel?
    let program: LiveTVPrototypeProgram?
    let watch: () -> Void
    @Environment(\.themePalette) private var palette
    @Environment(\.locale) private var locale

    var body: some View {
        if let channel {
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: channel.number.formatted(.number.grouping(.never)) + " · " + channel.name)
                    .font(.headline).foregroundStyle(palette.secondaryText)
                if let program {
                    Text(verbatim: program.title).font(.title2.weight(.bold))
                    Text(verbatim: program.start.formatted(.dateTime.hour().minute().locale(locale))
                         + " – " + program.end.formatted(.dateTime.hour().minute().locale(locale)))
                        .font(.subheadline).foregroundStyle(palette.secondaryText)
                    ProgressView(value: program.progress(at: model.now)).tint(palette.primaryText)
                    if let summary = program.playerInfo.summary {
                        Text(verbatim: summary).font(.body).foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 18) {
                    Button(action: watch) { Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(PrototypeButtonStyle())
                    Button { model.toggleFavorite(channel.id) } label: {
                        Image(systemName: model.favoriteIDs.contains(channel.id) ? "heart.fill" : "heart")
                    }
                    .buttonStyle(PrototypeButtonStyle())
                    .accessibilityLabel("Favorite")
                }
                ForEach(model.programs(for: channel.id, from: model.now, hours: 6).filter { $0.start > model.now }.prefix(3)) { next in
                    HStack(alignment: .top, spacing: 18) {
                        Text(verbatim: next.start.formatted(.dateTime.hour().minute().locale(locale)))
                            .foregroundStyle(palette.secondaryText)
                        Text(verbatim: next.title)
                    }
                    .font(.subheadline)
                }
            }
            .padding(12)
        }
    }
}
#endif
