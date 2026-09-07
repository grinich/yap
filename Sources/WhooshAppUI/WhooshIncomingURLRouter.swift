import Foundation

@MainActor
final class WhooshIncomingURLRouter {
    private var handle: ((URL) -> Void)?
    private var pending: URL?

    func configure(handle: @escaping (URL) -> Void) {
        self.handle = handle
        if let pending {
            self.pending = nil
            handle(pending)
        }
    }

    func receive(_ urls: [URL]) {
        // The app has one join sheet. The latest invitation is the user's current
        // destination; never queue multiple meetings to join after launch.
        guard let url = urls.last else { return }
        if let handle { handle(url) }
        else { pending = url }
    }
}
