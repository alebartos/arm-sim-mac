import Combine
import SwiftUI

/// Drop-in replacement for `@State`.
///
/// In recent SDKs `@State` is implemented as a macro whose plugin ships only with Xcode,
/// so it cannot be compiled with the Command Line Tools alone. This wrapper keeps the
/// value in a `StateObject`-owned box and offers the same `wrappedValue` / `$binding` API.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}
