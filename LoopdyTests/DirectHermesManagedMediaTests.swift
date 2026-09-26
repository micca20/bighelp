import Foundation
import Testing
@testable import Loopdy

@MainActor
struct DirectHermesManagedMediaTests {
    @Test func consumerProbesThenStreamsOnlyBoundedSequentialRanges() async throws {
        let file = mediaFile(byteCount: DirectHermesManagedMediaConsumer.maximumRangeRequestBytes * 2 + 17)
        let reader = ManagedMediaReader(file: file)
        let consumer = DirectHermesManagedMediaConsumer(file: file, reader: reader)
        let metadata = try await consumer.prepare()
        var deliveredByteCount = 0

        try await consumer.consume(range: 0..<metadata.byteCount) { bytes in
            deliveredByteCount += bytes.count
        }

        #expect(reader.probeCount == 1)
        #expect(reader.ranges == [
            0..<DirectHermesManagedMediaConsumer.maximumRangeRequestBytes,
            DirectHermesManagedMediaConsumer.maximumRangeRequestBytes..<(DirectHermesManagedMediaConsumer.maximumRangeRequestBytes * 2),
            (DirectHermesManagedMediaConsumer.maximumRangeRequestBytes * 2)..<metadata.byteCount,
        ])
        #expect(reader.ranges.allSatisfy { $0.count <= DirectHermesManagedMediaConsumer.maximumRangeRequestBytes })
        #expect(deliveredByteCount == metadata.byteCount)
    }

    @Test func missingByteRangeSupportStopsBeforeAnyBodyRead() async throws {
        let file = mediaFile(byteCount: 1_024)
        let reader = ManagedMediaReader(file: file)
        reader.acceptsByteRanges = false
        let consumer = DirectHermesManagedMediaConsumer(file: file, reader: reader)

        await #expect(throws: DirectHermesManagedFilesError.self) {
            _ = try await consumer.prepare()
        }
        #expect(reader.probeCount == 1)
        #expect(reader.ranges.isEmpty)
    }

    @Test func ownerLossAfterRangeAwaitCannotPublishReturnedBytes() async throws {
        let file = mediaFile(byteCount: 2_048)
        let reader = ManagedMediaReader(file: file)
        reader.retireAfterFirstRange = true
        let consumer = DirectHermesManagedMediaConsumer(file: file, reader: reader)
        var deliveredByteCount = 0

        await #expect(throws: DirectHermesManagedFilesError.self) {
            try await consumer.consume(range: 0..<2_048) { bytes in
                deliveredByteCount += bytes.count
            }
        }
        #expect(reader.ranges == [0..<2_048])
        #expect(deliveredByteCount == 0)
    }

    @Test func retiredConsumerStartsNoNewProbeOrRangeWork() async throws {
        let file = mediaFile(byteCount: 2_048)
        let reader = ManagedMediaReader(file: file)
        let consumer = DirectHermesManagedMediaConsumer(file: file, reader: reader)
        consumer.retire()

        await #expect(throws: DirectHermesManagedFilesError.self) {
            try await consumer.consume(range: 0..<2_048) { _ in }
        }
        #expect(reader.probeCount == 0)
        #expect(reader.ranges.isEmpty)
    }

    @Test func assetRequestRangeIsClampedWithoutIntegerOverflow() {
        #expect(DirectHermesManagedMediaResourceLoader.maximumOutstandingRequests == 8)
        #expect(DirectHermesManagedMediaResourceLoader.requestedRange(
            requestedOffset: 512,
            currentOffset: 1_024,
            requestedLength: 4_096,
            requestsAllDataToEnd: false,
            totalByteCount: 2_000
        ) == 1_024..<2_000)
        #expect(DirectHermesManagedMediaResourceLoader.requestedRange(
            requestedOffset: 512,
            currentOffset: 1_024,
            requestedLength: 1_000,
            requestsAllDataToEnd: false,
            totalByteCount: 5_000
        ) == 1_024..<1_512)
        #expect(DirectHermesManagedMediaResourceLoader.requestedRange(
            requestedOffset: 512,
            currentOffset: 1_024,
            requestedLength: 1,
            requestsAllDataToEnd: true,
            totalByteCount: 2_000
        ) == 1_024..<2_000)
        #expect(DirectHermesManagedMediaResourceLoader.requestedRange(
            requestedOffset: Int64.max,
            currentOffset: Int64.max,
            requestedLength: Int.max,
            requestsAllDataToEnd: false,
            totalByteCount: 2_000
        ) == nil)
    }

    @Test func supportedKindsAreLimitedToListedAudioAndVideoFiles() {
        #expect(DirectHermesManagedMediaPlayback.supports(mediaFile(byteCount: 1, mimeType: "audio/mpeg")))
        #expect(DirectHermesManagedMediaPlayback.supports(mediaFile(byteCount: 1, mimeType: "video/mp4")))
        #expect(!DirectHermesManagedMediaPlayback.supports(mediaFile(byteCount: 1, mimeType: "image/png")))
        #expect(!DirectHermesManagedMediaPlayback.supports(mediaFile(byteCount: 0, mimeType: "video/mp4")))
    }

    private func mediaFile(byteCount: Int, mimeType: String = "video/mp4") -> HermesManagedFile {
        .init(
            path: "/srv/team/project/sample.mp4",
            name: "sample.mp4",
            isDirectory: false,
            byteCount: byteCount,
            modifiedAt: Date(timeIntervalSince1970: 1),
            mimeType: mimeType
        )
    }
}

@MainActor
private final class ManagedMediaReader: DirectHermesManagedMediaReading {
    let file: HermesManagedFile
    var ownsScope = true
    var acceptsByteRanges = true
    var retireAfterFirstRange = false
    var probeCount = 0
    var ranges: [Range<Int>] = []

    init(file: HermesManagedFile) {
        self.file = file
    }

    func probeStream(_ file: HermesManagedFile) async throws -> HermesManagedMediaProbe {
        probeCount += 1
        return .init(file: file, acceptsByteRanges: acceptsByteRanges)
    }

    func readMediaRange(
        _ file: HermesManagedFile,
        range: Range<Int>
    ) async throws -> HermesManagedFileRange {
        ranges.append(range)
        if retireAfterFirstRange { ownsScope = false }
        return .init(
            file: file,
            requested: range,
            totalByteCount: self.file.byteCount ?? 0,
            bytes: Data(repeating: 0x5a, count: range.count)
        )
    }
}
