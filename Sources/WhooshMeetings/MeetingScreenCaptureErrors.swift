import Foundation
import ScreenCaptureKit

enum MeetingScreenCaptureErrors {
    static func permissionWasDenied(_ error: any Error) -> Bool {
        let failure = error as NSError
        return failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.userDeclined.rawValue
    }
}
