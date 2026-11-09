import Testing
@testable import ThresholdCore

struct SessionGateTests {
    @Test func uptimeWindow() {
        #expect(SessionGate.shouldRunForExistingSession(uptimeSeconds: 120))
        #expect(!SessionGate.shouldRunForExistingSession(uptimeSeconds: 3600))
        #expect(!SessionGate.shouldRunForExistingSession(uptimeSeconds: 600))
    }

    @Test func eligibleUsers() {
        #expect(!SessionGate.isEligibleUser(nil, ignored: []))
        #expect(!SessionGate.isEligibleUser("", ignored: []))
        #expect(!SessionGate.isEligibleUser("loginwindow", ignored: []))
        #expect(!SessionGate.isEligibleUser("_mbsetupuser", ignored: []))
        #expect(!SessionGate.isEligibleUser("_other", ignored: []))
        #expect(!SessionGate.isEligibleUser("root", ignored: []))
        #expect(!SessionGate.isEligibleUser("svc", ignored: ["svc"]))
        #expect(SessionGate.isEligibleUser("alice", ignored: ["svc"]))
        #expect(SessionGate.isEligibleUser("Svc", ignored: ["svc"]))
    }
}
