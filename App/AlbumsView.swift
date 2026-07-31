import FrameStationAPI
import FrameStationKit
import SwiftUI

/// Albums — hand-picked collections that cut across dates.
///
/// Not built yet. This says so rather than showing an empty grid with a
/// "Create Album" button that does nothing: albums need a table, endpoints and
/// a picker flow, and a convincing-looking shell would be worse than an honest
/// blank.
struct AlbumsView: View {
    @Bindable var session: AppSession

    var body: some View {
        ContentUnavailableView {
            Label("Albums", systemImage: "rectangle.stack")
        } description: {
            Text("Collections you build by hand, separate from the timeline. Not built yet.")
        }
        .navigationTitle("Albums")
    }
}
