import Dispatch
import Foundation
import Synchronization

/// Read a pipe in the background while the test waits or reads another pipe.
final class TestPipeReader: Sendable {
    private let data = Mutex(Data())
    private let readers = DispatchGroup()

    /// Start after Process.run(), when the child has its own write handle.
    init(_ pipe: Pipe) {
        pipe.fileHandleForWriting.closeFile()
        readers.enter()
        DispatchQueue.global().async {
            let result = pipe.fileHandleForReading.readDataToEndOfFile()
            self.data.withLock { $0 = result }
            self.readers.leave()
        }
    }

    func wait() -> Data {
        readers.wait()
        return data.withLock { $0 }
    }
}
