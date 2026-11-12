import Foundation
import IOKit.ps

/// Owns both the IOPS source and its callback context. The source is invalidated
/// before the context is released, even if the monitor goes away without stop().
@MainActor
final class PowerSourceObservation {
    private final class Context {
        let onChange: @MainActor () -> Void

        init(onChange: @escaping @MainActor () -> Void) {
            self.onChange = onChange
        }
    }

    private let context: Context
    private(set) var source: CFRunLoopSource?

    init(onChange: @escaping @MainActor () -> Void) {
        context = Context(onChange: onChange)
        source = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let context = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
            // This source is installed exclusively on the main run loop.
            MainActor.assumeIsolated { context.onChange() }
        }, Unmanaged.passUnretained(context).toOpaque())?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    func invalidate() {
        if let source { CFRunLoopSourceInvalidate(source) }
        source = nil
    }

    deinit {
        if let source { CFRunLoopSourceInvalidate(source) }
    }
}
