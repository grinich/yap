import YapMeetings

@MainActor
extension YapModel {
    /// Drives the real incoming-share controls using only a connected local preview.
    public func showReceivedShareFixture() {
        guard isPreview, meeting.isConnected, let driver = meeting.demoDriver else { return }
        driver.receiveFixtureScreenShares()
        if let sourceID = meeting.receivedShares.first?.id { meeting.selectReceivedShare(sourceID) }
    }

    public func stopReceivedShareFixture() {
        guard isPreview, let driver = meeting.demoDriver else { return }
        driver.stopFixtureScreenShares()
    }
}
