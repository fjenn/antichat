// M8.T12 / AT-108 (R-108 AC1): the full truth table — 3 modes × 4 groups (5 categories) × app active/inactive ×
// main window key or not × the event's chat visible or not, plus each category toggle off.
import Foundation
import Testing

@testable import AntiChatPlatform

@Suite struct NotificationPolicyTests {
    /// The rule, written out independently of the implementation (M8.md step 3).
    static func expected(_ when: NotifyWhen, _ c: NotificationCategory, groupOn: Bool, active: Bool, key: Bool, visible: Bool) -> Bool {
        guard groupOn else { return false }
        switch when {
        case .never: return false
        case .always: return true
        case .unfocused:
            let unfocused = !active || !key
            let otherChat = (c == .answer || c == .image || c == .video) && !visible
            return unfocused || otherChat
        }
    }

    @Test func fullTruthTable() {
        var rows = 0
        for when in NotifyWhen.allCases {
            for c in NotificationCategory.allCases {
                for groupOn in [true, false] {
                    var groups = Set(NotificationGroup.allCases)
                    if !groupOn { groups.remove(c.group) }
                    let p = NotificationPolicy(when: when, groups: groups)
                    for active in [true, false] {
                        for key in [true, false] {
                            for visible in [true, false] {
                                let f = NotificationPolicy.Focus(appActive: active, mainWindowKey: key, chatVisible: visible)
                                #expect(p.shouldNotify(c, focus: f)
                                        == Self.expected(when, c, groupOn: groupOn, active: active, key: key, visible: visible),
                                        "\(when) \(c) group=\(groupOn) active=\(active) key=\(key) visible=\(visible)")
                                rows += 1
                            }
                        }
                    }
                }
            }
        }
        #expect(rows == 3 * 5 * 2 * 2 * 2 * 2)
    }

    @Test func defaultsAreUnfocusedAndEveryGroupOn() {
        let p = NotificationPolicy()
        #expect(p.when == .unfocused)
        #expect(p.groups == Set(NotificationGroup.allCases))
        let focusedOnChat = NotificationPolicy.Focus(appActive: true, mainWindowKey: true, chatVisible: true)
        #expect(!p.shouldNotify(.answer, focus: focusedOnChat), "looking at the chat: no notification")
        let otherApp = NotificationPolicy.Focus(appActive: false, mainWindowKey: false, chatVisible: true)
        #expect(NotificationCategory.allCases.allSatisfy { p.shouldNotify($0, focus: otherApp) })
    }

    @Test func groupsMapToCategories() {
        #expect(NotificationCategory.answer.group == .responses)
        #expect(NotificationCategory.image.group == .media && NotificationCategory.video.group == .media)
        #expect(NotificationCategory.download.group == .downloads)
        #expect(NotificationCategory.update.group == .updates)
        let mediaOff = NotificationPolicy(when: .always, groups: [.responses, .downloads, .updates])
        let f = NotificationPolicy.Focus(appActive: false, mainWindowKey: false, chatVisible: false)
        #expect(!mediaOff.shouldNotify(.image, focus: f) && !mediaOff.shouldNotify(.video, focus: f))
        #expect(mediaOff.shouldNotify(.answer, focus: f))
    }
}
