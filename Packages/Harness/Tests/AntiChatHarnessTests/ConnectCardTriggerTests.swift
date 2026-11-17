// When the in-chat Connect card answers a message instead of the model (ConnectAppTool.cardApp): only a clear request
// to connect / sign in to an app, or a clear request for the user's own data in an app of a kind that is not connected.
// "My hard drive is full" and "help me plan my schedule" used to get a Connect Google Drive / Calendar card and no
// answer (any sentence with "my <thing>" matched).
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct ConnectCardTriggerTests {
    @Test(arguments: [
        ("let me log into GitHub", "github"),
        ("connect my gmail account please", "gmail"),
        ("sign in to Slack", "slack"),
        ("can you link Notion", "notion"),
        ("log in to Google Calendar", "googlecalendar"),
        ("summarize my latest emails", "gmail"),
        ("Summarise my unread emails", "gmail"),
        ("what's in my inbox?", "gmail"),
        ("check my inbox", "gmail"),
        ("check my mail", "gmail"),
        ("read my last 3 emails", "gmail"),
        ("find my emails from Anna about the invoice", "gmail"),
        ("anything new in my inbox?", "gmail"),
        ("go through my inbox and tell me what's urgent", "gmail"),
        ("show me my calendar for tomorrow", "googlecalendar"),
        ("what's on my calendar today", "googlecalendar"),
        ("What do I have on my schedule this week?", "googlecalendar"),
        ("list my Google Drive files", "googledrive"),
        ("search my drive files for the budget sheet", "googledrive"),
        ("show my open pull requests", "github"),
        ("list my repos", "github"),
        ("send an email to john@example.com saying I'll be late", "gmail"),
        ("please send a quick email to Maria about Friday", "gmail"),
        ("add a meeting with Sam to my calendar tomorrow at 3", "googlecalendar"),
        ("vat mijn laatste e-mails samen", "gmail"),
        ("wat staat er in mijn agenda vandaag", "googlecalendar"),
        ("zeig mir meine neuesten E-Mails", "gmail"),
        ("montre-moi mes derniers e-mails", "gmail"),
        ("muéstrame mi calendario", "googlecalendar"),
        ("resume os meus últimos emails", "gmail"),
    ])
    func clearRequestsShowTheCard(text: String, toolkit: String) {
        #expect(ConnectAppTool.cardApp(text, connected: [])?.toolkit == toolkit)
    }

    @Test(arguments: [
        "My hard drive is full",
        "help me plan my schedule",
        "write an email to my boss asking for a day off",
        "what should I put in my email signature",
        "my calendar is a mess, any tips?",
        "I need to clear my schedule next week",
        "how do I check my email on an iPhone?",
        "check my email for typos: Hi John, see you tomorow",
        "my drive to work takes an hour",
        "back up my drive to an external disk",
        "show me how to organize my inbox",
        "explain how email works",
        "can you recommend a calendar app",
        "My schedule is packed and I feel burned out",
        "what's the best way to manage my emails",
        "connect the dots for me",
        "how do I log into github from the terminal?",
        "connect github and slack",
        "tell me a joke about emails",
        "Why is my inbox always full?",
        "I drive my kids to school every morning",
        "summarize this article about calendar reform",
        "my repos are too big, how do I shrink a git repository",
        "sign in",
        "make me a weekly schedule for the gym",
        "is my email password strong enough?",
        "read my mind",
        "find my phone",
        "mijn harde schijf is vol",
        "schreibe eine E-Mail an meinen Chef",
        "list the pros and cons of a shared calendar",
        "search the web for my email provider's outage status",
        "how do I send an email to a group in Outlook?",
        "check my schedule template",
        "help me find time in my calendar for exercise",
        "check my drive for errors",
        "write a linear regression",
        "connect to my company VPN",
    ])
    func ordinaryMessagesGoToTheModel(text: String) {
        #expect(ConnectAppTool.cardApp(text, connected: []) == nil, "\(text) → \(String(describing: ConnectAppTool.cardApp(text, connected: [])))")
    }

    @Test func aConnectedAppOfThatKindMeansNoCard() {
        #expect(ConnectAppTool.cardApp("summarize my latest emails", connected: ["gmail"]) == nil)
        #expect(ConnectAppTool.cardApp("summarize my latest emails", connected: ["outlook"]) == nil)
        #expect(ConnectAppTool.cardApp("send an email to sam@example.com", connected: ["outlook"]) == nil)
        #expect(ConnectAppTool.cardApp("summarize my latest emails", connected: ["github"])?.toolkit == "gmail")
        #expect(ConnectAppTool.cardApp("summarize my latest emails", connected: [])?.direct == false)
        #expect(ConnectAppTool.cardApp("let me log into GitHub", connected: [])?.direct == true)
        // The loose rule still only keeps `connect_app` offered (the model decides), it no longer shows the card.
        #expect(ComposioApps.cued(in: "My hard drive is full") == ["googledrive"])
        #expect(ComposioApps.requested(in: "My hard drive is full").isEmpty)
    }
}
