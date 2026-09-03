import FrameStationAPI
import SwiftUI
#if canImport(MapKit)
import MapKit
#endif

/// The Information panel, modelled on Apple Photos.
///
/// Deliberately richer than Synology's, which shows no camera, no lens, no
/// exposure and no map at all. And it carries one row neither reference app
/// has: **Added by**, which is the whole point of a shared family library.
/// See ARCHITECTURE.md §9a.
struct InformationPanel: View {
    let detail: AssetDetail
    /// Supplied by hosts that can actually apply a correction. Nil leaves the
    /// row as a plain statement — the panel stays presentational and doesn't
    /// need a client of its own.
    var onEditCredit: (() -> Void)?
    /// Supplied by hosts that can apply a location. Nil leaves the map as a
    /// picture, and hides the "add a location" row entirely — there is no point
    /// inviting an edit the panel cannot carry out.
    var onEditLocation: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                caption
                dateBlock
                tagRow
                // Suppressed in a personal space — "added by me" is noise.
                if detail.isSharedSpace { addedBy }
                cameraCard
                #if !os(tvOS)
                if detail.latitude != nil {
                    mapCard
                } else if onEditLocation != nil {
                    addLocationRow
                }
                #endif
                storageRow
                // Everything the file itself records, below the curated card:
                // grouped, filtered and formatted by the server so this is a
                // plain column of sections rather than a wall of tags.
                if !detail.groups.isEmpty {
                    metadataSections
                }
            }
            .padding(20)
        }
    }

    // MARK: - Extended metadata

    /// The full technical dump, as a column of titled sections.
    ///
    /// A label column and a value column, the way Synology and Finder's Get Info
    /// both lay it out — the labels scan down the left, the values read across.
    /// Values are selectable so a coordinate or a serial number can be copied
    /// out; the server has already dropped the binary blobs and filesystem noise
    /// that would make this overwhelming.
    private var metadataSections: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(detail.groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 9) {
                    Text(group.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.5)

                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(entry.label)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 118, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(entry.value)
                                    .font(.footnote)
                                    #if !os(tvOS)
                                    .textSelection(.enabled)
                                    #endif
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Caption

    @ViewBuilder
    private var caption: some View {
        if let text = detail.description, !text.isEmpty {
            Text(text).font(.body)
        } else {
            Text("Add a Caption")
                .font(.body)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Date

    private var dateBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.longDate(detail.capturedAt, offset: detail.capturedTZOffset))
                .font(.headline)
            if let filename = detail.filename {
                Text(filename).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }


    // MARK: - Tags

    /// Absent entirely when there are none, rather than an empty row.
    @ViewBuilder
    private var tagRow: some View {
        if !detail.tags.isEmpty {
            // Horizontally scrolled rather than wrapped: a photo with twelve
            // tags shouldn't push the camera card off screen.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(detail.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Added by

    /// Tappable when the host offers a way to correct it.
    ///
    /// Worth being able to fix: a phone handed round at a birthday uploads under
    /// whoever is signed in, and a shared iPad backs up the whole household
    /// under one account. The upload record is right in both cases and the name
    /// on the photo is wrong.
    private var addedBy: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.tint.opacity(0.2))
                .frame(width: 34, height: 34)
                .overlay(
                    Text(String(detail.uploadedBy.displayName.prefix(1)))
                        .font(.headline)
                        .foregroundStyle(.tint)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Added by \(detail.uploadedBy.displayName)")
                    .font(.subheadline.weight(.medium))
                Text(detail.uploadedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if onEditCredit != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onEditCredit?() }
    }

    // MARK: - Camera card

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Self.cameraTitle(detail))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(Self.formatBadge(detail.mime))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }

            if let lensLine = Self.lensLine(detail) {
                Text(lensLine).font(.footnote).foregroundStyle(.secondary)
            }

            HStack {
                Text(Self.sizeLine(detail)).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if let range = detail.dynamicRange {
                    Text(range.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .overlay(Capsule().stroke(.tertiary))
                }
            }

            let exposure = Self.exposureFields(detail)
            if !exposure.isEmpty {
                Divider()
                HStack(spacing: 0) {
                    ForEach(Array(exposure.enumerated()), id: \.offset) { index, field in
                        if index > 0 {
                            Divider().frame(height: 14)
                        }
                        Text(field)
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Map

    #if canImport(MapKit) && !os(tvOS)
    @ViewBuilder
    private var mapCard: some View {
        if let latitude = detail.latitude, let longitude = detail.longitude {
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            VStack(alignment: .leading, spacing: 0) {
                Map(initialPosition: .region(
                    MKCoordinateRegion(
                        center: coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    )
                )) {
                    Marker("", coordinate: coordinate)
                }
                .frame(height: 170)
                .allowsHitTesting(false)

                HStack {
                    // Null until reverse geocoding lands; falls back to raw
                    // coordinates rather than showing an empty row.
                    Text(detail.placeName ?? String(format: "%.4f, %.4f", latitude, longitude))
                        .font(.footnote.weight(.medium))
                    Spacer()
                }
                .padding(12)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture { onEditLocation?() }
        }
    }

    /// The invitation when a photo has no location at all.
    ///
    /// Worth a row of its own rather than nothing: a photo with no place is
    /// invisible to search by place, and there is no other hint anywhere that
    /// this is fixable. Scans and old imports are exactly the pictures people
    /// most want to find again.
    private var addLocationRow: some View {
        Button {
            onEditLocation?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add a Location")
                        .font(.subheadline.weight(.medium))
                    Text("This photo has none, so it can't be found by place.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        }
        .tint(.primary)
    }
    #endif

    // MARK: - Storage

    private var storageRow: some View {
        HStack(spacing: 10) {
            Image(systemName: detail.onDevice ? "checkmark.icloud" : "externaldrive.badge.checkmark")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(detail.onDevice ? "Backed up" : "Archived")
                    .font(.subheadline.weight(.medium))
                Text(detail.onDevice
                     ? "On this device and on your NAS"
                     : "On your NAS only — removed from this device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Formatting

    /// `Saturday · Jul 4, 2026 · 3:55 PM` in the timezone the photo was taken.
    static func longDate(_ date: Date?, offset: Int?) -> String {
        guard let date else { return "Date unknown" }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEEE · MMM d, yyyy · h:mm a"
        formatter.timeZone = offset.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
        return formatter.string(from: date)
    }

    /// The camera that took it, or — when nothing did — what it is.
    ///
    /// Apple titles this card with the camera ("iPhone 15 Pro") and falls back
    /// to the *kind* when there is no camera: a screenshot says "Screenshot", a
    /// panorama "Panorama", a Live Photo "Live Photo". Falling back to a bare
    /// "Photo" threw that away — the one useful thing a screenshot's card can
    /// say is that it is a screenshot.
    static func cameraTitle(_ detail: AssetDetail) -> String {
        [detail.cameraMake, detail.cameraModel]
            .compactMap { $0 }
            .joined(separator: " ")
            .ifEmpty(detail.kind)
    }

    /// `Main Camera — 24 mm ƒ1.78`
    static func lensLine(_ detail: AssetDetail) -> String? {
        var parts: [String] = []
        if let lens = detail.lens { parts.append(lens) }
        var optics: [String] = []
        if let focal = detail.focalLength { optics.append("\(Int(focal.rounded())) mm") }
        if let aperture = detail.aperture { optics.append("ƒ\(Self.trim(aperture))") }
        if !optics.isEmpty { parts.append(optics.joined(separator: " ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    /// `24 MP • 4284 × 5712 • 6.2 MB`
    static func sizeLine(_ detail: AssetDetail) -> String {
        var parts: [String] = []
        if let megapixels = detail.megapixels, megapixels >= 0.1 {
            parts.append("\(Self.trim(megapixels)) MP")
        }
        if let width = detail.width, let height = detail.height {
            parts.append("\(width) × \(height)")
        }
        parts.append(Self.bytes(detail.byteSize))
        if let duration = detail.durationMs {
            parts.append(PhotoCell.formatDuration(duration))
        }
        return parts.joined(separator: " • ")
    }

    /// `ISO 64 | 24 mm | 0 ev | ƒ1.78 | 1/268 s`
    static func exposureFields(_ detail: AssetDetail) -> [String] {
        var fields: [String] = []
        if let iso = detail.iso { fields.append("ISO \(iso)") }
        if let focal = detail.focalLength { fields.append("\(Int(focal.rounded())) mm") }
        if let bias = detail.exposureBias { fields.append("\(Self.trim(bias)) ev") }
        if let aperture = detail.aperture { fields.append("ƒ\(Self.trim(aperture))") }
        if let shutter = detail.shutter { fields.append(shutter) }
        return fields
    }

    static func formatBadge(_ mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg": return "JPEG"
        case "image/heic", "image/heif": return "HEIC"
        case "image/png": return "PNG"
        case "video/quicktime": return "MOV"
        case "video/mp4": return "MP4"
        case "image/x-adobe-dng", "image/dng": return "DNG"
        default: return mime.split(separator: "/").last?.uppercased() ?? "FILE"
        }
    }

    static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var amount = Double(value), unit = 0
        while amount >= 1024, unit < units.count - 1 { amount /= 1024; unit += 1 }
        return String(format: unit <= 1 ? "%.0f %@" : "%.1f %@", amount, units[unit])
    }

    /// Drops trailing zeros so `24.0` reads `24`, while keeping real precision:
    /// an ƒ1.78 lens must not be rendered as ƒ1.8. `%g` formatting is wrong here
    /// because it counts *significant* digits, not decimal places.
    static func trim(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespaces).isEmpty ? fallback : self
    }
}
