import CryptoKit
import Foundation
import UIKit
import UserNotifications

/// Resumable model downloads that outlive the app.
///
/// Ported from Off Grid's `ios/DownloadManagerModule.swift` (MIT, (c) Mohammed Ali
/// Chherawalla): background `URLSession`, resume data, automatic retry with a growing
/// wait, and the optional fast foreground session with a hand-off when the app leaves
/// the screen. Changed for AntiChat:
///
/// - The core is a singleton that works without React Native, so a download that
///   finishes while the app is suspended or was relaunched in the background is still
///   moved into place (and announced with a local notification).
/// - A finished file is moved straight to its destination; nothing is staged for JS.
/// - Resume data is written to disk on pause and on every failure, so a download
///   continues from its bytes after the app was killed, not only after a hand-off.
/// - An HTTP error status is a failure (a download task otherwise "succeeds" with the
///   error page as the file). A resume the server refuses restarts the file once.
/// - One download per file. A model with several files starts several downloads.
final class AntiChatDownloadCore: NSObject {
  static let shared = AntiChatDownloadCore()

  struct Entry: Codable {
    let id: String
    var url: String
    var destination: String
    var headers: [String: String]
    var totalBytes: Int64
    var bytesWritten: Int64
    /// running, paused, completed, failed
    var status: String
    var error: String?
    var errorCode: String?
    var group: String?
    var notifyTitle: String?
    var notifyBody: String?
    var createdAt: Double
  }

  /// Receives `onDownloadProgress`, `onDownloadComplete`, `onDownloadFailed`.
  var sink: ((String, [String: Any]) -> Void)?
  /// Given by iOS when it wakes the app for background download events.
  var backgroundEventsCompletionHandler: (() -> Void)?

  private static let backgroundIdentifier = "ai.antichat.model-downloads"
  private static let storageKey = "ai.antichat.downloads.v1"
  private static let fastSessionKey = "antichatDownloadFastSession"
  private static let backgroundKeyOffset = 1 << 40
  private static let retryDelays: [Double] = [2, 4, 8, 16, 30, 30]
  private static let orphanGraceSeconds = 2.0

  private let queue = DispatchQueue(label: "ai.antichat.downloads")
  private var started = false
  private var backgroundSession: URLSession!
  private var fastSession: URLSession?
  private var entries: [String: Entry] = [:]
  private var tasks: [String: URLSessionDownloadTask] = [:]
  private var keyToId: [Int: String] = [:]
  /// Tasks let go on purpose (pause, cancel, hand-off): their cancellation is not a failure.
  private var retiredKeys = Set<Int>()
  /// Tasks created from resume data: an HTTP error on one restarts the file.
  private var resumedKeys = Set<Int>()
  private var freshRestarts = Set<String>()
  private var autoRetries: [String: Int] = [:]
  private var lastEmit: [String: Double] = [:]
  private var lastPersist = 0.0
  private var isInForeground = true
  /// Left once the tasks that survived a relaunch are attached; commands wait for it.
  private let restored = DispatchGroup()
  private var graceUntil = 0.0

  /// The fast session (`URLSessionConfiguration.default`) downloads at full line speed
  /// but dies with the app; Off Grid measured the background session as slower on
  /// phones. Off by default until that is measured on our phone:
  /// `-antichatDownloadFastSession YES` as a launch argument, or the same defaults key.
  private var usesFastSession: Bool {
    UserDefaults.standard.bool(forKey: AntiChatDownloadCore.fastSessionKey)
  }

  // MARK: - Start-up

  /// Idempotent. Recreates the sessions (which re-delivers events of downloads that
  /// ran while the app was dead) and continues every download that was running.
  func start() {
    queue.sync {
      guard !started else { return }
      started = true
      let config = URLSessionConfiguration.background(withIdentifier: AntiChatDownloadCore.backgroundIdentifier)
      config.isDiscretionary = false
      config.sessionSendsLaunchEvents = true
      config.allowsCellularAccess = true
      config.timeoutIntervalForRequest = 60
      config.timeoutIntervalForResource = 60 * 60 * 24 * 7
      config.urlCache = nil
      config.requestCachePolicy = .reloadIgnoringLocalCacheData
      backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
      if usesFastSession {
        let fast = URLSessionConfiguration.default
        fast.allowsCellularAccess = true
        fast.httpMaximumConnectionsPerHost = 6
        fast.waitsForConnectivity = true
        fast.timeoutIntervalForRequest = 60
        fast.timeoutIntervalForResource = 60 * 60 * 24 * 7
        fast.urlCache = nil
        fast.requestCachePolicy = .reloadIgnoringLocalCacheData
        fastSession = URLSession(configuration: fast, delegate: self, delegateQueue: nil)
      }
      loadEntries()
    }
    guard let session = backgroundSession, !restoreRequested else { return }
    restoreRequested = true
    observeLifecycle()
    restored.enter()
    session.getAllTasks { [weak self] found in
      guard let self else { return }
      self.queue.async {
        self.reattach(found)
        self.restored.leave()
      }
    }
  }

  private var restoreRequested = false

  private func reattach(_ found: [URLSessionTask]) {
    for task in found {
      guard let download = task as? URLSessionDownloadTask,
            let id = task.taskDescription, let entry = entries[id],
            entry.status == "running", tasks[id] == nil,
            task.state == .running || task.state == .suspended else {
        if task.state == .running || task.state == .suspended { task.cancel() }
        continue
      }
      let key = taskKey(download, in: backgroundSession)
      tasks[id] = download
      keyToId[key] = id
      if download.countOfBytesReceived > 0 { entries[id]?.bytesWritten = download.countOfBytesReceived }
      if task.state == .suspended { download.resume() }
      NSLog("[AntiChatDownload] reattached %@ at %lld bytes", id, download.countOfBytesReceived)
    }
    // A running download without a live task: the app was closed by the person (iOS then
    // cancels the transfer and hands over resume data in a moment) or it ran in the fast
    // session. Wait for that resume data, then continue from whatever is on disk.
    guard entries.values.contains(where: { $0.status == "running" && tasks[$0.id] == nil }) else { return }
    graceUntil = Date().timeIntervalSince1970 + AntiChatDownloadCore.orphanGraceSeconds
    queue.asyncAfter(deadline: .now() + AntiChatDownloadCore.orphanGraceSeconds) { [weak self] in
      guard let self else { return }
      let orphans = self.entries.values.filter { $0.status == "running" && self.tasks[$0.id] == nil }.map { $0.id }
      for id in orphans {
        NSLog("[AntiChatDownload] %@ has no live task after relaunch; continuing", id)
        self.begin(id, resumeData: self.loadResumeData(id))
      }
    }
  }

  private func observeLifecycle() {
    DispatchQueue.main.async {
      self.isInForeground = UIApplication.shared.applicationState != .background
      let center = NotificationCenter.default
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
        self?.isInForeground = false
        self?.handOff(toBackground: true)
      }
      center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        guard let self, !self.isInForeground else { return }
        self.isInForeground = true
        self.handOff(toBackground: false)
      }
    }
  }

  /// With the fast session on: moves running downloads to the session that fits the
  /// app's state, keeping their bytes through resume data.
  private func handOff(toBackground: Bool) {
    guard let fast = fastSession else { return }
    let source = toBackground ? fast : backgroundSession!
    let app = UIApplication.shared
    var assertion = UIBackgroundTaskIdentifier.invalid
    assertion = app.beginBackgroundTask(withName: "antichat-download-handoff") {
      app.endBackgroundTask(assertion)
      assertion = .invalid
    }
    let group = DispatchGroup()
    queue.async {
      for (id, task) in self.tasks where self.entries[id]?.status == "running" {
        let key = self.taskKey(task, in: source)
        guard self.keyToId[key] == id else { continue }
        self.retire(id, key: key)
        group.enter()
        task.cancel(byProducingResumeData: { data in
          self.queue.async {
            NSLog("[AntiChatDownload] hand-off %@ to the %@ session (%@ resume data)",
                  id, toBackground ? "background" : "fast", data == nil ? "no" : "with")
            if self.entries[id]?.status == "running" { self.begin(id, resumeData: data) }
            group.leave()
          }
        })
      }
      group.notify(queue: .main) {
        if assertion != .invalid { app.endBackgroundTask(assertion) }
      }
    }
  }

  // MARK: - Commands

  struct StartRequest {
    let url: String
    let destination: String
    let headers: [String: String]
    let totalBytes: Int64
    let group: String?
    let notifyTitle: String?
    let notifyBody: String?
  }

  /// Starts a download, or continues the one already known for this destination.
  func startDownload(_ request: StartRequest) -> [String: Any] {
    start()
    restored.wait()
    return queue.sync {
      if var existing = entries.values.first(where: { $0.destination == request.destination }) {
        let id = existing.id
        let sameFile = existing.url == request.url
        if sameFile, existing.status == "running", tasks[id] != nil {
          return ["downloadId": id, "reattached": true, "bytesWritten": NSNumber(value: existing.bytesWritten)]
        }
        if sameFile, existing.status != "completed" {
          existing.status = "running"
          existing.error = nil
          existing.errorCode = nil
          existing.headers = request.headers
          existing.group = request.group
          existing.notifyTitle = request.notifyTitle
          existing.notifyBody = request.notifyBody
          entries[id] = existing
          autoRetries[id] = 0
          // Inside the grace period after a relaunch the restore continues it.
          if tasks[id] == nil, Date().timeIntervalSince1970 >= graceUntil { begin(id, resumeData: loadResumeData(id)) }
          persist()
          return ["downloadId": id, "reattached": true, "bytesWritten": NSNumber(value: existing.bytesWritten)]
        }
        // Another file for this path, or a finished entry whose file is being fetched again.
        dropLocked(id)
      }
      let id = UUID().uuidString
      entries[id] = Entry(
        id: id, url: request.url, destination: request.destination, headers: request.headers,
        totalBytes: request.totalBytes, bytesWritten: 0, status: "running", error: nil, errorCode: nil,
        group: request.group, notifyTitle: request.notifyTitle, notifyBody: request.notifyBody,
        createdAt: Date().timeIntervalSince1970 * 1000)
      autoRetries[id] = 0
      begin(id, resumeData: nil)
      persist()
      return ["downloadId": id, "reattached": false, "bytesWritten": NSNumber(value: 0)]
    }
  }

  func pauseDownload(_ id: String) -> Bool {
    queue.sync {
      guard var entry = entries[id], entry.status == "running" else { return false }
      entry.status = "paused"
      entries[id] = entry
      persist()
      guard let task = tasks[id] else { return true }
      retire(id, key: currentKey(of: task))
      task.cancel(byProducingResumeData: { data in
        self.queue.async {
          if let data { self.saveResumeData(data, id) }
          NSLog("[AntiChatDownload] paused %@ (%@ resume data)", id, data == nil ? "no" : "with")
        }
      })
      return true
    }
  }

  func resumeDownload(_ id: String) -> Bool {
    restored.wait()
    return queue.sync {
      guard var entry = entries[id], entry.status == "paused" || entry.status == "failed" else { return false }
      entry.status = "running"
      entry.error = nil
      entry.errorCode = nil
      entries[id] = entry
      autoRetries[id] = 0
      begin(id, resumeData: loadResumeData(id))
      persist()
      return true
    }
  }

  func cancelDownload(_ id: String) {
    queue.sync { dropLocked(id) }
  }

  func downloads() -> [[String: Any]] {
    start()
    restored.wait()
    return queue.sync { entries.values.map(describe) }
  }

  // MARK: - Tasks

  private func taskKey(_ task: URLSessionTask, in session: URLSession) -> Int {
    session === backgroundSession ? task.taskIdentifier + AntiChatDownloadCore.backgroundKeyOffset : task.taskIdentifier
  }

  private func currentKey(of task: URLSessionTask) -> Int {
    keyToId.first(where: { tasks[$0.value] === task })?.key ?? -1
  }

  private func retire(_ id: String, key: Int) {
    keyToId.removeValue(forKey: key)
    retiredKeys.insert(key)
    resumedKeys.remove(key)
    tasks.removeValue(forKey: id)
  }

  private func dropLocked(_ id: String) {
    if let task = tasks[id] {
      retire(id, key: currentKey(of: task))
      task.cancel()
    }
    entries.removeValue(forKey: id)
    autoRetries.removeValue(forKey: id)
    freshRestarts.remove(id)
    deleteResumeData(id)
    persist()
  }

  /// Creates and starts the task of a download. Call on `queue`.
  private func begin(_ id: String, resumeData: Data?) {
    guard let entry = entries[id], let url = URL(string: entry.url) else { return }
    let session = (isInForeground ? fastSession : nil) ?? backgroundSession!
    let task: URLSessionDownloadTask
    if let resumeData {
      task = session.downloadTask(withResumeData: AntiChatDownloadCore.rebase(resumeData, onto: entry.url))
    } else {
      var request = URLRequest(url: url)
      request.cachePolicy = .reloadIgnoringLocalCacheData
      // Off Grid: HTTP/3 is often slower than HTTP/2 for one large transfer on iOS.
      request.assumesHTTP3Capable = false
      for (name, value) in entry.headers { request.setValue(value, forHTTPHeaderField: name) }
      task = session.downloadTask(with: request)
      entries[id]?.bytesWritten = 0
    }
    task.taskDescription = id
    let key = taskKey(task, in: session)
    tasks[id] = task
    keyToId[key] = id
    if resumeData != nil { resumedKeys.insert(key) }
    deleteResumeData(id)
    task.resume()
    NSLog("[AntiChatDownload] %@ %@ (%@)", resumeData == nil ? "started" : "resumed", id, entry.url)
  }

  // MARK: - Resume data

  /// Points resume data back at the address the download was started from.
  ///
  /// Resume data remembers the address the bytes last came from. For Hugging Face that
  /// is a signed CDN link that expires an hour after the download began, so a resume
  /// later than that is refused (HTTP 403) and the file starts again from zero. The
  /// original `resolve` address redirects to a fresh link every time, and the range and
  /// entity-tag headers of the resume travel along the redirect.
  ///
  /// Resume data is a keyed archive of a dictionary whose layout is not documented
  /// (`NSURLSessionDownloadURL`, `NSURLSessionResumeCurrentRequest`,
  /// `NSURLSessionResumeOriginalRequest`, ...). If it cannot be read the way it is read
  /// here, the data is returned unchanged and the resume behaves as it does without this.
  static func rebase(_ resumeData: Data, onto original: String) -> Data {
    guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: resumeData) else { return resumeData }
    unarchiver.requiresSecureCoding = false
    defer { unarchiver.finishDecoding() }
    guard let decoded = unarchiver.decodeObject(forKey: resumeRootKey) as? NSDictionary,
          let info = decoded.mutableCopy() as? NSMutableDictionary,
          let current = info["NSURLSessionDownloadURL"] as? String else { return resumeData }
    if current == original { return resumeData }
    guard let originalRequest = info["NSURLSessionResumeOriginalRequest"] as? Data else { return resumeData }
    info["NSURLSessionDownloadURL"] = original
    info["NSURLSessionResumeCurrentRequest"] = originalRequest
    let archiver = NSKeyedArchiver(requiringSecureCoding: false)
    archiver.encode(info, forKey: resumeRootKey)
    archiver.finishEncoding()
    NSLog("[AntiChatDownload] resume re-resolves %@", original)
    return archiver.encodedData
  }

  /// The archive's top-level key is this literal text, not the value of the
  /// `NSKeyedArchiveRootObjectKey` constant ("root").
  private static let resumeRootKey = "NSKeyedArchiveRootObjectKey"

  // MARK: - Persistence

  private func loadEntries() {
    guard let data = UserDefaults.standard.data(forKey: AntiChatDownloadCore.storageKey),
          let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return }
    for entry in saved { entries[entry.id] = entry }
  }

  private func persist() {
    lastPersist = Date().timeIntervalSince1970
    if let data = try? JSONEncoder().encode(Array(entries.values)) {
      UserDefaults.standard.set(data, forKey: AntiChatDownloadCore.storageKey)
    }
  }

  private func resumeDataURL(_ id: String) -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("antichat-downloads", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("\(id).resume")
  }

  private func saveResumeData(_ data: Data, _ id: String) {
    try? data.write(to: resumeDataURL(id), options: .atomic)
  }

  private func loadResumeData(_ id: String) -> Data? {
    try? Data(contentsOf: resumeDataURL(id))
  }

  private func deleteResumeData(_ id: String) {
    try? FileManager.default.removeItem(at: resumeDataURL(id))
  }

  private func describe(_ entry: Entry) -> [String: Any] {
    var out: [String: Any] = [
      "downloadId": entry.id,
      "url": entry.url,
      "destination": entry.destination,
      "bytesWritten": NSNumber(value: entry.bytesWritten),
      "totalBytes": NSNumber(value: entry.totalBytes),
      "status": entry.status
    ]
    if let error = entry.error { out["error"] = error }
    if let code = entry.errorCode { out["code"] = code }
    return out
  }

  private func emit(_ name: String, _ entry: Entry) {
    sink?(name, describe(entry))
  }

  // MARK: - Outcomes (on `queue`)

  private func fail(_ id: String, message: String, code: String) {
    guard var entry = entries[id] else { return }
    entry.status = "failed"
    entry.error = message
    entry.errorCode = code
    entries[id] = entry
    persist()
    NSLog("[AntiChatDownload] %@ failed: %@ (%@)", id, message, code)
    emit("onDownloadFailed", entry)
  }

  private func complete(_ id: String) {
    guard var entry = entries[id] else { return }
    entry.status = "completed"
    if entry.totalBytes > 0 { entry.bytesWritten = entry.totalBytes }
    entries[id] = entry
    autoRetries.removeValue(forKey: id)
    freshRestarts.remove(id)
    deleteResumeData(id)
    persist()
    NSLog("[AntiChatDownload] %@ completed -> %@", id, entry.destination)
    emit("onDownloadComplete", entry)
    notifyIfGroupFinished(entry)
  }

  /// "Download finished", only when nobody is looking at the app and the last file of
  /// the group is in. JS posts its own notice when it is alive and has verified the files.
  private func notifyIfGroupFinished(_ entry: Entry) {
    guard let title = entry.notifyTitle, !isInForeground else { return }
    let pending = entries.values.contains { $0.group == entry.group && $0.status != "completed" }
    guard !pending else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = entry.notifyBody ?? ""
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: "antichat.download.\(entry.group ?? entry.id)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { error in
      NSLog("[AntiChatDownload] finished notice for %@: %@", entry.group ?? entry.id,
            error?.localizedDescription ?? "posted")
    }
  }

  static func reasonCode(for error: NSError) -> String {
    if error.domain == NSURLErrorDomain {
      switch error.code {
      case NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
           NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
        return "network_lost"
      case NSURLErrorTimedOut:
        return "network_timeout"
      case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
           NSURLErrorBadServerResponse:
        return "server_unavailable"
      case NSURLErrorCancelled:
        return error.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] != nil ? "download_interrupted" : "cancelled"
      case NSURLErrorCannotWriteToFile, NSURLErrorCannotCreateFile:
        return "disk_full"
      default:
        return "unknown_error"
      }
    }
    if (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
      || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC)) {
      return "disk_full"
    }
    return "unknown_error"
  }

  private static func isTransient(_ code: String) -> Bool {
    ["network_lost", "network_timeout", "server_unavailable", "download_interrupted"].contains(code)
  }

  // MARK: - Hashing

  /// SHA-256 of a file read in 4 MB pieces, so a 6 GB model never sits in memory.
  /// (`RNFS.hash` reads the whole file into one `NSData` on iOS.)
  static func sha256(path: String, progress: @escaping (Double) -> Void) throws -> String {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    var hasher = SHA256()
    var done: Int64 = 0
    var lastReport = 0.0
    while true {
      let finished: Bool = try autoreleasepool {
        guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { return true }
        hasher.update(data: chunk)
        done += Int64(chunk.count)
        return false
      }
      if finished { break }
      let now = Date().timeIntervalSince1970
      if size > 0, now - lastReport > 0.25 {
        lastReport = now
        progress(Double(done) / Double(size))
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - URLSession delegate

extension AntiChatDownloadCore: URLSessionDownloadDelegate {
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                  totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    let key = taskKey(downloadTask, in: session)
    queue.async {
      guard let id = self.keyToId[key], var entry = self.entries[id], entry.status == "running" else { return }
      entry.bytesWritten = totalBytesWritten
      if entry.totalBytes <= 0, totalBytesExpectedToWrite > 0 { entry.totalBytes = totalBytesExpectedToWrite }
      self.entries[id] = entry
      // Bytes are arriving again: the next drop gets the full set of retries.
      self.autoRetries[id] = 0
      let now = Date().timeIntervalSince1970
      if now - (self.lastEmit[id] ?? 0) >= 0.5 {
        self.lastEmit[id] = now
        self.emit("onDownloadProgress", entry)
      }
      if now - self.lastPersist >= 5 { self.persist() }
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    // The file at `location` is deleted when this method returns: move it now.
    let key = taskKey(downloadTask, in: session)
    let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
    let lookup: (id: String, entry: Entry, resumed: Bool)? = queue.sync {
      // After a relaunch a task can finish before it was mapped: its description names it.
      let id = keyToId[key] ?? (retiredKeys.contains(key) ? nil : downloadTask.taskDescription)
      guard let id, let entry = entries[id], entry.status == "running" else { return nil }
      return (id, entry, resumedKeys.contains(key))
    }
    guard let lookup else { return }
    var failure: (String, String)?
    if status != 0 && !(200...299).contains(status) {
      failure = ("The server answered HTTP \(status)", "http_\(status)")
    } else {
      let manager = FileManager.default
      let destination = URL(fileURLWithPath: lookup.entry.destination)
      do {
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try manager.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? -1
        if lookup.entry.totalBytes > 0, size != lookup.entry.totalBytes {
          failure = ("Downloaded \(size) bytes, expected \(lookup.entry.totalBytes)", "size_mismatch")
        } else {
          try? manager.removeItem(at: destination)
          try manager.moveItem(at: location, to: destination)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          var target = destination
          try? target.setResourceValues(values)
        }
      } catch {
        let code = AntiChatDownloadCore.reasonCode(for: error as NSError)
        failure = ("Could not save the download: \(error.localizedDescription)", code == "disk_full" ? code : "save_failed")
      }
    }
    queue.async {
      let id = lookup.id
      self.retire(id, key: key)
      self.retiredKeys.remove(key)
      guard let failure else {
        self.complete(id)
        return
      }
      // A resume the server refused (a changed file, an expired link): fetch the file again, once.
      if lookup.resumed || failure.1 == "size_mismatch", !self.freshRestarts.contains(id) {
        self.freshRestarts.insert(id)
        NSLog("[AntiChatDownload] %@: %@; starting the file again", id, failure.0)
        self.begin(id, resumeData: nil)
        return
      }
      self.fail(id, message: failure.0, code: failure.1)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error = error as NSError? else { return }
    let key = taskKey(task, in: session)
    let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    queue.async {
      if self.retiredKeys.remove(key) != nil { return }
      // A task from before a relaunch is known only by its description.
      guard let id = self.keyToId[key] ?? task.taskDescription, let entry = self.entries[id] else { return }
      if let known = self.tasks[id], known !== task { return }
      self.keyToId.removeValue(forKey: key)
      self.resumedKeys.remove(key)
      self.tasks.removeValue(forKey: id)
      if let resumeData { self.saveResumeData(resumeData, id) }
      guard entry.status == "running" else { return }

      let code = AntiChatDownloadCore.reasonCode(for: error)
      let attempts = self.autoRetries[id] ?? 0
      if AntiChatDownloadCore.isTransient(code), attempts < AntiChatDownloadCore.retryDelays.count {
        self.autoRetries[id] = attempts + 1
        let delay = code == "download_interrupted" ? 0.1 : AntiChatDownloadCore.retryDelays[attempts]
        NSLog("[AntiChatDownload] %@ stopped (%@); retry %d in %.0fs %@ resume data",
              id, code, attempts + 1, delay, resumeData == nil ? "without" : "with")
        self.persist()
        self.queue.asyncAfter(deadline: .now() + delay) {
          guard self.entries[id]?.status == "running", self.tasks[id] == nil else { return }
          self.begin(id, resumeData: self.loadResumeData(id))
        }
        return
      }
      self.fail(id, message: error.localizedDescription, code: code)
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
    DispatchQueue.main.async {
      self.backgroundEventsCompletionHandler?()
      self.backgroundEventsCompletionHandler = nil
    }
  }
}

// MARK: - App delegate hook

/// iOS relaunches the app in the background when a download finishes while it was
/// dead. Upstream's AppDelegate does not implement this method, so it lives here.
extension AppDelegate {
  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    AntiChatDownloadCore.shared.backgroundEventsCompletionHandler = completionHandler
    AntiChatDownloadCore.shared.start()
  }
}
