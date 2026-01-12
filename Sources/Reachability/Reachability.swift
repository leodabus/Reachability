// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import SystemConfiguration

// MARK: - Reachability
/**
 A lightweight wrapper around `SCNetworkReachability` that monitors the reachability flags
 for either a hostname (preferred) or a "zero" IPv4/IPv6 address.

 ## How it works
 - Creates an `SCNetworkReachability` reference (by hostname or address).
 - Registers a callback and binds the reachability object to a private serial queue.
 - When flags change, posts `Notification.Name Network.flagsChanged` on the **main queue**.

 ## Threading model
 - SystemConfiguration invokes the reachability callback on `serialQueue` because we call
   `SCNetworkReachabilitySetDispatchQueue`.
 - This type posts notifications on the **main thread** so observers (often UI) can react safely.

 ## Strict Concurrency (Swift 6 / "Sendable" checks)
 This class intentionally owns shared mutable state (`reachabilityFlags`, `isRunning`, etc).
 If you store instances globally (e.g. `static var`) you should isolate that global access
 (e.g. `@MainActor` or a lock), otherwise the compiler will warn about global shared state.

 ## Notifications
 - Posts `Network.flagsChanged` with `object: Reachability` whenever reachability flags change
   (and also once on startup).

 ## Important
 Apple recommends using `SCNetworkReachabilityCreateWithName` (hostname initializer) when
 possible. Address-based reachability is more error-prone and harder to reason about.
 */
public final class Reachability: @unchecked Sendable {

    // MARK: Stored properties

    /// The hostname being monitored (if created via hostname). `nil` when created via address.
    public private(set) var hostname: String?

    /// Whether the reachability reference was created using an IPv6 zero address fallback.
    public private(set) var ipv6 = false

    /// Indicates whether callbacks/dispatch queue are currently installed.
    public private(set) var isRunning = false

    /**
     Controls whether WWAN (cellular) is considered "reachable".
     - If `false`, cellular connectivity will be treated as unreachable.
     */
    public var isReachableOnWWAN: Bool

    /// The underlying SystemConfiguration reachability reference.
    private var reachability: SCNetworkReachability

    /**
     The last observed reachability flags.
     Used to detect changes and avoid posting duplicate notifications.
     */
    public private(set) var reachabilityFlags = SCNetworkReachabilityFlags()

    /**
     Serial queue used by SystemConfiguration to deliver reachability callbacks.
     Keeping it serial makes state updates deterministic and avoids flag races.
     */
    static private let serialQueue = DispatchQueue(label: "ReachabilityQueue")

    // MARK: Initializers

    /**
     Creates a reachability reference using a "zero" IPv4 address and falls back to IPv6.

     - Warning: This initializer is discouraged in favor of `init(hostname:)`.
       Address-based reachability can be misleading depending on the routing context.

     - Throws:
       - `Network.Error.failedToInitializeWith` if both IPv4 and IPv6 address creation fail.
       - `Network.Error.failedToSetCallout` if the callback cannot be installed.
       - `Network.Error.failedToSetDispatchQueue` if the dispatch queue cannot be installed.
     */
    init() throws {
        // Attempt IPv4 first.
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zeroAddress.sin_family = sa_family_t(AF_INET)

        if let reachability = withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, $0)
            }
        }) {
            self.reachability = reachability
        } else {
            // Fallback to IPv6.
            var zeroAddress6 = sockaddr_in6()
            // NOTE: You may want `MemoryLayout<sockaddr_in6>.size` here.
            zeroAddress6.sin6_len = UInt8(MemoryLayout<sockaddr_in>.size)
            zeroAddress6.sin6_family = sa_family_t(AF_INET6)

            guard let reachability = withUnsafePointer(to: &zeroAddress6, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, $0)
                }
            }) else {
                throw Network.Error.failedToInitializeWith(zeroAddress, zeroAddress6)
            }

            self.reachability = reachability
            print(zeroAddress6.sin6_addr)
            ipv6 = true
        }

        // By default, allow WWAN to be treated as reachable.
        self.isReachableOnWWAN = true

        // Start monitoring immediately.
        try start()
    }

    /**
     Creates a reachability reference for a hostname using `SCNetworkReachabilityCreateWithName`.

     This is the preferred initializer because it matches Apple's recommended API usage.

     - Parameter hostname: A hostname (e.g. `"apple.com"`).

     - Throws:
       - `Network.Error.failedToCreateWith` if the reachability ref cannot be created.
       - `Network.Error.failedToSetCallout` if the callback cannot be installed.
       - `Network.Error.failedToSetDispatchQueue` if the dispatch queue cannot be installed.
     */
    init<S: StringProtocol>(hostname: S) throws {
        let hostname = String(hostname)

        guard let reachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, hostname) else {
            throw Network.Error.failedToCreateWith(hostname)
        }

        self.reachability = reachability
        self.hostname = hostname

        // By default, allow WWAN to be treated as reachable.
        self.isReachableOnWWAN = true

        // Start monitoring immediately.
        try start()
    }

    // MARK: Public API

    /**
     Computed reachability status exposed as your `Network.Status`.

     Logic:
     - `.wifi` when connected and reachable via Wi-Fi.
     - `.wwan` when connected and running on a physical device (not simulator).
     - `.unreachable` otherwise.
     */
    public var status: Network.Status {
        isConnectedToNetwork && isReachableViaWiFi ? .wifi :
        isConnectedToNetwork && isRunningOnDevice  ? .wwan :
        .unreachable
    }

    /**
     Returns `true` when the host/address is considered reachable.

     This checks:
     - Flags indicate `reachable`
     - No transient+required connection state
     - If on device and WWAN is active, must also allow WWAN via `isReachableOnWWAN`
     */
    public var isConnectedToNetwork: Bool {
        reachable &&
        !isConnectionRequiredAndTransientConnection &&
        !(isRunningOnDevice && isWWAN && !isReachableOnWWAN)
    }

    /// `true` when reachable and running on a physical device without WWAN active.
    public var isReachableViaWiFi: Bool { reachable && isRunningOnDevice && !isWWAN }

    /**
     Detects whether this code is running on a real device vs the iOS simulator.

     Used to decide whether WWAN logic is meaningful (simulator has no WWAN flag semantics).
     */
    public var isRunningOnDevice: Bool = {
        print("isRunningOnDevice")
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }()

    /// Stops monitoring when the object is deallocated.
    deinit { stop() }
}

// MARK: - Private monitoring plumbing
private extension Reachability {

    /**
     Installs the SystemConfiguration callback + dispatch queue and emits an initial notification.

     - Important:
       `SCNetworkReachabilitySetDispatchQueue` makes the callback execute on `serialQueue`.
       We then forward notifications to the main queue.
     */
    private func start() throws {
        guard !isRunning else { return }

        // Provide `self` to the callback via `context.info`.
        var context = SCNetworkReachabilityContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        context.info = Unmanaged<Reachability>.passUnretained(self).toOpaque()

        // Callback invoked by SystemConfiguration whenever flags may have changed.
        let callout: SCNetworkReachabilityCallBack = {
            guard
                let info = $2,
                case let reachability = Unmanaged<Reachability>.fromOpaque(info).takeUnretainedValue(),
                reachability.flags != reachability.reachabilityFlags
            else { return }

            // Update cached flags.
            reachability.reachabilityFlags = reachability.flags

            // Post on main for UI-safety.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Network.flagsChanged, object: reachability)
            }
        }

        // Install callback.
        guard SCNetworkReachabilitySetCallback(reachability, callout, &context) else {
            stop()
            throw Network.Error.failedToSetCallout
        }

        // Bind callback delivery to our serial queue.
        guard SCNetworkReachabilitySetDispatchQueue(reachability, Reachability.serialQueue) else {
            stop()
            throw Network.Error.failedToSetDispatchQueue
        }

        // Post an initial notification once monitoring begins.
        Reachability.serialQueue.async { [weak self] in
            NotificationCenter.default.post(name: Network.flagsChanged, object: self)
        }

        isRunning = true
    }

    /**
     Removes callback + dispatch queue.

     After calling `stop()`, the class will no longer post `Network.flagsChanged`.
     */
    private func stop() {
        defer { isRunning = false }
        SCNetworkReachabilitySetCallback(reachability, nil, nil)
        SCNetworkReachabilitySetDispatchQueue(reachability, nil)
    }

    // MARK: Flags

    /**
     Current reachability flags snapshot.

     - Returns: The flags for the monitored hostname/address, or empty flags if retrieval fails.
     */
    var flags: SCNetworkReachabilityFlags {
        var flags = SCNetworkReachabilityFlags()
        return withUnsafeMutablePointer(to: &flags) {
            SCNetworkReachabilityGetFlags(reachability, UnsafeMutablePointer($0))
        } ? flags : SCNetworkReachabilityFlags()
    }

    /**
     Compares the current flags with the previously cached flags and posts `flagsChanged`
     if they differ.

     Note: this is not currently used by `start()` because the callback already performs
     the same change detection.
     */
    func flagsChanged() {
        guard flags != reachabilityFlags else { return }
        reachabilityFlags = flags
        NotificationCenter.default.post(name: Network.flagsChanged, object: self)
    }

    // MARK: Flag helpers (booleans)

    /// The node can be reached via a transient connection (e.g. PPP).
    var transientConnection: Bool { flags.contains(.transientConnection) }

    /// The node can be reached using the current network configuration.
    var reachable: Bool { flags.contains(.reachable) }

    /// The node can be reached, but a connection must first be established.
    var connectionRequired: Bool { flags.contains(.connectionRequired) }

    /// Traffic will initiate the connection (on-traffic).
    var connectionOnTraffic: Bool { flags.contains(.connectionOnTraffic) }

    /// User intervention is required to establish the connection.
    var interventionRequired: Bool { flags.contains(.interventionRequired) }

    /// Connection will be established "On Demand".
    var connectionOnDemand: Bool { flags.contains(.connectionOnDemand) }

    /// The node address is associated with a local interface.
    var isLocalAddress: Bool { flags.contains(.isLocalAddress) }

    /// Traffic goes directly to an interface, not through a gateway.
    var isDirect: Bool { flags.contains(.isDirect) }

    /// The node can be reached via cellular (WWAN).
    var isWWAN: Bool { flags.contains(.isWWAN) }

    /**
     Special-case: flags exactly equal to `[.connectionRequired, .transientConnection]`.

     Used by `isConnectedToNetwork` to reject transient+required connections.
     */
    var isConnectionRequiredAndTransientConnection: Bool {
        flags == [.connectionRequired, .transientConnection]
    }
}

// MARK: - Convenience
fileprivate extension StringProtocol {
    /// Convenience factory to create a `Reachability` using a hostname string.
    func reachability() throws -> Reachability { try Reachability(hostname: self) }
}
