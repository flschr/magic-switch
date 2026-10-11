import Foundation

struct HandoffOperationGate {
  private(set) var activeOperation: UUID?

  mutating func begin() -> UUID? {
    guard activeOperation == nil else { return nil }
    let operation = UUID()
    activeOperation = operation
    return operation
  }

  func contains(_ operation: UUID) -> Bool {
    activeOperation == operation
  }

  @discardableResult
  mutating func finish(_ operation: UUID) -> Bool {
    guard activeOperation == operation else { return false }
    activeOperation = nil
    return true
  }
}
