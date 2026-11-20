import ServiceManagement
import Testing

@testable import RunningOutUI

@Suite("Login item status")
struct LoginItemStatusTests {
    /// A fresh install has no Background Task Management record yet, so `SMAppService` reports `.notFound` until the
    /// first `register()`. Treating that as unavailable disabled the toggle for every new user (v0.1.0).
    @Test func neverRegisteredReadsAsOff() {
        #expect(LoginItemStatus(SMAppService.Status.notFound) == .disabled)
    }

    @Test func otherStatusesKeepTheirMeaning() {
        #expect(LoginItemStatus(SMAppService.Status.enabled) == .enabled)
        #expect(LoginItemStatus(SMAppService.Status.notRegistered) == .disabled)
        #expect(LoginItemStatus(SMAppService.Status.requiresApproval) == .requiresApproval)
    }
}
