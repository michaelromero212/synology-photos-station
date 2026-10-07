import FrameStationAPI
import Foundation
import Testing

/// The rule the server enforces and the apps follow when they decide whether to
/// offer Remove. It lives in FrameStationAPI so the two can't disagree.
@Suite("Who may remove a photo from a space")
struct SpacePermissionsTests {
    private let me = UUID()
    private let someoneElse = UUID()

    @Test("In a shared album, what you added is yours to remove")
    func ownPhotoInSharedAlbum() {
        #expect(SpacePermissions.mayRemove(kind: .shared, role: .contributor, addedBy: me, user: me))
    }

    @Test("Somebody else's isn't, unless you made the album")
    func othersPhotoInSharedAlbum() {
        #expect(!SpacePermissions.mayRemove(
            kind: .shared, role: .contributor, addedBy: someoneElse, user: me
        ))
        #expect(SpacePermissions.mayRemove(kind: .shared, role: .owner, addedBy: someoneElse, user: me))
    }

    @Test("Everything in your own library is yours")
    func personalLibrary() {
        #expect(SpacePermissions.mayRemove(kind: .personal, role: .owner, addedBy: someoneElse, user: me))
    }

    @Test("Viewers remove nothing, not even what they're credited with")
    func viewers() {
        #expect(!SpacePermissions.mayRemove(kind: .shared, role: .viewer, addedBy: me, user: me))
    }

    @Test("Without knowing who's asking, nothing in a shared album can go")
    func unknownUser() {
        #expect(!SpacePermissions.mayRemove(kind: .shared, role: .contributor, addedBy: nil, user: nil))
    }

    @Test("A space answers for itself the same way")
    func spaceConvenience() {
        let shared = SpaceDTO(id: UUID(), kind: .shared, name: "Family", role: .contributor, memberCount: 3)
        #expect(shared.allowsRemoving(addedBy: me, by: me))
        #expect(!shared.allowsRemoving(addedBy: someoneElse, by: me))
    }
}
