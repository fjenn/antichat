//
//  MemoryPressureResponder.swift
//  osaurus
//
//  Responds to macOS memory-pressure events by proactively freeing app-side
//  caches (warning) and unloading idle model weights (critical), instead of
//  relying solely on NSCache's passive eviction.
//
//  This never refuses loads or applies hidden RAM limits — it only frees
//  reconstructible caches and lease-free models through the existing
//  `ModelRuntime.unload` path, and logs every action so the behavior is
//  observable.
//

import Foundation
import os

public final class MemoryPressureResponder: @unchecked Sendable {
    public static let shared = MemoryPressureResponder()

    // ANTICHAT-PATCH: UP-OS-033 rebrand log subsystems, queue labels, Keychain service and temp/log directory names to app.antichat / AntiChat
    private static let log = Logger(subsystem: "app.antichat", category: "MemoryPressure")
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-033 rebrand log subsystems, queue labels, Keychain service and temp/log directory names to app.antichat / AntiChat
    private let queue = DispatchQueue(label: "app.antichat.memory-pressure", qos: .utility)
    // ANTICHAT-PATCH-END
    private var source: DispatchSourceMemoryPressure?

    // ANTICHAT-PATCH: UP-OS-008 D-08: pressure responses go to the injected ResidencyHost (Osaurus UI caches and ModelRuntime are not vendored)
    // Read on `queue` (event handler) and written by the scheduler (G-011); guarded by `hostLock`.
    private let hostLock = NSLock()
    private var _host: (any ResidencyHost)?
    package var host: (any ResidencyHost)? {
        get { hostLock.withLock { _host } }
        set { hostLock.withLock { _host = newValue } }
    }

    package init(host: (any ResidencyHost)? = nil) {
        self._host = host
    }
    // ANTICHAT-PATCH-END

    /// Install the memory-pressure handler. Idempotent; called once at launch.
    public func start() {
        queue.sync {
            guard source == nil else { return }
            let src = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: queue
            )
            src.setEventHandler { [weak self] in
                guard let self, let source = self.source else { return }
                let event = source.data
                if event.contains(.critical) {
                    Self.log.warning("critical memory pressure — freeing caches and idle models")
                    self.respondToWarning()
                    self.respondToCritical()
                } else if event.contains(.warning) {
                    Self.log.info("memory pressure warning — freeing app caches")
                    self.respondToWarning()
                }
            }
            src.activate()
            source = src
        }
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
        }
    }

    /// Warning tier: drop reconstructible UI caches and return MLX's
    /// freed-buffer pool to the allocator. Everything here is re-derived
    /// lazily on next use; nothing user-visible is lost.
    // ANTICHAT-PATCH: UP-OS-008 (warning tier)
    private func respondToWarning() {
        guard let host else { return }
        Task { await host.trimCaches() }
    }
    // ANTICHAT-PATCH-END

    /// Critical tier: additionally release idle (lease-free) model weights
    /// through the normal unload path and purge detection memo caches.
    private func respondToCritical() {
        // ANTICHAT-PATCH: UP-OS-008 (critical tier: evict lease-free models)
        guard let host else { return }
        Task {
            var unloaded: [String] = []
            for name in await host.residentModels() where await host.leaseCount(name) == 0 {
                if await host.evict(name) { unloaded.append(name) }
            }
        // ANTICHAT-PATCH-END
            if unloaded.isEmpty {
                Self.log.info("critical memory pressure: no idle models to unload")
            } else {
                Self.log.warning(
                    "critical memory pressure: unloaded \(unloaded.joined(separator: ", "), privacy: .public)"
                )
            }
        }
    }
}
