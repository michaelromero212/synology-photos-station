import Foundation
import Testing
@testable import FrameStationKit

@Suite("A failed transfer is classified by whose fault it was")
struct TransferFailureTests {
    @Test("Losing the network never costs the item a retry")
    func transportErrorsAreUnreachable() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff,
            .dataNotAllowed, .badServerResponse, .cancelled,
        ]
        for code in codes {
            #expect(
                TransferFailure.classify(URLError(code)) == .unreachable,
                "URLError.\(code) should not be blamed on the photo"
            )
        }
    }

    /// The split-horizon DNS failure mode: every upload fails at home and none
    /// away from it. Spending the retry budget on that leaves the queue parked
    /// after the DNS is fixed.
    @Test("A certificate the device won't accept is the server's problem")
    func certificateErrorsAreUnreachable() {
        let codes: [URLError.Code] = [
            .secureConnectionFailed, .serverCertificateUntrusted,
            .serverCertificateHasBadDate, .serverCertificateNotYetValid,
            .serverCertificateHasUnknownRoot,
        ]
        for code in codes {
            #expect(TransferFailure.classify(URLError(code)) == .unreachable)
        }
    }

    @Test("An unsendable file is the item's own fault")
    func fileErrorsAreItemFailures() {
        let codes: [URLError.Code] = [
            .badURL, .unsupportedURL, .fileDoesNotExist, .fileIsDirectory,
        ]
        for code in codes {
            #expect(TransferFailure.classify(URLError(code)) == .itemFailed)
        }
    }

    @Test("A NAS restarting mid-deploy costs the queue nothing")
    func serverErrorsAreUnreachable() {
        for status in [500, 502, 503, 504] {
            #expect(TransferFailure.classify(httpStatus: status) == .unreachable)
        }
        #expect(TransferFailure.classify(httpStatus: 408) == .unreachable)
        #expect(TransferFailure.classify(httpStatus: 429) == .unreachable)
    }

    @Test("A stale token stops the run instead of emptying the retry budget")
    func unauthorizedIsAuthentication() {
        #expect(TransferFailure.classify(httpStatus: 401) == .authentication)
        #expect(TransferFailure.classify(FrameStationClientError.notAuthenticated) == .authentication)
    }

    /// Not `.authentication`: signing in again cannot make someone a member of
    /// a space they were removed from, so sending them to the sign-in screen
    /// would be a dead end.
    @Test("Forbidden is a real rejection, not a sign-in problem")
    func forbiddenIsAnItemFailure() {
        #expect(TransferFailure.classify(httpStatus: 403) == .itemFailed)
    }

    @Test("A refused request is the item's fault")
    func clientErrorsAreItemFailures() {
        for status in [400, 404, 409, 413, 422] {
            #expect(TransferFailure.classify(httpStatus: status) == .itemFailed)
        }
    }

    @Test("A captive portal is an outage, not a bad photo")
    func nonHTTPResponsesAreUnreachable() {
        #expect(TransferFailure.classify(FrameStationClientError.notHTTP) == .unreachable)
    }

    @Test("An error we don't recognise stops after three tries rather than forever")
    func unknownErrorsAreItemFailures() {
        struct Mystery: Error {}
        #expect(TransferFailure.classify(Mystery()) == .itemFailed)
        #expect(TransferFailure.classify(FrameStationClientError.invalidURL("x")) == .itemFailed)
    }

    @Test("The HTTP classifier agrees with the wrapped-error one")
    func wrappedStatusesMatchBareStatuses() {
        for status in [401, 403, 408, 429, 500, 503, 400, 404] {
            #expect(
                TransferFailure.classify(
                    FrameStationClientError.http(status: status, reason: nil)
                ) == TransferFailure.classify(httpStatus: status)
            )
        }
    }
}
