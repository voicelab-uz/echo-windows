import Foundation
@main struct EchoProfileAPIRegression {
 static func main() throws {
  let wire = JSONDecoder(); wire.keyDecodingStrategy = .convertFromSnakeCase
  let account = try wire.decode(EchoAccount.self, from: Data(#"{"id":42,"email":"me@example.com","display_name":"Echo User","avatar_url":"https://cdn.voicelab.uz/avatar.png"}"#.utf8))
  precondition(account.id == "42" && account.name == "Echo User" && account.avatarURL?.host == "cdn.voicelab.uz")
  let roundtrip = try JSONDecoder().decode(EchoAccount.self, from: JSONEncoder().encode(account))
  precondition(roundtrip == account)
  let old = try JSONDecoder().decode(EchoAccount.self, from: Data(#"{"id":"42","email":"me@example.com","name":"Legacy"}"#.utf8))
  precondition(old.avatarURL == nil && old.name == "Legacy")
  let unsafe = try wire.decode(EchoAccount.self, from: Data(#"{"id":"42","email":"me@example.com","avatar_url":"http://unsafe.example/avatar"}"#.utf8))
  precondition(unsafe.avatarURL == nil)
  let usage = try wire.decode(EchoUsageSnapshot.self, from: Data(#"{"enabled":false}"#.utf8))
  precondition(!usage.enabled && usage.remainingSeconds == nil)
  let exhausted = try wire.decode(EchoUsageSnapshot.self, from: Data(#"{"enabled":true,"usage_limit_seconds":3600,"used_seconds":3600}"#.utf8))
  precondition(exhausted.remainingSeconds == 0 && exhausted.usedSeconds == 3600)
  let unused = try wire.decode(EchoUsageSnapshot.self, from: Data(#"{"enabled":true,"usage_limit_seconds":3600,"remaining_seconds":3600}"#.utf8))
  precondition(unused.usedSeconds == 0)
  let subscription = try wire.decode(EchoSubscription.self, from: Data(#"{"active":false,"daily_seconds":0,"max_request_seconds":0,"cancel_at_period_end":false}"#.utf8))
  precondition(!subscription.active && subscription.packageName == nil)
  // Real API contract: days has totals without a platform; platform_days carries
  // the device split. An iPhone recording must not disappear into the Mac total.
  let stats = try wire.decode(EchoStatistics.self, from: Data(#"{"days":[{"day":"2026-10-25","language":"uz","words":30,"recordings":3,"duration_ms":9000}],"platform_days":[{"day":"2026-10-25","language":"uz","platform":"desktop","words":10,"recordings":1,"duration_ms":3000},{"day":"2026-10-25","language":"uz","platform":"ios","words":20,"recordings":2,"duration_ms":6000}],"from":"2026-10-25","through":"2026-10-25","time_zone":"Asia/Tashkent"}"#.utf8))
  precondition(stats.days.count == 1 && stats.days[0].platform == nil && stats.days[0].recordings == 3)
  precondition(stats.platformDays?.filter { $0.platform == "ios" }.reduce(0) { $0 + $1.recordings } == 2)
  precondition(stats.platformDays?.filter { $0.platform == "desktop" }.reduce(0) { $0 + $1.recordings } == 1)
  precondition(stats.platformDays?.reduce(0) { $0 + $1.recordings } == stats.days[0].recordings)
  let legacyStats = try wire.decode(EchoStatistics.self, from: Data(#"{"days":[{"day":"2026-10-25","language":"uz","words":30,"recordings":3,"duration_ms":9000}],"from":"2026-10-25","through":"2026-10-25","time_zone":"Asia/Tashkent"}"#.utf8))
  precondition(legacyStats.platformDays == nil && legacyStats.days[0].recordings == 3)
  let emptyStats = try wire.decode(EchoStatistics.self, from: Data(#"{"days":[],"platform_days":[],"from":"2026-10-25","through":"2026-10-25","time_zone":"Asia/Tashkent"}"#.utf8))
  precondition(emptyStats.platformDays?.isEmpty == true)
  let historyJSON = #"{"transcriptions":[{"id":"dst_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","transcript":"O‘zbekiston haqida aytilgan gap.","revision":1,"language":"uz","duration_ms":5690,"audio_available":true,"created_at":"2026-10-25T12:30:00.123456789Z","updated_at":"2026-10-25T12:30:01Z","language_details":{"primary":"uz"}}],"pagination":{"page":1,"page_size":50,"total_transcriptions":51,"total_pages":2,"has_next":true,"has_previous":false,"next_page":2,"previous_page":null},"request_id":"req_test"}"#
  let historyData = Data(historyJSON.utf8)
  let history = try wire.decode(EchoDictationHistory.self, from: historyData)
  precondition(history.items.count == 1 && history.items[0].transcript == "O‘zbekiston haqida aytilgan gap.")
  precondition(history.items[0].durationMs == 5690 && history.items[0].audioAvailable && history.items[0].language == "uz")
  precondition(history.items[0].createdAt < history.items[0].updatedAt && history.total == 51 && history.nextCursor == "2")
  var historyObject = try JSONSerialization.jsonObject(with: historyData) as! [String: Any]
  historyObject["transcriptions"] = []
  historyObject["pagination"] = ["page": 2, "page_size": 50, "total_transcriptions": 0, "total_pages": 0, "has_next": false, "next_page": NSNull()]
  let finalHistory = try wire.decode(EchoDictationHistory.self, from: JSONSerialization.data(withJSONObject: historyObject))
  precondition(finalHistory.items.isEmpty && finalHistory.nextCursor == nil)
  var badHistory = try JSONSerialization.jsonObject(with: historyData) as! [String: Any]
  var badPagination = badHistory["pagination"] as! [String: Any]
  badPagination["next_page"] = 1 // A repeated continuation would loop the UI.
  badHistory["pagination"] = badPagination
  do {
   _ = try wire.decode(EchoDictationHistory.self, from: JSONSerialization.data(withJSONObject: badHistory))
   preconditionFailure("Invalid history continuation accepted")
  } catch EchoAuthError.invalidResponse {}
  badHistory = try JSONSerialization.jsonObject(with: historyData) as! [String: Any]
  var badItems = badHistory["transcriptions"] as! [[String: Any]]
  badItems[0]["created_at"] = "not-a-date"
  badHistory["transcriptions"] = badItems
  do {
   _ = try wire.decode(EchoDictationHistory.self, from: JSONSerialization.data(withJSONObject: badHistory))
   preconditionFailure("Invalid history timestamp accepted")
  } catch EchoAuthError.invalidResponse {}
  print("Echo profile, statistics, and dictation history API decoding regressions passed")
 }
}
