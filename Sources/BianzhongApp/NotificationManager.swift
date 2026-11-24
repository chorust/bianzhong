import BianzhongCore
import Foundation
import UserNotifications

/// Manages macOS `UNUserNotificationCenter` interactive banners (`BZ_APPROVAL_READY` & `BZ_REPLY_READY`).
/// Strictly guarded so non-`.app` test or CLI contexts never touch `UNUserNotificationCenter.current()`.
public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let approvalCategoryID = "BZ_APPROVAL_READY"
    public static let replyCategoryID = "BZ_REPLY_READY"

    public static let actionApproveBG = "APPROVE_BG"
    public static let actionApproveNote = "APPROVE_WITH_NOTE"
    public static let actionCopyOpenFeishu = "COPY_OPEN_FEISHU"
    public static let actionTakeover = "TAKEOVER_TERMINAL"
    public static let actionIgnore = "IGNORE"

    private let orchestrator: Orchestrator
    private let isAppBundle: Bool

    public init(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
        self.isAppBundle = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
        super.init()
    }

    public func setupIfSupported() {
        guard isAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let approveBG = UNNotificationAction(
            identifier: Self.actionApproveBG,
            title: "批准执行",
            options: []
        )
        let approveNote = UNTextInputNotificationAction(
            identifier: Self.actionApproveNote,
            title: "附言并批准...",
            options: [],
            textInputButtonTitle: "发送",
            textInputPlaceholder: "补充约束或执行说明..."
        )
        let copyFeishu = UNNotificationAction(
            identifier: Self.actionCopyOpenFeishu,
            title: "复制并回飞书",
            options: [.foreground]
        )
        let takeover = UNNotificationAction(
            identifier: Self.actionTakeover,
            title: "在终端接管",
            options: [.foreground]
        )
        let ignore = UNNotificationAction(
            identifier: Self.actionIgnore,
            title: "忽略",
            options: [.destructive]
        )

        let approvalCat = UNNotificationCategory(
            identifier: Self.approvalCategoryID,
            actions: [approveBG, approveNote, takeover, ignore],
            intentIdentifiers: [],
            options: []
        )
        let replyCat = UNNotificationCategory(
            identifier: Self.replyCategoryID,
            actions: [copyFeishu, takeover, ignore],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([approvalCat, replyCat])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    public func postNotification(for approval: ApprovalRecord) {
        guard isAppBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = "编钟 · \(approval.title)"
        content.subtitle = approval.provenanceSummary
        content.body = String(approval.proposedAction.prefix(240))
        content.sound = .default
        content.categoryIdentifier = approval.kind == "question" ? Self.replyCategoryID : Self.approvalCategoryID
        content.userInfo = ["approval_id": approval.id]

        let req = UNNotificationRequest(identifier: approval.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    // Show interactive banner even if Bianzhong MenuBar popover happens to be open
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let approvalID = response.notification.request.content.userInfo["approval_id"] as? String else {
            return
        }

        switch response.actionIdentifier {
        case Self.actionApproveBG:
            orchestrator.approve(id: approvalID, comment: nil)
        case Self.actionApproveNote:
            let note = (response as? UNTextInputNotificationResponse)?.userText
            orchestrator.approve(id: approvalID, comment: note)
        case Self.actionCopyOpenFeishu:
            orchestrator.copyAndOpenFeishu(id: approvalID)
        case Self.actionTakeover:
            orchestrator.launchTakeover(for: approvalID)
        case Self.actionIgnore:
            orchestrator.reject(id: approvalID, comment: "Ignored from notification")
        default:
            break
        }
    }
}
