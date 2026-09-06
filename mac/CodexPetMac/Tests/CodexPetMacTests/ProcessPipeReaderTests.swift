import Foundation
import XCTest
@testable import Statelet

private final class PipeReaderTestData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

final class ProcessPipeReaderTests: XCTestCase {
    func testReaderKeepsItsDescriptorWhenOriginalFoundationHandleCloses() throws {
        let pipe = Pipe()
        let reader = try XCTUnwrap(ProcessPipeReader(handle: pipe.fileHandleForReading))
        let output = PipeReaderTestData()
        let ended = expectation(description: "reader reached EOF")
        try pipe.fileHandleForReading.close()
        DispatchQueue.global(qos: .utility).async {
            reader.drain { output.append($0) }
            ended.fulfill()
        }
        let payload = Data("retained descriptor".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()
        wait(for: [ended], timeout: 2)
        XCTAssertEqual(output.data, payload)
    }

    func testStopFinishesWhileWriterStillKeepsPipeOpen() throws {
        let pipe = Pipe()
        let reader = try XCTUnwrap(ProcessPipeReader(handle: pipe.fileHandleForReading))
        let received = expectation(description: "reader consumed initial data")
        let ended = expectation(description: "reader stopped without waiting for EOF")
        DispatchQueue.global(qos: .utility).async {
            reader.drain { _ in received.fulfill() }
            ended.fulfill()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data([1]))
        wait(for: [received], timeout: 2)
        reader.stop()
        wait(for: [ended], timeout: 1)
        // Keep the writer open until cancellation has completed. Closing it
        // before the wait would hide the descendant-retained-stream regression.
        try pipe.fileHandleForWriting.close()
        try pipe.fileHandleForReading.close()
    }

    func testReaderDrainsMoreThanOneBufferThroughEOF() throws {
        let pipe = Pipe()
        let reader = try XCTUnwrap(ProcessPipeReader(handle: pipe.fileHandleForReading))
        let output = PipeReaderTestData()
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let ended = expectation(description: "reader drained complete stream")
        let written = expectation(description: "writer finished")
        DispatchQueue.global(qos: .utility).async {
            reader.drain { output.append($0) }
            ended.fulfill()
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                try pipe.fileHandleForWriting.write(contentsOf: payload)
                try pipe.fileHandleForWriting.close()
            } catch {
                XCTFail("pipe writer failed")
            }
            written.fulfill()
        }
        wait(for: [ended, written], timeout: 3)
        XCTAssertEqual(output.data, payload)
        try pipe.fileHandleForReading.close()
    }
}
