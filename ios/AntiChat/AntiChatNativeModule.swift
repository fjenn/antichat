import Foundation
import React
import UIKit
import os

/// JS face of the AntiChat model engine on iOS: resumable downloads
/// (`AntiChatDownloadCore`), streamed SHA-256 and a memory reading.
/// JS side: `src/antichat/engine/downloads/native.ts`.
@objc(AntiChatNative)
class AntiChatNativeModule: RCTEventEmitter {
  private var hasListeners = false

  override init() {
    super.init()
    AntiChatDownloadCore.shared.sink = { [weak self] name, body in
      guard let self, self.hasListeners else { return }
      self.sendEvent(withName: name, body: body)
    }
    AntiChatDownloadCore.shared.start()
  }

  @objc override static func requiresMainQueueSetup() -> Bool { false }

  override func supportedEvents() -> [String]! {
    ["onDownloadProgress", "onDownloadComplete", "onDownloadFailed", "onHashProgress"]
  }

  override func startObserving() { hasListeners = true }
  // Listeners belong to a JS singleton and are permanent; RN's stop/start churn must
  // not drop a completion event (Off Grid's finding).
  override func stopObserving() {}

  @objc func startDownload(_ params: NSDictionary,
                           resolver resolve: @escaping RCTPromiseResolveBlock,
                           rejecter reject: @escaping RCTPromiseRejectBlock) {
    guard let url = params["url"] as? String, URL(string: url) != nil,
          let destination = params["destination"] as? String else {
      reject("INVALID_PARAMS", "url and destination are required", nil)
      return
    }
    let request = AntiChatDownloadCore.StartRequest(
      url: url,
      destination: destination,
      headers: (params["headers"] as? [String: String]) ?? [:],
      totalBytes: (params["totalBytes"] as? NSNumber)?.int64Value ?? 0,
      group: params["group"] as? String,
      notifyTitle: params["notifyTitle"] as? String,
      notifyBody: params["notifyBody"] as? String)
    resolve(AntiChatDownloadCore.shared.startDownload(request))
  }

  @objc func pauseDownload(_ id: String,
                           resolver resolve: @escaping RCTPromiseResolveBlock,
                           rejecter _: @escaping RCTPromiseRejectBlock) {
    resolve(AntiChatDownloadCore.shared.pauseDownload(id))
  }

  @objc func resumeDownload(_ id: String,
                            resolver resolve: @escaping RCTPromiseResolveBlock,
                            rejecter _: @escaping RCTPromiseRejectBlock) {
    resolve(AntiChatDownloadCore.shared.resumeDownload(id))
  }

  @objc func cancelDownload(_ id: String,
                            resolver resolve: @escaping RCTPromiseResolveBlock,
                            rejecter _: @escaping RCTPromiseRejectBlock) {
    AntiChatDownloadCore.shared.cancelDownload(id)
    resolve(true)
  }

  @objc func getDownloads(_ resolve: @escaping RCTPromiseResolveBlock,
                          rejecter _: @escaping RCTPromiseRejectBlock) {
    resolve(AntiChatDownloadCore.shared.downloads())
  }

  @objc func hashFile(_ path: String, token: String,
                      resolver resolve: @escaping RCTPromiseResolveBlock,
                      rejecter reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let digest = try AntiChatDownloadCore.sha256(path: path) { [weak self] fraction in
          guard let self, self.hasListeners else { return }
          self.sendEvent(withName: "onHashProgress", body: ["token": token, "fraction": fraction])
        }
        resolve(digest)
      } catch {
        reject("HASH_FAILED", error.localizedDescription, error)
      }
    }
  }

  /// "active", "inactive" or "background", read from UIKit. React Native's AppState
  /// stays "background" when the app returns to the screen under a system prompt
  /// (no didBecomeActive is posted), so the model engine asks here.
  @objc func applicationState(_ resolve: @escaping RCTPromiseResolveBlock,
                              rejecter _: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.main.async {
      switch UIApplication.shared.applicationState {
      case .active: resolve("active")
      case .inactive: resolve("inactive")
      case .background: resolve("background")
      @unknown default: resolve("active")
      }
    }
  }

  @objc func memoryInfo(_ resolve: @escaping RCTPromiseResolveBlock,
                        rejecter _: @escaping RCTPromiseRejectBlock) {
    resolve([
      "availableBytes": NSNumber(value: UInt64(os_proc_available_memory())),
      "totalBytes": NSNumber(value: ProcessInfo.processInfo.physicalMemory),
      "lowMemory": false
    ] as [String: Any])
  }
}
