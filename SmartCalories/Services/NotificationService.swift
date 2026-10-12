import Foundation
import UserNotifications
import WidgetKit

/// Local reminders: meal-logging nudges plus an evening check-in whose text
/// carries the user's actual numbers for the day.
@MainActor
final class NotificationService {

    private let center = UNUserNotificationCenter.current()

    private enum ID {
        static let breakfast = "meal.breakfast"
        static let lunch = "meal.lunch"
        static let dinner = "meal.dinner"
        static let checkIn = "goal.checkin"
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Re-apply every schedule. Cheap and idempotent, so it's safe to call
    /// whenever settings or the day's totals change.
    func scheduleAll(settings: AppSettings, eaten: Double, goal: Double) {
        Task {
            guard await authorizationStatus() == .authorized else { return }

            if settings.mealRemindersEnabled {
                schedule(id: ID.breakfast, hour: settings.breakfastHour, minute: settings.breakfastMinute,
                         title: "Log your breakfast",
                         body: "Weigh it and log it while it's fresh.")
                schedule(id: ID.lunch, hour: settings.lunchHour, minute: settings.lunchMinute,
                         title: "Log your lunch",
                         body: "Keeping the diary complete is what makes the numbers mean anything.")
                schedule(id: ID.dinner, hour: settings.dinnerHour, minute: settings.dinnerMinute,
                         title: "Log your dinner",
                         body: "One more meal to capture today.")
            } else {
                center.removePendingNotificationRequests(
                    withIdentifiers: [ID.breakfast, ID.lunch, ID.dinner])
            }

            if settings.goalCheckInEnabled {
                let remaining = goal - eaten
                let body: String
                if eaten <= 0 {
                    body = "Nothing logged yet today. Your target is \(Int(goal)) kcal."
                } else if remaining >= 0 {
                    body = "You're at \(Int(eaten)) of \(Int(goal)) kcal — \(Int(remaining)) left."
                } else {
                    body = "You're at \(Int(eaten)) of \(Int(goal)) kcal — \(Int(-remaining)) over."
                }
                schedule(id: ID.checkIn, hour: settings.checkInHour, minute: settings.checkInMinute,
                         title: "Today's progress", body: body)
            } else {
                center.removePendingNotificationRequests(withIdentifiers: [ID.checkIn])
            }
        }
    }

    private func schedule(id: String, hour: Int, minute: Int, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        center.add(request)
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }
}

// MARK: - Widget bridge

/// Publishes today's numbers to the shared App Group so a home-screen widget
/// can render them without launching the app.
enum WidgetBridge {
    static let appGroup = "group.com.sankalpsingh.smartcalories"

    static func publish(eaten: Double, goal: Double, burned: Double) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(Int(eaten.rounded()), forKey: "calories_eaten")
        defaults.set(Int(goal.rounded()), forKey: "calories_goal")
        defaults.set(Int((goal - eaten).rounded()), forKey: "calories_remaining")
        defaults.set(Int(burned.rounded()), forKey: "calories_burned")
        WidgetCenter.shared.reloadAllTimelines()
    }
}
