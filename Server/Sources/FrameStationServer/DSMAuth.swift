import Foundation
import Vapor

/// Validates DSM credentials against the NAS's own auth API.
///
/// The password reaches this server once, over TLS, and is forwarded to DSM on
/// the **host loopback** — it never crosses the network again and is never
/// written anywhere. On success the caller gets a FrameStation device token,
/// which is what the app actually stores.
///
/// That is the whole point of doing it here rather than in the app: a stolen
/// phone yields a revocable app token, not a NAS account. See ARCHITECTURE.md §2.
struct DSMAuth {
    struct Identity {
        let username: String
        /// DSM's numeric uid, used to chown files placed in the user's home.
        let uid: Int?
        let homeDirectory: String?
    }

    enum Failure: Error, CustomStringConvertible {
        case unreachable(String)
        case badCredentials
        case accountDisabled
        case permissionDenied
        case twoFactorRequired
        case blocked
        case other(Int)

        var description: String {
            switch self {
            case .unreachable(let detail):
                return "Could not reach DSM: \(detail)"
            case .badCredentials:
                return "That DSM username or password is incorrect."
            case .accountDisabled:
                return "That DSM account is disabled."
            case .permissionDenied:
                // 402 is not a bad password — DSM accepted the credentials and
                // then declined to open a session. In practice that is either an
                // account without permission for this application, or a sign-in
                // arriving from outside the LAN that DSM won't grant.
                return """
                    DSM accepted that password but won't allow this account to \
                    sign in from here. Check Control Panel → User → Applications, \
                    and try the NAS's local address while on your home network.
                    """
            case .twoFactorRequired:
                return "That DSM account uses two-step verification. Enter the six-digit code from your authenticator app."
            case .blocked:
                return "DSM has temporarily blocked this address after too many failed attempts."
            case .other(let code):
                return "DSM refused the sign-in (error \(code))."
            }
        }

        /// A wrong password is the user's problem; an unreachable DSM is ours.
        var status: HTTPStatus {
            switch self {
            case .unreachable: return .badGateway
            case .blocked: return .tooManyRequests
            default: return .unauthorized
            }
        }
    }

    let baseURL: String
    let client: any Client
    let logger: Logger

    /// Authenticates, then immediately ends the DSM session — we only wanted to
    /// know the password was right, not to hold a session open.
    func authenticate(
        username: String, password: String, otpCode: String? = nil
    ) async throws -> Identity {
        struct Envelope: Content {
            struct Data: Content { let sid: String? }
            struct ErrorBody: Content { let code: Int }
            let success: Bool
            let data: Data?
            let error: ErrorBody?
        }

        let loginURI = URI(string: "\(baseURL)/webapi/entry.cgi")
        let response: ClientResponse
        do {
            response = try await client.post(loginURI) { request in
                // POST rather than GET: a password in a query string ends up in
                // DSM's access logs.
                var form = URLComponents()
                form.queryItems = [
                    .init(name: "api", value: "SYNO.API.Auth"),
                    .init(name: "version", value: "6"),
                    .init(name: "method", value: "login"),
                    .init(name: "account", value: username),
                    .init(name: "passwd", value: password),
                    // Only when there is one: DSM rejects an empty otp_code
                    // outright rather than ignoring it.
                ] + (otpCode.map { [URLQueryItem(name: "otp_code", value: $0)] } ?? []) + [
                    .init(name: "session", value: "FrameStation"),
                    .init(name: "format", value: "sid"),
                ]
                request.headers.contentType = .urlEncodedForm
                request.body = .init(string: form.percentEncodedQuery ?? "")
            }
        } catch {
            throw Failure.unreachable(String(describing: error))
        }

        guard let envelope = try? response.content.decode(Envelope.self) else {
            throw Failure.unreachable("unexpected response from \(baseURL)")
        }

        guard envelope.success else {
            let code = envelope.error?.code ?? 0
            logger.warning("DSM rejected sign-in for \(username): error \(code)")
            switch code {
            case 400: throw Failure.badCredentials
            case 401: throw Failure.accountDisabled
            case 402: throw Failure.permissionDenied
            case 403, 404, 406: throw Failure.twoFactorRequired
            case 407: throw Failure.blocked
            default: throw Failure.other(code)
            }
        }

        if let sid = envelope.data?.sid {
            await endSession(sid)
        }

        return Identity(
            username: username,
            uid: Self.lookupUID(username),
            homeDirectory: Self.homeDirectory(for: username)
        )
    }

    private func endSession(_ sid: String) async {
        let uri = URI(string:
            "\(baseURL)/webapi/entry.cgi?api=SYNO.API.Auth&version=6&method=logout&session=FrameStation&_sid=\(sid)")
        _ = try? await client.get(uri)
    }

    // MARK: - Local account lookup

    /// Reads the uid from the container's view of the host's passwd database.
    ///
    /// Requires `/etc/passwd` to be shared with the container. Returns nil when
    /// it isn't, in which case files land owned by the container user and
    /// remain readable — just not *owned* by the person in File Station.
    static func lookupUID(_ username: String) -> Int? {
        guard let passwd = try? String(contentsOfFile: "/etc/passwd", encoding: .utf8) else {
            return nil
        }
        for line in passwd.split(separator: "\n") {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[0] == username else { continue }
            return Int(fields[2])
        }
        return nil
    }

    /// DSM homes are `/volume1/homes/<username>`, exposed to the container at
    /// whatever `FRAMESTATION_HOMES_ROOT` points to.
    static func homeDirectory(for username: String) -> String? {
        let root = Environment.get("FRAMESTATION_HOMES_ROOT") ?? "/homes"
        let candidate = "\(root)/\(username)"
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }
}
