import FrameStationAPI
import SwiftUI

/// Year / Month / Day, floating above the tab bar.
///
/// One control, two effects: it changes how the server groups the timeline
/// *and* how many photos fit across. They belong together — asking for a year
/// at four across would be a wall of scrolling, and a day at eleven across
/// shows thumbnails too small to recognise.
struct ZoomBar: View {
    @Binding var zoom: TimelineZoom
    let onChange: (TimelineZoom) -> Void

    /// The selected pill morphs between options rather than fading in place —
    /// on iOS 26 that's a glass-to-glass transition inside the shared container,
    /// which is the effect Liquid Glass exists to give. Below 26 the same
    /// namespace drives a plain matched-geometry slide.
    @Namespace private var selectionShape

    var body: some View {
        GlassGroup(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(TimelineZoom.allCases, id: \.self) { option in
                    Button {
                        guard option != zoom else { return }
                        zoom = option
                        onChange(option)
                    } label: {
                        Text(option.title)
                            .font(.subheadline)
                            .fontWeight(zoom == option ? .semibold : .regular)
                            .foregroundStyle(zoom == option ? .primary : .secondary)
                            .padding(.horizontal, 18).padding(.vertical, 7)
                            .background {
                                if zoom == option {
                                    Capsule()
                                        .fill(.quaternary)
                                        .matchedGeometryEffect(
                                            id: "zoomSelection", in: selectionShape
                                        )
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .glassCapsule(interactive: false, fallback: .regularMaterial)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        .animation(.snappy(duration: 0.28), value: zoom)
    }
}

extension TimelineZoom {
    var title: String {
        switch self {
        case .year: "Year"
        case .month: "Month"
        case .day: "Day"
        }
    }

    /// How many photos fit across at this grouping.
    ///
    /// Zooming out means smaller tiles and more of them: a year is for
    /// recognising a season at a glance, a day is for looking at the photos.
    var columns: Int {
        switch self {
        case .year: 11
        case .month: 5
        case .day: 4
        }
    }
}
