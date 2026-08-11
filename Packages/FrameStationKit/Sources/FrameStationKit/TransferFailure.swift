import Foundation

/// Why a transfer failed, in the only terms the queue cares about: whose fault
/// it was.
///
/// The distinction exists because the backup queue caps retries per item, and
/// that cap is only meaningful for failures the item itself caused. A phone
/// that goes through a tunnel with three hundred photos queued would otherwise
/// spend every item's entire retry budget in the seconds before the engine
/// notices, and park the lot — still parked once the phone is back on Wi-Fi,
/// until somebody finds the Retry button. Losing the network is not a fact
/// about a photo.
public enum TransferFailure: Equatable, Sendable {
    /// The network or the server is unavailable. Costs the item nothing, and
    /// the run stops rather than marching the rest of the queue into the same
    /// wall.
    case unreachable

    /// The token is no longer good. Also free — retrying is pointless until
    /// somebody signs in again, and burning the queue down in the meantime
    /// means a re-sign-in still leaves hundreds of items needing a manual
    /// retry.
    case authentication

    /// This item failed on its own merits. Counts against its retry cap, which
    /// is what stops one bad photo blocking everything behind it.
    case itemFailed
}

extension TransferFailure {
    /// Classifies anything the upload path can throw.
    ///
    /// Unrecognised errors are treated as the item's fault. That is the
    /// conservative direction: a misfiled item stops after three attempts,
    /// whereas a misfiled outage retries forever.
    public static func classify(_ error: any Error) -> TransferFailure {
        if let client = error as? FrameStationClientError {
            switch client {
            case .notAuthenticated:
                return .authentication
            case .http(let status, _):
                return classify(httpStatus: status)
            case .notHTTP:
                // A captive portal answering with a login page, or a proxy
                // returning something that isn't HTTP at all. The server never
                // saw this request.
                return .unreachable
            case .invalidURL:
                return .itemFailed
            }
        }
        if let url = error as? URLError {
            return classify(url)
        }
        return .itemFailed
    }

    /// The status-code half, so callers holding a bare status — the chunk
    /// uploader reports one without wrapping it — classify the same way.
    public static func classify(httpStatus status: Int) -> TransferFailure {
        switch status {
        case 401:
            return .authentication
        case 408, 429:
            return .unreachable
        case 500...599:
            // Including the whole 5xx range on purpose: a NAS mid-`docker
            // compose up` serves 502s for a minute or two, and that must not
            // cost the queue anything.
            return .unreachable
        default:
            // 4xx other than the two above is the server refusing this
            // particular request, which retrying will not change. 403 lands
            // here rather than under `.authentication` because "you are not a
            // contributor to this space" is a real rejection, not a stale
            // token, and telling someone to sign in again would send them
            // somewhere that cannot help.
            return .itemFailed
        }
    }

    private static func classify(_ error: URLError) -> TransferFailure {
        switch error.code {
        case .badURL, .unsupportedURL, .fileDoesNotExist, .fileIsDirectory,
             .dataLengthExceedsMaximum:
            // About the thing being sent, not about the path to the server.
            return .itemFailed
        default:
            // Everything else `URLError` describes is transport: no route, no
            // DNS, no route to that host, a dropped connection, a timeout, a
            // certificate the device won't accept. None of it is evidence
            // about the photo.
            //
            // Certificates are deliberately in this bucket. A split-horizon DNS
            // misconfiguration makes every upload fail with a trust error at
            // home and none away from it, and a queue that spent its retries on
            // that would stay broken after the DNS was fixed.
            return .unreachable
        }
    }
}
