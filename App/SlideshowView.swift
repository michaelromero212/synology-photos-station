#if os(iOS)
import AVKit
import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import SwiftUI

/// What a slideshow plays.
enum SlideshowMode {
    /// Everything from the day, in order — photos held for a few seconds,
    /// videos played through.
    case everything
    /// Only the videos, back to back.
    ///
    /// Not something Synology offers. A day with sixty photos and four clips
    /// is, for most people, four things worth watching and a lot of scrolling
    /// to find them.
    case videosOnly

    var title: String {
        switch self {
        case .everything: "Slideshow"
        case .videosOnly: "Play All Videos"
        }
    }

    var symbol: String {
        switch self {
        case .everything: "play.rectangle"
        case .videosOnly: "film.stack"
        }
    }
}

@Observable
@MainActor
final class SlideshowModel {
    private(set) var items: [TimelineItem] = []
    private(set) var index = 0
    private(set) var player: AVPlayer?
    private(set) var isFinished = false
    var isPaused = false

    /// How long a still photo holds before moving on. Videos run to their end
    /// instead — cutting a clip off at five seconds would be worse than useless.
    static let photoDuration: TimeInterval = 5

    private var advanceTask: Task<Void, Never>?
    private var endObserver: (any NSObjectProtocol)?
    private weak var session: AppSession?

    init(session: AppSession) { self.session = session }

    var current: TimelineItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    func start(with all: [TimelineItem], mode: SlideshowMode, from item: TimelineItem?) {
        switch mode {
        case .everything:
            items = all
            // Begin where the user was looking, not at the top of the day.
            index = item.flatMap { current in all.firstIndex { $0.id == current.id } } ?? 0
        case .videosOnly:
            items = all.filter { $0.mediaType == .video }
            index = 0
        }
        isFinished = items.isEmpty
        advance(to: index)
    }

    func stop() {
        advanceTask?.cancel()
        advanceTask = nil
        clearEndObserver()
        player?.pause()
        player = nil
    }

    func next() { advance(to: index + 1) }
    func previous() { advance(to: max(index - 1, 0)) }

    private func advance(to target: Int) {
        advanceTask?.cancel()
        clearEndObserver()
        player?.pause()
        player = nil

        guard items.indices.contains(target) else {
            isFinished = true
            return
        }
        index = target
        guard let item = current else { return }

        if item.mediaType == .video {
            Task { await playVideo(item) }
        } else {
            advanceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.photoDuration))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.next() }
            }
        }
    }

    private func playVideo(_ item: TimelineItem) async {
        guard let client = session?.client else { next(); return }
        do {
            let playback = try await client.playbackURL(assetID: item.assetID)
            guard index < items.count, items[index].id == item.id else { return }
            let queued = AVPlayer(url: playback.url)
            player = queued
            // Move on when the clip ends rather than after a fixed interval —
            // the whole point of a video slideshow is watching the whole thing.
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: queued.currentItem, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.next() }
            }
            queued.play()
        } catch {
            // A video that won't load shouldn't strand the slideshow.
            next()
        }
    }

    private func clearEndObserver() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}

struct SlideshowView: View {
    @Bindable var session: AppSession
    let items: [TimelineItem]
    let mode: SlideshowMode
    let startingAt: TimelineItem?
    let onDone: () -> Void

    @State private var model: SlideshowModel?
    @State private var showChrome = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let model {
                if let item = model.current {
                    if item.mediaType == .video, let player = model.player {
                        VideoPlayer(player: player)
                            .ignoresSafeArea()
                    } else {
                        SlidePhoto(item: item, loader: session.loader)
                            .id(item.id)
                            .transition(.opacity)
                    }
                } else if model.isFinished {
                    ContentUnavailableView {
                        Label(
                            mode == .videosOnly ? "No videos that day" : "Nothing to play",
                            systemImage: mode.symbol
                        )
                    }
                    .foregroundStyle(.white)
                }
            }

            if showChrome { chrome }
        }
        .statusBarHidden()
        .onTapGesture { withAnimation { showChrome.toggle() } }
        .task {
            let created = SlideshowModel(session: session)
            model = created
            created.start(with: items, mode: mode, from: startingAt)
        }
        .onDisappear { model?.stop() }
        .onChange(of: model?.isFinished) { _, finished in
            if finished == true { onDone() }
        }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button { onDone() } label: {
                    Image(systemName: "xmark")
                        .font(.title3).padding(12)
                        .background(.black.opacity(0.5), in: Circle())
                }
                Spacer()
                if let model, !model.items.isEmpty {
                    Text("\(model.index + 1) of \(model.items.count)")
                        .font(.subheadline)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                }
            }
            .padding()
            Spacer()
        }
        .foregroundStyle(.white)
        .transition(.opacity)
    }
}

/// A still, held for its few seconds. Uses the preview rather than the
/// original: a slideshow is a screen-sized thing and the 2048px render is
/// already on the NAS.
private struct SlidePhoto: View {
    let item: TimelineItem
    let loader: ThumbnailLoader?

    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: item.assetID) {
            image = await loader?.preview(assetID: item.assetID)
        }
    }
}
#endif

#if os(iOS)
/// So `fullScreenCover(item:)` can drive the mode directly.
extension SlideshowMode: Identifiable {
    var id: String { title }
}
#endif
