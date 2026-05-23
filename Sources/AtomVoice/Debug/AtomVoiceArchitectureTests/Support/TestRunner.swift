import CoreGraphics
import Darwin
import Foundation

struct TestRunner {
    private var failures: [String] = []
    private var passed = 0

    mutating func run(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("PASS \(name)")
        } catch {
            failures.append("\(name): \(error)")
            print("FAIL \(name): \(error)")
        }
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("All architecture tests passed (\(passed) cases)")
            exit(0)
        }

        print("\nArchitecture test failures:")
        failures.forEach { print("- \($0)") }
        exit(1)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let file: StaticString
    let line: UInt
    let message: String

    var description: String {
        "\(file):\(line) \(message)"
    }
}

func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "expectation failed",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard condition() else {
        throw TestFailure(file: file, line: line, message: message)
    }
}

func approximatelyEqual<T: BinaryFloatingPoint>(
    _ lhs: T,
    _ rhs: T,
    tolerance: T = 0.000_001
) -> Bool {
    abs(lhs - rhs) <= tolerance
}

func approximatelyEqual(
    _ lhs: CGRect,
    _ rhs: CGRect,
    tolerance: CGFloat = 0.000_001
) -> Bool {
    approximatelyEqual(lhs.origin.x, rhs.origin.x, tolerance: tolerance)
        && approximatelyEqual(lhs.origin.y, rhs.origin.y, tolerance: tolerance)
        && approximatelyEqual(lhs.size.width, rhs.size.width, tolerance: tolerance)
        && approximatelyEqual(lhs.size.height, rhs.size.height, tolerance: tolerance)
}

func require<T>(
    _ value: T?,
    _ message: String = "required value was nil",
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    guard let value else {
        throw TestFailure(file: file, line: line, message: message)
    }
    return value
}

func waitForAsyncCallbacks() async throws {
    try await Task.sleep(nanoseconds: 80_000_000)
}

func restoreDefaultsObject(_ object: Any?, forKey key: String) {
    if let object {
        UserDefaults.standard.set(object, forKey: key)
    } else {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

