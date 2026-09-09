import Darwin
import Foundation

final class ProcessPipeReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let queue: DispatchQueue

    init(fileHandle: FileHandle, label: String) {
        self.fileHandle = fileHandle
        queue = DispatchQueue(label: label, qos: .utility)
    }

    func start(
        onBytes: @escaping @Sendable (Data) -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) {
        queue.async { [self] in
            defer {
                try? fileHandle.close()
                onFinished()
            }
            readAvailableBytes(onBytes)
        }
    }

    func start(
        onLines: @escaping @Sendable ([String]) -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) {
        queue.async { [self] in
            var accumulator = ProcessLineAccumulator()
            defer {
                let trailingLines = accumulator.finish()
                if !trailingLines.isEmpty {
                    onLines(trailingLines)
                }
                try? fileHandle.close()
                onFinished()
            }
            readAvailableBytes { data in
                let lines = accumulator.append(data)
                if !lines.isEmpty {
                    onLines(lines)
                }
            }
        }
    }

    private func readAvailableBytes(_ onBytes: (Data) -> Void) {
        let descriptor = fileHandle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 4_096)

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }

            if bytesRead > 0 {
                onBytes(Data(buffer.prefix(bytesRead)))
            } else if bytesRead == 0 {
                return
            } else if errno != EINTR {
                return
            }
        }
    }
}

struct ProcessLineAccumulator {
    private var bufferedData = Data()

    mutating func append(_ data: Data) -> [String] {
        append(data, flushRemainder: false)
    }

    mutating func finish() -> [String] {
        append(Data(), flushRemainder: true)
    }

    private mutating func append(_ data: Data, flushRemainder: Bool) -> [String] {
        if !data.isEmpty {
            bufferedData.append(data)
        }

        var lines: [String] = []
        while let newlineIndex = bufferedData.firstIndex(of: 0x0A) {
            var lineData = bufferedData[..<newlineIndex]
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            lines.append(String(decoding: lineData, as: UTF8.self))
            bufferedData.removeSubrange(...newlineIndex)
        }

        if flushRemainder, !bufferedData.isEmpty {
            if bufferedData.last == 0x0D {
                bufferedData.removeLast()
            }
            lines.append(String(decoding: bufferedData, as: UTF8.self))
            bufferedData.removeAll(keepingCapacity: false)
        }
        return lines
    }
}
