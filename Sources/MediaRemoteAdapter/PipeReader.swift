import Foundation

/// The ONE way this package reads a child process's pipe.
///
/// The class it closes: a `readabilityHandler` that can return WITHOUT draining the descriptor
/// (an early `guard ... else { return }`), or that stays installed after EOF, is re-invoked
/// immediately by its dispatch source — a busy loop that holds a core at 100% for as long as the
/// host process lives, one per leaked pipe. `getTrackInfo` shipped exactly that: its state was
/// captured weakly, died on return, and every artwork fetch added a spinner.
///
/// So the handler here ALWAYS reads `availableData` first, ALWAYS detaches at EOF, and holds its
/// closures (and everything they capture) strongly — their lifetime is the reader's, released
/// exactly when it detaches.
enum PipeReader {
    static func attach(_ handle: FileHandle,
                       onEOF: @escaping @Sendable () -> Void = {},
                       onData: @escaping @Sendable (Data) -> Void) {
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                onEOF()
                return
            }
            onData(data)
        }
    }
}
