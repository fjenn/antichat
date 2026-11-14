// M5.T10 step 5 (R-040 AC2 event leg; AT-040 AC2 `testCompletionEventPosted` in-process): a finished video job posts
// `MediaJobCompleted{kind: video, chatID}` to the NotificationService interface; the test sink records it. Delivery of
// the system notification is M8 (R-042, R-108; AT-042).
//   make test-unit FILTER=MediaCompletionEventsTests
import Foundation
import Testing
@testable import AntiChatPlatform

@Suite(.serialized) struct MediaCompletionEventsTests {
    @Test func jobResultPostsOneEventToTheService() {
        let sink = RecordingNotificationSink()
        let before = MediaCompletionEvents.service
        defer { MediaCompletionEvents.service = before }
        MediaCompletionEvents.service = sink
        MediaCompletionEvents.jobResult(kind: .video, chatID: "chat-1", jobID: "job-1")
        #expect(sink.events.count == 1)
        let e = sink.events[0]
        #expect(e.kind == .video && e.chatID == "chat-1" && e.jobID == "job-1")
    }

    @Test func eventsKeepTheirOrderAndKind() {
        let sink = RecordingNotificationSink()
        let before = MediaCompletionEvents.service
        defer { MediaCompletionEvents.service = before }
        MediaCompletionEvents.service = sink
        MediaCompletionEvents.jobResult(kind: .video, chatID: "a", jobID: "1")
        MediaCompletionEvents.jobResult(kind: .image, chatID: "b", jobID: "2")
        #expect(sink.events.map(\.chatID) == ["a", "b"] && sink.events.map(\.kind) == [.video, .image])
        let data = try? JSONEncoder().encode(sink.events[0])
        #expect(data.flatMap { try? JSONDecoder().decode(MediaJobCompleted.self, from: $0) } == sink.events[0])
    }

    @Test func defaultServiceOnlyLogs() {
        #expect(MediaCompletionEvents.service is LoggingNotificationService || MediaCompletionEvents.service is RecordingNotificationSink)
        LoggingNotificationService().post(MediaJobCompleted(kind: .video, chatID: "c", jobID: "j"))  // no delivery until M8
    }
}
