import Foundation
import UIKit
import UserNotifications
import XCTest

class RunnerTests: XCTestCase {

  private func futureTimeToday() throws -> (Calendar, Date) {
    let calendar = Calendar.current
    let now = Date()
    let target = now.addingTimeInterval(120)
    try XCTSkipUnless(
      calendar.isDate(now, inSameDayAs: target),
      "Run this clock-relative probe at least two minutes before midnight."
    )
    return (calendar, target)
  }

  func testDailyTriggerDoesNotHonorTomorrowAsAStartBoundary() throws {
    let (calendar, today) = try futureTimeToday()
    let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
    // Match the component selection in flutter_local_notifications 22.3.1.
    let components = calendar.dateComponents(
      [.hour, .minute, .second, .timeZone], from: tomorrow
    )
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
    let next = try XCTUnwrap(trigger.nextTriggerDate())
    XCTAssertTrue(calendar.isDate(next, inSameDayAs: today))
    XCTAssertEqual(next.timeIntervalSince1970, today.timeIntervalSince1970, accuracy: 1)
    XCTAssertLessThan(next, tomorrow)
  }

  func testWeeklyTriggerDoesNotHonorNextWeekAsAStartBoundary() throws {
    let (calendar, today) = try futureTimeToday()
    let nextWeek = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: today))
    let components = calendar.dateComponents(
      [.weekday, .hour, .minute, .second, .timeZone], from: nextWeek
    )
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
    let next = try XCTUnwrap(trigger.nextTriggerDate())
    XCTAssertTrue(calendar.isDate(next, inSameDayAs: today))
    XCTAssertEqual(next.timeIntervalSince1970, today.timeIntervalSince1970, accuracy: 1)
    XCTAssertLessThan(next, nextWeek)
  }

  func testOneShotTriggerPreservesTheExplicitFutureDate() throws {
    let (calendar, today) = try futureTimeToday()
    let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
    let components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second, .timeZone], from: tomorrow
    )
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    let next = try XCTUnwrap(trigger.nextTriggerDate())
    XCTAssertTrue(calendar.isDate(next, inSameDayAs: tomorrow))
    XCTAssertEqual(next.timeIntervalSince1970, tomorrow.timeIntervalSince1970, accuracy: 1)
  }

  private let notificationCenter = UNUserNotificationCenter.current()

  private func record(_ observation: String) {
    XCTContext.runActivity(named: observation) { _ in }
  }

  private func settings() throws -> UNNotificationSettings {
    let received = expectation(description: "Read current notification settings")
    var result: UNNotificationSettings?
    notificationCenter.getNotificationSettings {
      result = $0
      received.fulfill()
    }
    wait(for: [received], timeout: 10)
    return try XCTUnwrap(result)
  }

  private func pendingRequests() throws -> [UNNotificationRequest] {
    let received = expectation(description: "Read pending notification requests")
    var result: [UNNotificationRequest]?
    notificationCenter.getPendingNotificationRequests {
      result = $0
      received.fulfill()
    }
    wait(for: [received], timeout: 10)
    return try XCTUnwrap(result)
  }

  private func add(_ request: UNNotificationRequest) throws {
    let added = expectation(description: "Add synthetic notification")
    var failure: Error?
    notificationCenter.add(request) {
      failure = $0
      added.fulfill()
    }
    wait(for: [added], timeout: 10)
    if let failure { throw failure }
  }

  private func requireAuthorizedEmptyQueue() throws {
    let current = try settings()
    try XCTSkipUnless(
      current.authorizationStatus == .authorized,
      "G2 scheduling is unverified: notification authorization requires owner approval."
    )
    try XCTSkipUnless(
      try pendingRequests().isEmpty,
      "G2 scheduling probe requires an empty queue; existing notifications are preserved."
    )
  }

  private func prepareIdentifiers(count: Int) -> [String] {
    let prefix = "habit-checkin.g2-probe.\(UUID().uuidString)"
    let identifiers = (0..<count).map { "\(prefix).\($0)" }
    addTeardownBlock { [self] in
      notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
      let remaining = try pendingRequests()
      XCTAssertFalse(remaining.contains { identifiers.contains($0.identifier) })
    }
    return identifiers
  }

  private func request(id: String, daysFromNow: Int) throws -> UNNotificationRequest {
    let calendar = Calendar.current
    let date = try XCTUnwrap(
      calendar.date(byAdding: .day, value: daysFromNow, to: Date())
    )
    let components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second, .timeZone], from: date
    )
    let content = UNMutableNotificationContent()
    content.title = "TEST G2"
    content.body = "Synthetic probe; not a personal reminder."
    return UNNotificationRequest(
      identifier: id,
      content: content,
      trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    )
  }

  func testRecordNotificationPrerequisitesWithoutPrompting() throws {
    let current = try settings()
    let pending = try pendingRequests()
    record(
      "G2 prerequisites: authorization=\(current.authorizationStatus.rawValue), "
        + "alerts=\(current.alertSetting.rawValue), pending=\(pending.count). "
        + "Read-only observation, not delivery or capacity acceptance."
    )
  }

  func testAuthorizedRequestReplacementAndTargetedCancellation() throws {
    try requireAuthorizedEmptyQueue()
    let ids = prepareIdentifiers(count: 2)
    let original = try request(id: ids[0], daysFromNow: 30)
    let replacement = try request(id: ids[0], daysFromNow: 31)
    let future = try request(id: ids[1], daysFromNow: 32)
    try add(original)
    try add(future)
    try add(replacement)
    let afterReplace = try pendingRequests()
    XCTAssertEqual(Set(afterReplace.map(\.identifier)), Set(ids))
    let replaced = try XCTUnwrap(afterReplace.first { $0.identifier == ids[0] })
    let actualTrigger = try XCTUnwrap(replaced.trigger as? UNCalendarNotificationTrigger)
    let expectedTrigger = try XCTUnwrap(replacement.trigger as? UNCalendarNotificationTrigger)
    XCTAssertEqual(
      try XCTUnwrap(actualTrigger.nextTriggerDate()).timeIntervalSince1970,
      try XCTUnwrap(expectedTrigger.nextTriggerDate()).timeIntervalSince1970,
      accuracy: 1
    )
    notificationCenter.removePendingNotificationRequests(withIdentifiers: [ids[0]])
    let afterCancel = try pendingRequests()
    XCTAssertEqual(afterCancel.map(\.identifier), [ids[1]])
    record("G2 pending identity: replacement=2 requests, targeted cancellation=1 retained.")
  }

  func testAuthorizedPendingCapacityBoundaries() throws {
    try requireAuthorizedEmptyQueue()
    let ids = prepareIdentifiers(count: 65)
    for index in ids.indices {
      try add(request(id: ids[index], daysFromNow: 30 + index))
      if index >= 62 {
        let pending = try pendingRequests()
        let retained = Set(pending.map(\.identifier))
        XCTAssertTrue(retained.isSubset(of: Set(ids)))
        XCTAssertFalse(retained.isEmpty)
        XCTAssertLessThanOrEqual(retained.count, index + 1)
        let indexes = ids.indices.filter { retained.contains(ids[$0]) }
        record(
          "G2 capacity observation: added=\(index + 1), pending=\(pending.count), "
            + "retained synthetic indexes=\(indexes). Not delivery acceptance."
        )
      }
    }
  }

  private struct DeliveryObservation: Codable {
    let identifier: String
    let deliveredAt: Date
  }

  private struct DeliveryPlan: Codable {
    let run: String
    let armedAt: Date
    let processIdentifier: Int32
    var state: String
    var observedAt: Date?
    var observations: [DeliveryObservation]?
  }

  private func deliveredNotifications() throws -> [UNNotification] {
    let received = expectation(description: "Read system-delivered notifications")
    var result: [UNNotification]?
    notificationCenter.getDeliveredNotifications {
      result = $0
      received.fulfill()
    }
    wait(for: [received], timeout: 10)
    return try XCTUnwrap(result)
  }

  private func requireDelivery(_ condition: Bool, _ message: String) throws {
    guard condition else {
      throw NSError(
        domain: "HabitCheckin.G2Delivery", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
  }

  private func validDeliveryRun(_ run: String) -> Bool {
    run.range(of: "\\A[A-Za-z0-9-]{1,80}\\z", options: .regularExpression) != nil
  }

  func testDeliveryRunTokensCannotChangeEvidencePaths() {
    for run in ["r1", "20261009-delivery-r1", String(repeating: "a", count: 80)] {
      XCTAssertTrue(validDeliveryRun(run))
    }
    for run in [
      "", ".", "../probe", "a/b", "a\\b", "a b", "a\n", "a\r\n",
      "\u{4e2d}", String(repeating: "a", count: 81),
    ] {
      XCTAssertFalse(validDeliveryRun(run))
    }
  }

  private func saveDeliveryPlan(_ plan: DeliveryPlan, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(plan).write(to: url, options: .atomic)
  }

  private func cleanDeliveryRequests(_ identifiers: Set<String>) throws {
    let ids = Array(identifiers)
    notificationCenter.removePendingNotificationRequests(withIdentifiers: ids)
    notificationCenter.removeDeliveredNotifications(withIdentifiers: ids)
    try requireDelivery(
      try pendingRequests().allSatisfy { !identifiers.contains($0.identifier) },
      "Synthetic pending requests remain after targeted cleanup."
    )
    try requireDelivery(
      try deliveredNotifications().allSatisfy {
        !identifiers.contains($0.request.identifier)
      },
      "Synthetic delivered notifications remain after targeted cleanup."
    )
  }

  func testAuthorizedDeliveryAcrossProcesses() throws {
    #if !targetEnvironment(simulator)
      throw XCTSkip("This short delivery probe is authorized for the test simulator only.")
    #endif
    let environment = ProcessInfo.processInfo.environment
    guard let phase = environment["G2_DELIVERY_PHASE"] else {
      throw XCTSkip("Explicit arm/verify/cleanup phase and a fresh G2_DELIVERY_RUN are required.")
    }
    try requireDelivery(
      ["arm", "verify", "cleanup"].contains(phase), "Unknown delivery probe phase."
    )
    let run = try XCTUnwrap(environment["G2_DELIVERY_RUN"])
    try requireDelivery(
      validDeliveryRun(run),
      "Use a fresh alphanumeric/hyphen run token, at most 80 characters."
    )
    let root = try XCTUnwrap(
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ).appendingPathComponent("habit-checkin-g2-delivery", isDirectory: true)
    let file = root.appendingPathComponent("\(run).json")
    let prefix = "habit-checkin.g2-delivery.\(run)."
    let roles = ["control", "cancelled", "replacement", "future"]
    let ids = Set(roles.map { prefix + $0 })
    let offsets: [String: TimeInterval] = [
      "control": 90, "cancelled": 90, "replacement": 120, "future": 150,
    ]

    if phase == "arm" {
      try requireAuthorizedEmptyQueue()
      try requireDelivery(
        try settings().alertSetting == .enabled, "Notification alerts must already be enabled."
      )
      try requireDelivery(
        try deliveredNotifications().isEmpty,
        "Preserve existing delivered notifications; use an empty test installation."
      )
      try requireDelivery(
        !FileManager.default.fileExists(atPath: file.path),
        "This run token already has evidence; do not overwrite it."
      )
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      var plan = DeliveryPlan(
        run: run, armedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
        processIdentifier: ProcessInfo.processInfo.processIdentifier, state: "preparing"
      )
      // Persist ownership before scheduling so an interrupted arm can be cleaned safely.
      try saveDeliveryPlan(plan, to: file)
      do {
        func schedule(_ role: String, after offset: TimeInterval) throws {
          let date = plan.armedAt.addingTimeInterval(offset)
          let calendar = Calendar.current
          let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .timeZone], from: date
          )
          let content = UNMutableNotificationContent()
          content.title = "TEST G2 Delivery"
          content.body = "Synthetic notification delivery probe."
          content.threadIdentifier = prefix
          content.userInfo = ["g2Run": run, "g2Role": role]
          try add(
            UNNotificationRequest(
              identifier: prefix + role, content: content,
              trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
          )
        }
        for role in roles {
          try schedule(role, after: 90)
        }
        try schedule("replacement", after: 120)
        try schedule("future", after: 150)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [prefix + "cancelled"])
        let pending = try pendingRequests()
        try requireDelivery(
          Set(pending.map(\.identifier)) == ids.subtracting([prefix + "cancelled"]),
          "Arming did not preserve exactly the three expected requests."
        )
        for item in pending {
          let role = String(item.identifier.dropFirst(prefix.count))
          let expected = plan.armedAt.addingTimeInterval(try XCTUnwrap(offsets[role]))
          let trigger = try XCTUnwrap(item.trigger as? UNCalendarNotificationTrigger)
          let next = try XCTUnwrap(trigger.nextTriggerDate())
          try requireDelivery(
            abs(next.timeIntervalSince(expected)) < 1,
            "Pending trigger does not match the final replacement date."
          )
        }
        try requireDelivery(
          Date() < plan.armedAt.addingTimeInterval(60),
          "Arming consumed the safe process-exit margin; retry with a fresh token."
        )
        plan.state = "armed"
        try saveDeliveryPlan(plan, to: file)
        record(
          "G2 delivery armed: run=\(run), epoch=\(plan.armedAt.timeIntervalSince1970), "
            + "control/cancelled=+90s, replacement=+120s, future=+150s. "
            + "Terminate the App before +90s; verify no earlier than +165s."
        )
      } catch {
        try cleanDeliveryRequests(ids)
        throw error
      }
      return
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    var plan = try decoder.decode(DeliveryPlan.self, from: Data(contentsOf: file))
    try requireDelivery(plan.run == run, "Evidence belongs to a different run.")
    if phase == "cleanup" {
      try cleanDeliveryRequests(ids)
      if plan.state != "verified" { plan.state = "cleaned" }
      try saveDeliveryPlan(plan, to: file)
      record("G2 delivery cleanup: only this run's synthetic IDs were removed; evidence retained.")
      return
    }

    try requireDelivery(plan.state == "armed", "Read requires an unverified, successfully armed run.")
    try requireDelivery(
      plan.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      "Verify must run in an independent App process."
    )
    let now = Date()
    try requireDelivery(
      now >= plan.armedAt.addingTimeInterval(165),
      "Read is too early: wait beyond all scheduled times without changing the system clock."
    )
    try requireDelivery(
      now < plan.armedAt.addingTimeInterval(900),
      "Read exceeded the bounded observation window; keep the evidence and clean this run."
    )
    addTeardownBlock { [self] in try cleanDeliveryRequests(ids) }
    let delivered = try deliveredNotifications().filter { ids.contains($0.request.identifier) }
    plan.observedAt = now
    plan.observations = delivered.map {
      DeliveryObservation(identifier: $0.request.identifier, deliveredAt: $0.date)
    }
    // Preserve actual results before assertions, including a failed verification.
    try saveDeliveryPlan(plan, to: file)
    for item in delivered {
      record(
        "G2 delivered: id=\(item.request.identifier), "
          + "systemDateEpoch=\(item.date.timeIntervalSince1970), observedEpoch=\(now.timeIntervalSince1970)"
      )
    }
    let expectedIds = ids.subtracting([prefix + "cancelled"])
    try requireDelivery(
      delivered.count == 3 && Set(delivered.map { $0.request.identifier }) == expectedIds,
      "Expected control, replacement and future delivery, with the cancelled request absent."
    )
    try requireDelivery(
      try pendingRequests().allSatisfy { !ids.contains($0.identifier) },
      "An expected one-shot notification remains pending after its delivery time."
    )
    for item in delivered {
      let role = String(item.request.identifier.dropFirst(prefix.count))
      let expected = plan.armedAt.addingTimeInterval(try XCTUnwrap(offsets[role]))
      try requireDelivery(
        item.date >= expected.addingTimeInterval(-1) && item.date <= now,
        "The system delivery timestamp precedes the final scheduled time."
      )
      try requireDelivery(
        item.request.content.title == "TEST G2 Delivery"
          && item.request.content.body == "Synthetic notification delivery probe."
          && item.request.content.userInfo["g2Run"] as? String == run,
        "Delivered content does not match this synthetic run."
      )
    }
    plan.state = "verified"
    try saveDeliveryPlan(plan, to: file)
    record(
      "G2 delivery verified in a new process: 3 delivered, cancelled absent, no own pending. "
        + "This short simulator probe is not next-day, offline, physical-device or 72-hour acceptance."
    )
  }

}
