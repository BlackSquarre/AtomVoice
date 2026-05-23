import Foundation

protocol SettingsBackend: AnyObject {
    var notificationObject: Any? { get }

    func string(forKey key: String) -> String?
    func bool(forKey key: String, default defaultValue: Bool) -> Bool
    func double(forKey key: String, default defaultValue: Double) -> Double
    func integer(forKey key: String, default defaultValue: Int) -> Int
    func set(_ value: Any?, forKey key: String)
    func register(defaults: [String: Any])
    func observe(key: String, handler: @escaping () -> Void) -> SettingsObservation
}

final class SettingsObservation {
    private var onCancel: (() -> Void)?

    init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard let onCancel else { return }
        self.onCancel = nil
        onCancel()
    }

    deinit {
        cancel()
    }
}

final class UserDefaultsBackend: SettingsBackend {
    private let defaults: UserDefaults

    var notificationObject: Any? { defaults }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    func double(forKey key: String, default defaultValue: Double) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.double(forKey: key)
    }

    func integer(forKey key: String, default defaultValue: Int) -> Int {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.integer(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func register(defaults registration: [String: Any]) {
        defaults.register(defaults: registration)
    }

    func observe(key: String, handler: @escaping () -> Void) -> SettingsObservation {
        let observer = UserDefaultsKeyObserver(handler: handler)
        defaults.addObserver(observer, forKeyPath: key, options: [.new], context: nil)
        return SettingsObservation { [defaults, observer] in
            defaults.removeObserver(observer, forKeyPath: key)
        }
    }
}

private final class UserDefaultsKeyObserver: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        handler()
    }
}

final class InMemorySettingsBackend: SettingsBackend {
    private var values: [String: Any] = [:]
    private var registeredDefaults: [String: Any] = [:]
    private var observers: [String: [UUID: () -> Void]] = [:]
    private let lock = NSLock()

    var notificationObject: Any? { self }

    func string(forKey key: String) -> String? {
        value(forKey: key) as? String
    }

    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        if let bool = value(forKey: key) as? Bool { return bool }
        if let number = value(forKey: key) as? NSNumber { return number.boolValue }
        return defaultValue
    }

    func double(forKey key: String, default defaultValue: Double) -> Double {
        if let double = value(forKey: key) as? Double { return double }
        if let number = value(forKey: key) as? NSNumber { return number.doubleValue }
        return defaultValue
    }

    func integer(forKey key: String, default defaultValue: Int) -> Int {
        if let int = value(forKey: key) as? Int { return int }
        if let number = value(forKey: key) as? NSNumber { return number.intValue }
        return defaultValue
    }

    func set(_ value: Any?, forKey key: String) {
        let handlers: [() -> Void]
        lock.lock()
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        if let keyObservers = observers[key] {
            handlers = Array(keyObservers.values)
        } else {
            handlers = []
        }
        lock.unlock()

        handlers.forEach { $0() }
    }

    func register(defaults registration: [String: Any]) {
        lock.lock()
        for (key, value) in registration {
            registeredDefaults[key] = value
        }
        lock.unlock()
    }

    func observe(key: String, handler: @escaping () -> Void) -> SettingsObservation {
        let id = UUID()
        lock.lock()
        observers[key, default: [:]][id] = handler
        lock.unlock()

        return SettingsObservation { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.observers[key]?[id] = nil
            self.lock.unlock()
        }
    }

    private func value(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key] ?? registeredDefaults[key]
    }
}
