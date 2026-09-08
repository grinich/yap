import Foundation
import Testing
import YapOAuth

@Suite("Sign-in completion page")
struct OAuthCompletionPageTests {
    @Test(arguments: OAuthCompletionPage.Provider.allCases, OAuthCompletionPage.Outcome.allCases)
    func pageHasOnlyLocalContentAndAnExplicitAppLink(_ provider: OAuthCompletionPage.Provider, _ outcome: OAuthCompletionPage.Outcome) {
        let page = OAuthCompletionPage(provider: provider, outcome: outcome)
        #expect(page.body.contains("href=\"yap://open\""))
        #expect(page.body.contains("history.replaceState(null, \"\", location.pathname)"))
        #expect(!page.body.contains("http://"))
        #expect(!page.body.contains("https://"))
        #expect(!page.body.contains("window.location="))
        #expect(page.contentSecurityPolicy.contains("default-src 'none'"))
        #expect(page.contentSecurityPolicy.contains("frame-ancestors 'none'"))
        #expect(!page.contentSecurityPolicy.contains("unsafe-inline"))
        #expect(page.body.contains("prefers-reduced-motion"))
    }

    @Test(arguments: OAuthCompletionPage.Provider.allCases)
    func callbackDoesNotClaimTokenExchangeAlreadySucceeded(_ provider: OAuthCompletionPage.Provider) {
        let page = OAuthCompletionPage(provider: provider, outcome: .received)
        #expect(page.body.contains("as soon as your connection is ready"))
        #expect(!page.body.contains("Calendar connected"))
        #expect(!page.body.contains("Sign-in complete"))
    }

    @Test func responseNoncesAreUniqueAndMatchStyleAndScript() throws {
        let first = OAuthCompletionPage(provider: .googleCalendar, outcome: .received)
        let second = OAuthCompletionPage(provider: .googleCalendar, outcome: .received)
        #expect(first.contentSecurityPolicy != second.contentSecurityPolicy)
        let nonce = try #require(first.contentSecurityPolicy.components(separatedBy: "'nonce-").dropFirst().first?.components(separatedBy: "'").first)
        #expect(first.body.contains("<style nonce=\"\(nonce)\">"))
        #expect(first.body.contains("<script nonce=\"\(nonce)\">"))
    }
}
