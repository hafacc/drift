import Foundation
import Synchronization
import Testing

/// One fetch at a time, shared by whoever asks while it runs.
struct SingleFlightTests {
  @Test func callersDuringARunShareIt() async {
    let flight = SingleFlight<Int>()
    let runs = Mutex(0)
    let hold = Hold()
    async let first = flight.run {
      let run = runs.withLock { count in
        count += 1
        return count
      }
      await hold.wait()
      return run
    }
    await hold.untilWaiting()
    async let second = flight.run {
      runs.withLock { count in
        count += 1
        return count
      }
    }
    // Lets the second call join before the first finishes.
    try? await Task.sleep(nanoseconds: 50_000_000)
    await hold.open()
    let results = await [first, second]
    #expect(results == [1, 1])
    #expect(runs.withLock { $0 } == 1)
  }

  @Test func aCallAfterARunStartsAnother() async {
    let flight = SingleFlight<Int>()
    let runs = Mutex(0)
    let operation: @Sendable () async -> Int = {
      runs.withLock { count in
        count += 1
        return count
      }
    }
    let first = await flight.run(operation)
    let second = await flight.run(operation)
    #expect(first == 1)
    #expect(second == 2)
  }
}

/// How long a widget waits for the app to take a handed-over press.
struct WaitUntilTests {
  @Test func returnsOnceTheConditionHolds() async {
    let start = Date()
    let ready = start + 0.1
    let held = await waitUntil(timeout: 1.5, checkingEvery: 0.02) { Date() >= ready }
    #expect(held)
    #expect(Date().timeIntervalSince(start) < 1)
  }

  @Test func givesUpAtTheTimeout() async {
    let start = Date()
    let held = await waitUntil(timeout: 0.2, checkingEvery: 0.05) { false }
    let waited = Date().timeIntervalSince(start)
    #expect(!held)
    #expect(waited >= 0.2)
    #expect(waited < 1)
  }

  @Test func checksBeforeWaiting() async {
    let held = await waitUntil(timeout: 0, checkingEvery: 1) { true }
    #expect(held)
  }
}

/// Holds an operation until the test lets it finish.
private actor Hold {
  private var waiter: CheckedContinuation<Void, Never>?
  private var isOpen = false

  /// Suspend until `open()`.
  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiter = $0 }
  }

  /// Return once something waits.
  func untilWaiting() async {
    while waiter == nil && !isOpen {
      await Task.yield()
    }
  }

  /// Let the waiter go.
  func open() {
    isOpen = true
    waiter?.resume()
    waiter = nil
  }
}
