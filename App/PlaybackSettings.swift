import SwiftUI

/// How videos behave once one finishes.
///
/// This replaced a "Play All Videos" slideshow mode. The mode was the wrong
/// shape for what people actually do: nobody decides in advance to watch a
/// day's clips, they tap the first one and then want the next. So the choice
/// moved out of a menu you have to find and into a preference that changes
/// what the ordinary tap does.
///
/// On by default, because continuing is what the birthday-party case wants —
/// four clips from one afternoon, watched end to end without going back to the
/// grid between each. Off is for someone who opened one video on purpose and
/// doesn't want to be handed another.
enum PlaybackSettings {
    private static let autoPlayKey = "playback.autoPlayNextVideo"

    static var autoPlayNextVideo: Bool {
        get { UserDefaults.standard.object(forKey: autoPlayKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoPlayKey) }
    }
}

/// The toggle, in More.
struct AutoPlayToggle: View {
    @State private var autoPlay = PlaybackSettings.autoPlayNextVideo

    var body: some View {
        Toggle(isOn: $autoPlay) {
            Label("Auto Play Next Video", systemImage: "play.square.stack")
        }
        .onChange(of: autoPlay) { _, new in
            PlaybackSettings.autoPlayNextVideo = new
        }
    }
}
