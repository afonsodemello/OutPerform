//
//  PermissionGate.swift
//  OutPerform
//
//  iOS shows one permission popup at a time. If the app asks for two at once
//  (say Bluetooth and Apple Health), the second is silently dropped. That's
//  how the Apple Health prompt disappeared once the band arrived: picking the
//  band or "All sources" started Bluetooth, its alert took the screen, and
//  the Health request in the same moment never showed.
//
//  Every permission request goes through this gate, which runs them one
//  after another, each waiting until the previous popup has been answered.
//

import Foundation

@MainActor
final class PermissionGate {
    static let shared = PermissionGate()
    private var tail: Task<Void, Never>?

    /// Run `request` once every earlier request has finished.
    func run<T>(_ request: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await request()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
