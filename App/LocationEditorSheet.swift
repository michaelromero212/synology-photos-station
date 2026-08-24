import FrameStationAPI
import FrameStationKit
import SwiftUI
#if canImport(MapKit)
import MapKit
#endif

#if !os(tvOS)

/// Saying where a photo was taken, when the file won't.
///
/// Two cases, both ordinary in a family library. Scans and old imports carry no
/// GPS at all, so they are unfindable by place however clearly you remember
/// standing there. And a phone occasionally records a position that is simply
/// wrong — a stale fix from the last place it had signal — which is worse than
/// nothing, because it puts the photo somewhere confidently.
///
/// Searching by name rather than dropping a pin: nobody knows the coordinates of
/// their grandmother's house, but everybody can type the town. The map is there
/// to confirm the guess, not to make it.
///
/// The place *name* is deliberately not sent. The server derives it from the
/// coordinates using the same geocoder that named every other photo, so what you
/// see here is what search will match on — a name typed by the client would be
/// a place you could read and never find.
struct LocationEditorSheet: View {
    let session: AppSession
    let spaceID: UUID
    let assetID: UUID
    let current: (latitude: Double, longitude: Double)?
    let currentName: String?
    let onFinished: (Bool) -> Void

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var chosen: MKMapItem?
    @State private var isSearching = false
    @State private var isSaving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                if let chosen {
                    previewSection(chosen)
                }
                searchSection
                if !results.isEmpty { resultsSection }
                if current != nil && chosen == nil { clearSection }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle("Location")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinished(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(chosen?.placemark.coordinate) }
                        .disabled(chosen == nil)
                }
            }
        }
    }

    // MARK: - Sections

    private func previewSection(_ item: MKMapItem) -> some View {
        Section {
            let coordinate = item.placemark.coordinate
            Map(initialPosition: .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                )
            )) {
                Marker(item.name ?? "", coordinate: coordinate)
            }
            .frame(height: 160)
            .listRowInsets(EdgeInsets())
            .allowsHitTesting(false)

            Text(Self.describe(item))
                .font(.subheadline.weight(.medium))
        } footer: {
            // Named honestly: the app cannot promise what the server's geocoder
            // will call this until it has asked it.
            Text("The photo will be filed under the nearest place name your NAS knows.")
        }
    }

    private var searchSection: some View {
        Section {
            HStack {
                TextField("Search for a place", text: $query)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                if isSearching { ProgressView() }
            }
            // Searches as you type, like Apple's own place picker. Waiting for
            // a Return would be a hidden step: the field is the whole interface
            // here, and nothing on screen says it needs submitting.
            .task(id: query) {
                // Long enough that "Cu" doesn't fire a search, and a pause long
                // enough to be a pause rather than the gap between two letters.
                guard query.trimmingCharacters(in: .whitespaces).count >= 3 else {
                    results = []
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await search()
            }
        } header: {
            Text("Where was this taken?")
        } footer: {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty,
               results.isEmpty, chosen == nil, !isSearching {
                Text("No places match that yet.")
            } else if let currentName, chosen == nil {
                Text("Currently filed under \(currentName).")
            } else if current == nil && chosen == nil {
                Text("This photo has no location, so it can't be found by place.")
            }
        }
    }

    private var resultsSection: some View {
        Section("Results") {
            ForEach(results, id: \.self) { item in
                Button {
                    chosen = item
                    results = []
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "Unnamed place")
                            Text(Self.describe(item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    // A row of place names is a list to read, not a row of
                    // links: tinting every one makes the list harder to scan
                    // and says nothing, since they are all equally tappable.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var clearSection: some View {
        Section {
            Button(role: .destructive) {
                save(nil)
            } label: {
                Text("Remove Location")
            }
        } footer: {
            Text("For a photo whose recorded position is wrong and whose real one nobody knows.")
        }
    }

    // MARK: - Behaviour

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSearching = true
        failure = nil
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        // Biased towards the photo's existing position when it has one, so
        // correcting a nearby mistake doesn't offer the same town on another
        // continent first.
        if let current {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: current.latitude, longitude: current.longitude
                ),
                span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2)
            )
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            results = response.mapItems
        } catch {
            failure = "Couldn't search for places right now."
        }
    }

    private func save(_ coordinate: CLLocationCoordinate2D?) {
        guard let client = session.client else { return }
        isSaving = true
        failure = nil
        Task {
            defer { isSaving = false }
            do {
                _ = try await client.setLocation(
                    spaceID: spaceID, assetID: assetID,
                    latitude: coordinate?.latitude, longitude: coordinate?.longitude
                )
                onFinished(true)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// "Culpeper, Virginia" rather than a postal address: the grid's date
    /// headers speak in towns, and this should agree with them.
    static func describe(_ item: MKMapItem) -> String {
        let placemark = item.placemark
        let parts = [placemark.locality, placemark.administrativeArea, placemark.country]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

#endif
