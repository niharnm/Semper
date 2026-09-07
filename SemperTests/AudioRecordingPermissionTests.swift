import Testing
@testable import Semper

@Suite("Audio recording permission")
@MainActor
struct AudioRecordingPermissionTests {
    @Test("Repeated requests share one in-flight system request")
    func coalescesConcurrentRequests() async {
        var completions: [(Bool) -> Void] = []
        let permission = AudioRecordingPermission { completion in
            completions.append(completion)
        }
        permission.status = .unknown

        permission.request()
        permission.request()

        #expect(completions.count == 1)
        completions[0](true)
        await Task.yield()
        #expect(permission.status == .authorized)
    }
}
