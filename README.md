# Reachability

A lightweight Swift wrapper around `SCNetworkReachability` for monitoring network connectivity changes on Apple platforms.

This package provides a simple, notification-based API to observe changes in network reachability (Wi-Fi, cellular, or offline), while keeping the implementation close to Apple’s `SystemConfiguration` framework.

---

## Features

- Monitor network reachability using `SCNetworkReachability`
- Supports hostname-based reachability (recommended by Apple)
- Optional fallback to address-based reachability
- Posts notifications when reachability flags change
- Notifications are delivered on the main thread (UI-safe)
- Swift Package Manager compatible
- No external dependencies

---

## Requirements

- Swift 5.9 or newer
- Apple platforms that support `SystemConfiguration`
  - iOS
  - macOS
  - tvOS
  - watchOS

> ⚠️ This package is Apple-platform only due to its dependency on `SystemConfiguration`.

---

## Installation

### Swift Package Manager

Add the package in Xcode or directly in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/YOUR_USERNAME/Reachability.git", from: "1.0.2")
]
```

---

## Usage (UIKit)

```swift
import Reachability
import UIKit

final class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        do {
            Network.reachability = try "www.google.com".reachability()
        } catch {
            print(error)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusManager(_:)),
            name: Network.flagsChanged,
            object: nil
        )
    }

    @objc func statusManager(_ notification: Notification) {
        updateUserInterface()
    }

    func updateUserInterface() {
        guard let reachability = Network.reachability else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            switch reachability.status {
            case .unreachable:
                view.backgroundColor = .red
            case .wifi:
                view.backgroundColor = .green
            case .wwan:
                view.backgroundColor = .yellow
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
```

---

## License

MIT License
