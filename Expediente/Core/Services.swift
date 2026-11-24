import Contacts
import Foundation
import UserNotifications

/// Avisos no próprio aparelho: antes de cada atendimento (se ligado) e no fim do dia, com quem ficou sem anotação.
enum ReminderScheduler {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func reschedule(_ db: Database, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let old = pending.map(\.identifier).filter { isOurs($0) }
        center.removePendingNotificationRequests(withIdentifiers: old)
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let all = Documentation.upcomingReminders(for: db, now: now) + Documentation.reminders(for: db, now: now)
        for r in all {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            content.threadIdentifier = r.identifier.hasPrefix(Documentation.upcomingPrefix) ? "antes" : "fim-do-dia"
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: r.identifier, content: content, trigger: trigger))
        }
    }

    static func isOurs(_ id: String) -> Bool {
        id.hasPrefix(Documentation.reminderPrefix) || id.hasPrefix(Documentation.upcomingPrefix)
    }

    static func cancelAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let ids = reqs.map(\.identifier).filter { ReminderScheduler.isOurs($0) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}

/// Integração com o app Contatos.
enum ContactsBridge {
    struct ImportedContact: Equatable {
        var name: String
        var phone: String
        var email: String
    }

    static func imported(from contact: CNContact) -> ImportedContact {
        let name = [contact.givenName, contact.middleName, contact.familyName]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return ImportedContact(
            name: name.isEmpty ? contact.organizationName : name,
            phone: contact.phoneNumbers.first?.value.stringValue ?? "",
            email: (contact.emailAddresses.first?.value as String?) ?? "")
    }

    enum ExportResult { case saved, denied, failed }

    /// Cria um contato novo com nome, telefone e e-mail do cliente.
    static func export(_ patient: Patient) async -> ExportResult {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else { return .denied }
        let c = CNMutableContact()
        let parts = patient.name.split(separator: " ").map(String.init)
        c.givenName = parts.first ?? patient.name
        c.familyName = parts.dropFirst().joined(separator: " ")
        if !patient.phone.isEmpty {
            c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: patient.phone))]
        }
        if !patient.email.isEmpty {
            c.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: patient.email as NSString)]
        }
        let req = CNSaveRequest()
        req.add(c, toContainerWithIdentifier: nil)
        do {
            try store.execute(req)
            return .saved
        } catch {
            return .failed
        }
    }
}
