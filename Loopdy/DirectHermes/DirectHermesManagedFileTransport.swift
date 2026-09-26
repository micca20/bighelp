import CryptoKit
import Foundation

struct DirectHermesManagedFileStagedUpload: Sendable {
    let bodyURL: URL
    let folderURL: URL
    let boundary: String
    let bodyByteCount: Int
    let payloadByteCount: Int
    let payloadSHA256: String

    fileprivate init(
        bodyURL: URL,
        folderURL: URL,
        boundary: String,
        bodyByteCount: Int,
        payloadByteCount: Int,
        payloadSHA256: String
    ) {
        self.bodyURL = bodyURL
        self.folderURL = folderURL
        self.boundary = boundary
        self.bodyByteCount = bodyByteCount
        self.payloadByteCount = payloadByteCount
        self.payloadSHA256 = payloadSHA256
    }

    func remove() {
        try? FileManager.default.removeItem(at: folderURL)
    }
}

/// Fixed, app-authored operations for Hermes' managed-files transport. No
/// caller can supply a URL, HTTP method, or header through this seam.
enum DirectHermesManagedFileTransportRequest: Sendable {
    case download(path: String, scope: DirectHermesWorkspaceFileScope, maximumBytes: Int)
    case streamHead(path: String, scope: DirectHermesWorkspaceFileScope)
    case streamRange(
        path: String,
        scope: DirectHermesWorkspaceFileScope,
        range: Range<Int>,
        maximumBytes: Int
    )
    case upload(
        path: String,
        scope: DirectHermesWorkspaceFileScope,
        fileName: String,
        mimeType: String,
        staged: DirectHermesManagedFileStagedUpload,
        overwrite: Bool,
        maximumResponseBytes: Int
    )
    case verifyDownload(
        path: String,
        scope: DirectHermesWorkspaceFileScope,
        expectedByteCount: Int,
        maximumBytes: Int
    )

    var isMutation: Bool {
        if case .upload = self { return true }
        return false
    }
}

private enum DirectHermesManagedFileTransport {
    static let maximumTransferBytes = 16 * 1_024 * 1_024
    static let maximumMutationResponseBytes = 256 * 1_024
    static let maximumMultipartOverheadBytes = 16 * 1_024
    static let sha256DigestByteCount = 32

    enum ResponseBody: Sendable {
        case bytes(maximumBytes: Int)
        case none
        case sha256(expectedByteCount: Int, maximumBytes: Int)
    }

    struct PreparedRequest: Sendable {
        let route: String
        let method: String
        let query: [URLQueryItem]
        let accept: String
        let contentType: String?
        let bodyFileURL: URL?
        let bodyByteCount: Int?
        let responseBody: ResponseBody
    }

    static func prepare(_ request: DirectHermesManagedFileTransportRequest) throws -> PreparedRequest {
        switch request {
        case .download(let path, let scope, let maximumBytes):
            try validate(path: path, scope: scope)
            try validateTransferLimit(maximumBytes)
            return .init(
                route: "/api/files/download",
                method: "GET",
                query: [.init(name: "path", value: path)],
                accept: "application/octet-stream",
                contentType: nil,
                bodyFileURL: nil,
                bodyByteCount: nil,
                responseBody: .bytes(maximumBytes: maximumBytes)
            )

        case .streamHead(let path, let scope):
            try validate(path: path, scope: scope)
            return .init(
                route: "/api/files/stream",
                method: "HEAD",
                query: [.init(name: "path", value: path)],
                accept: "audio/*, video/*",
                contentType: nil,
                bodyFileURL: nil,
                bodyByteCount: nil,
                responseBody: .none
            )

        case .streamRange(let path, let scope, let range, let maximumBytes):
            try validate(path: path, scope: scope)
            try validateTransferLimit(maximumBytes)
            let length = range.upperBound.subtractingReportingOverflow(range.lowerBound)
            guard range.lowerBound >= 0, !length.overflow, length.partialValue > 0,
                  length.partialValue <= maximumBytes else {
                throw DirectHermesError.messageTooLarge
            }
            return .init(
                route: "/api/files/stream",
                method: "GET",
                query: [.init(name: "path", value: path)],
                accept: "audio/*, video/*",
                contentType: nil,
                bodyFileURL: nil,
                bodyByteCount: nil,
                responseBody: .bytes(maximumBytes: maximumBytes)
            )

        case .upload(
            let path, let scope, let fileName, let mimeType, let staged, let overwrite,
            let maximumResponseBytes
        ):
            try validate(path: path, scope: scope)
            try validate(fileName: fileName)
            try validate(mimeType: mimeType)
            try validate(staged: staged)
            guard staged.payloadByteCount <= maximumTransferBytes,
                  (1...maximumMutationResponseBytes).contains(maximumResponseBytes) else {
                throw DirectHermesError.messageTooLarge
            }
            return .init(
                route: "/api/files/upload-stream",
                method: "POST",
                query: [],
                accept: "application/json",
                contentType: "multipart/form-data; boundary=\(staged.boundary)",
                bodyFileURL: staged.bodyURL,
                bodyByteCount: staged.bodyByteCount,
                responseBody: .bytes(maximumBytes: maximumResponseBytes)
            )

        case .verifyDownload(let path, let scope, let expectedByteCount, let maximumBytes):
            try validate(path: path, scope: scope)
            try validateTransferLimit(maximumBytes)
            guard expectedByteCount > 0, expectedByteCount <= maximumBytes else {
                throw DirectHermesError.messageTooLarge
            }
            return .init(
                route: "/api/files/download",
                method: "GET",
                query: [.init(name: "path", value: path)],
                accept: "application/octet-stream",
                contentType: nil,
                bodyFileURL: nil,
                bodyByteCount: nil,
                responseBody: .sha256(
                    expectedByteCount: expectedByteCount,
                    maximumBytes: maximumBytes
                )
            )
        }
    }

    static func response(
        from response: DirectHermesHTTP.Response
    ) throws -> DirectHermesManagedFileBinaryResponse {
        let contentType = try boundedHeader("Content-Type", in: response.http, maximumBytes: 256)
        let contentRange = try boundedHeader("Content-Range", in: response.http, maximumBytes: 256)
        let rawRanges = try boundedHeader("Accept-Ranges", in: response.http, maximumBytes: 64)
        let acceptsByteRanges = rawRanges?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "bytes"
        let contentLength: Int?
        if let rawLength = try boundedHeader("Content-Length", in: response.http, maximumBytes: 32) {
            guard !rawLength.isEmpty,
                  rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int(rawLength), parsed >= 0 else {
                throw DirectHermesError.invalidResponse
            }
            contentLength = parsed
        } else {
            contentLength = nil
        }
        return .init(
            statusCode: response.http.statusCode,
            contentType: contentType,
            contentLength: contentLength,
            acceptsByteRanges: acceptsByteRanges,
            contentRange: contentRange,
            bytes: response.body
        )
    }

    static func requireJSON(_ response: DirectHermesManagedFileBinaryResponse) throws {
        let base = response.contentType?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard base == "application/json" else { throw DirectHermesError.invalidResponse }
    }

    static func readback(
        from response: DirectHermesHTTP.Response,
        expectedByteCount: Int
    ) throws -> DirectHermesManagedFileReadback {
        guard response.body.count == sha256DigestByteCount else {
            throw DirectHermesError.invalidResponse
        }
        let contentType = try boundedHeader("Content-Type", in: response.http, maximumBytes: 256)
        let contentRange = try boundedHeader("Content-Range", in: response.http, maximumBytes: 256)
        guard contentRange == nil else { throw DirectHermesError.invalidResponse }
        let contentLength: Int?
        if let rawLength = try boundedHeader("Content-Length", in: response.http, maximumBytes: 32) {
            guard !rawLength.isEmpty,
                  rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int(rawLength), parsed >= 0 else {
                throw DirectHermesError.invalidResponse
            }
            contentLength = parsed
        } else {
            contentLength = nil
        }
        return .init(
            statusCode: response.http.statusCode,
            contentType: contentType,
            contentLength: contentLength,
            byteCount: expectedByteCount,
            sha256: response.body.map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func validateTransferLimit(_ maximumBytes: Int) throws {
        guard (1...maximumTransferBytes).contains(maximumBytes) else {
            throw DirectHermesError.messageTooLarge
        }
    }

    private static func validate(
        path: String,
        scope: DirectHermesWorkspaceFileScope
    ) throws {
        guard (try? scope.require(path)) != nil else {
            throw DirectHermesError.invalidResponse
        }
    }

    private static func validate(fileName: String) throws {
        guard !fileName.isEmpty, fileName.utf8.count <= 255,
              fileName != ".", fileName != "..",
              !fileName.contains("/"), !fileName.contains("\\"),
              !fileName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !fileName.unicodeScalars.contains(where: {
                  (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
              }) else {
            throw DirectHermesError.invalidResponse
        }
    }

    private static func validate(mimeType: String) throws {
        guard !mimeType.isEmpty, mimeType.utf8.count <= 120, mimeType.contains("/"),
              mimeType.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || "!#$&^_.+-/".contains($0))
              }) else {
            throw DirectHermesError.invalidResponse
        }
    }

    static func stageUpload(
        sourceURL: URL,
        expectedByteCount: Int,
        path: String,
        scope: DirectHermesWorkspaceFileScope,
        fileName: String,
        mimeType: String,
        overwrite: Bool
    ) async throws -> DirectHermesManagedFileStagedUpload {
        try validate(path: path, scope: scope)
        try validate(fileName: fileName)
        try validate(mimeType: mimeType)
        guard expectedByteCount > 0, expectedByteCount <= maximumTransferBytes else {
            throw DirectHermesError.messageTooLarge
        }
        let boundary = try multipartBoundary(excluding: [
            Data(path.utf8),
            Data(fileName.utf8),
            Data(mimeType.utf8),
        ])
        let encodedFileName = percentEncodedHeaderValue(fileName)
        let prefix = Data((
            "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"file\"; filename=\"\(encodedFileName)\"\r\n"
                + "Content-Type: \(mimeType)\r\n\r\n"
        ).utf8)
        let suffix = Data((
            "\r\n--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"path\"\r\n\r\n"
                + path
                + "\r\n--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"overwrite\"\r\n\r\n"
                + (overwrite ? "true" : "false")
                + "\r\n--\(boundary)--\r\n"
        ).utf8)
        let overhead = prefix.count.addingReportingOverflow(suffix.count)
        guard !overhead.overflow, overhead.partialValue <= maximumMultipartOverheadBytes else {
            throw DirectHermesError.messageTooLarge
        }

        return try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let folder = fileManager.temporaryDirectory
                .appending(path: "LoopdyManagedFileUploads", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            do {
                try fileManager.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true,
                    attributes: [
                        .protectionKey: FileProtectionType.completeUnlessOpen,
                        .posixPermissions: 0o700,
                    ]
                )
                var privateFolder = folder
                var folderValues = URLResourceValues()
                folderValues.isExcludedFromBackup = true
                try privateFolder.setResourceValues(folderValues)

                let bodyURL = folder.appending(path: "multipart-body", directoryHint: .notDirectory)
                guard fileManager.createFile(
                    atPath: bodyURL.path,
                    contents: nil,
                    attributes: [
                        .protectionKey: FileProtectionType.completeUnlessOpen,
                        .posixPermissions: 0o600,
                    ]
                ) else {
                    throw DirectHermesError.invalidResponse
                }

                let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                let sourceBefore = try sourceURL.resourceValues(forKeys: keys)
                guard sourceBefore.isRegularFile == true,
                      sourceBefore.isSymbolicLink != true,
                      sourceBefore.fileSize == expectedByteCount else {
                    throw DirectHermesError.invalidResponse
                }

                let input = try FileHandle(forReadingFrom: sourceURL)
                let output = try FileHandle(forWritingTo: bodyURL)
                defer {
                    try? input.close()
                    try? output.close()
                }
                try output.write(contentsOf: prefix)
                var payloadByteCount = 0
                var hasher = SHA256()
                var boundaryTail = Data()
                let boundaryBytes = Data(boundary.utf8)
                while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    let next = payloadByteCount.addingReportingOverflow(chunk.count)
                    guard !next.overflow, next.partialValue <= expectedByteCount else {
                        throw DirectHermesError.invalidResponse
                    }
                    var boundaryWindow = boundaryTail
                    boundaryWindow.append(chunk)
                    guard boundaryWindow.range(of: boundaryBytes) == nil else {
                        throw DirectHermesError.invalidResponse
                    }
                    boundaryTail = Data(boundaryWindow.suffix(max(0, boundaryBytes.count - 1)))
                    try output.write(contentsOf: chunk)
                    hasher.update(data: chunk)
                    payloadByteCount = next.partialValue
                    try Task.checkCancellation()
                }
                guard payloadByteCount == expectedByteCount else {
                    throw DirectHermesError.invalidResponse
                }
                try output.write(contentsOf: suffix)
                try output.synchronize()

                let sourceAfter = try sourceURL.resourceValues(forKeys: keys)
                guard sourceAfter.isRegularFile == true,
                      sourceAfter.isSymbolicLink != true,
                      sourceAfter.fileSize == expectedByteCount else {
                    throw DirectHermesError.invalidResponse
                }
                let bodyByteCount = prefix.count + payloadByteCount + suffix.count
                let bodyValues = try bodyURL.resourceValues(forKeys: keys)
                guard bodyValues.isRegularFile == true,
                      bodyValues.isSymbolicLink != true,
                      bodyValues.fileSize == bodyByteCount,
                      bodyByteCount <= maximumTransferBytes + maximumMultipartOverheadBytes else {
                    throw DirectHermesError.messageTooLarge
                }
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                return DirectHermesManagedFileStagedUpload(
                    bodyURL: bodyURL,
                    folderURL: folder,
                    boundary: boundary,
                    bodyByteCount: bodyByteCount,
                    payloadByteCount: payloadByteCount,
                    payloadSHA256: digest
                )
            } catch {
                try? fileManager.removeItem(at: folder)
                throw error
            }
        }.value
    }

    private static func validate(staged: DirectHermesManagedFileStagedUpload) throws {
        let values = try staged.bodyURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard staged.payloadByteCount > 0,
              staged.payloadByteCount <= maximumTransferBytes,
              staged.bodyByteCount >= staged.payloadByteCount,
              staged.bodyByteCount <= staged.payloadByteCount + maximumMultipartOverheadBytes,
              staged.bodyURL.deletingLastPathComponent().standardizedFileURL
                == staged.folderURL.standardizedFileURL,
              staged.boundary.hasPrefix("Loopdy-"),
              let boundaryID = UUID(uuidString: String(staged.boundary.dropFirst("Loopdy-".count))),
              staged.boundary == "Loopdy-" + boundaryID.uuidString,
              staged.payloadSHA256.utf8.count == 64,
              staged.payloadSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == staged.bodyByteCount else {
            throw DirectHermesError.invalidResponse
        }
    }

    private static func percentEncodedHeaderValue(_ value: String) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte)
                || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) {
                return String(decoding: [byte], as: UTF8.self)
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    private static func multipartBoundary(excluding values: [Data]) throws -> String {
        for _ in 0..<8 {
            let candidate = "Loopdy-\(UUID().uuidString)"
            let bytes = Data(candidate.utf8)
            if values.allSatisfy({ $0.range(of: bytes) == nil }) { return candidate }
        }
        throw DirectHermesError.invalidResponse
    }

    private static func boundedHeader(
        _ name: String,
        in response: HTTPURLResponse,
        maximumBytes: Int
    ) throws -> String? {
        guard let value = response.value(forHTTPHeaderField: name) else { return nil }
        guard value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DirectHermesError.invalidResponse
        }
        return value
    }
}

extension DirectHermesHTTP {
    /// Uses this instance's ephemeral URLSession and redirect/TLS delegate. The
    /// only widened bodies and responses are fixed managed-file operations.
    func sendManagedFile(
        _ operation: DirectHermesManagedFileTransportRequest,
        bearer: String?,
        legacyToken: String?,
        willDispatch: @MainActor () throws -> Void,
        didReceiveStatus: @MainActor (Int) -> Void
    ) async throws -> Response {
        try Task.checkCancellation()
        let prepared = try DirectHermesManagedFileTransport.prepare(operation)
        guard (bearer != nil) != (legacyToken != nil) else {
            throw DirectHermesError.unsupportedAuthentication
        }
        var components = URLComponents(
            url: try endpoint.url(for: prepared.route),
            resolvingAgainstBaseURL: false
        )!
        if !prepared.query.isEmpty { components.queryItems = prepared.query }
        guard let url = components.url else { throw DirectHermesError.invalidEndpoint }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = prepared.method
        request.httpShouldHandleCookies = false
        request.setValue(prepared.accept, forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let bearer {
            try DirectHermesSecretValidation.validate(bearer)
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        if let legacyToken {
            try DirectHermesSecretValidation.validate(legacyToken)
            request.setValue(legacyToken, forHTTPHeaderField: "X-Hermes-Session-Token")
        }
        if case .streamRange(_, _, let range, _) = operation {
            request.setValue(
                "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                forHTTPHeaderField: "Range"
            )
        }
        if let contentType = prepared.contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let bodyFileURL = prepared.bodyFileURL {
            guard let bodyByteCount = prepared.bodyByteCount, bodyByteCount > 0 else {
                throw DirectHermesError.invalidResponse
            }
            request.setValue(String(bodyByteCount), forHTTPHeaderField: "Content-Length")
            guard case .bytes(let maximumResponseBytes) = prepared.responseBody else {
                throw DirectHermesError.invalidResponse
            }
            // Authentication, file validation, fixed request construction, and
            // owner validation all finish before the upload task can send bytes.
            try willDispatch()
            do {
                let (body, http) = try await sendManagedFileUpload(
                    request: request,
                    fromFile: bodyFileURL,
                    successMaximumBytes: maximumResponseBytes,
                    failureMaximumBytes: DirectHermesManagedFileTransport.maximumMutationResponseBytes
                )
                guard http.url == url else { throw DirectHermesError.redirectRefused }
                didReceiveStatus(http.statusCode)
                if (300...399).contains(http.statusCode) {
                    throw DirectHermesError.redirectRefused
                }
                try Task.checkCancellation()
                return .init(http: http, body: body)
            } catch let failure as DirectHermesSessionDelegate.BoundedFileUploadFailure {
                if let response = failure.response, response.url == url {
                    didReceiveStatus(response.statusCode)
                }
                throw Self.safeError(failure.underlying)
            } catch {
                throw Self.safeError(error)
            }
        } else if prepared.bodyByteCount != nil {
            throw DirectHermesError.invalidResponse
        }

        try willDispatch()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url else {
                bytes.task.cancel()
                throw DirectHermesError.redirectRefused
            }
            didReceiveStatus(http.statusCode)
            if (300...399).contains(http.statusCode) {
                bytes.task.cancel()
                throw DirectHermesError.redirectRefused
            }
            let body: Data
            if !(200...299).contains(http.statusCode) {
                if http.expectedContentLength > Int64(DirectHermesManagedFileTransport.maximumMutationResponseBytes) {
                    bytes.task.cancel()
                    throw DirectHermesError.messageTooLarge
                }
                body = try await Self.collectBody(
                    bytes,
                    maximumBytes: DirectHermesManagedFileTransport.maximumMutationResponseBytes
                )
            } else {
                switch prepared.responseBody {
                case .bytes(let maximumBytes):
                    if http.expectedContentLength > Int64(maximumBytes) {
                        bytes.task.cancel()
                        throw DirectHermesError.messageTooLarge
                    }
                    body = try await Self.collectBody(bytes, maximumBytes: maximumBytes)
                case .none:
                    body = try await Self.collectBody(bytes, maximumBytes: 0)
                case .sha256(let expectedByteCount, let maximumBytes):
                    guard http.expectedContentLength < 0
                        || http.expectedContentLength == Int64(expectedByteCount) else {
                        bytes.task.cancel()
                        throw DirectHermesError.invalidResponse
                    }
                    body = try await Self.collectSHA256(
                        bytes,
                        expectedByteCount: expectedByteCount,
                        maximumBytes: maximumBytes
                    )
                }
            }
            try Task.checkCancellation()
            return .init(http: http, body: body)
        } catch {
            throw Self.safeError(error)
        }
    }

    nonisolated private static func collectSHA256(
        _ bytes: URLSession.AsyncBytes,
        expectedByteCount: Int,
        maximumBytes: Int
    ) async throws -> Data {
        guard expectedByteCount > 0, expectedByteCount <= maximumBytes else {
            bytes.task.cancel()
            throw DirectHermesError.messageTooLarge
        }
        var hasher = SHA256()
        var chunk = Data()
        chunk.reserveCapacity(64 * 1_024)
        var count = 0
        for try await byte in bytes {
            guard count < expectedByteCount, count < maximumBytes else {
                bytes.task.cancel()
                throw DirectHermesError.invalidResponse
            }
            chunk.append(byte)
            count += 1
            if chunk.count == 64 * 1_024 {
                hasher.update(data: chunk)
                chunk.removeAll(keepingCapacity: true)
                try Task.checkCancellation()
            }
        }
        if !chunk.isEmpty { hasher.update(data: chunk) }
        guard count == expectedByteCount else { throw DirectHermesError.invalidResponse }
        return Data(hasher.finalize())
    }
}

extension DirectHermesClient {
    func downloadManagedFile(
        path: String,
        scope: DirectHermesWorkspaceFileScope,
        maximumBytes: Int
    ) async throws -> DirectHermesManagedFileBinaryResponse {
        let response = try await managedFileTransportResponse(
            .download(path: path, scope: scope, maximumBytes: maximumBytes)
        )
        return try DirectHermesManagedFileTransport.response(from: response)
    }

    func headManagedMedia(
        path: String,
        scope: DirectHermesWorkspaceFileScope
    ) async throws -> DirectHermesManagedFileBinaryResponse {
        let response = try await managedFileTransportResponse(.streamHead(path: path, scope: scope))
        let typed = try DirectHermesManagedFileTransport.response(from: response)
        guard typed.bytes.isEmpty else { throw DirectHermesError.invalidResponse }
        return typed
    }

    func streamManagedMedia(
        path: String,
        scope: DirectHermesWorkspaceFileScope,
        range: Range<Int>,
        maximumBytes: Int
    ) async throws -> DirectHermesManagedFileBinaryResponse {
        let response = try await managedFileTransportResponse(
            .streamRange(path: path, scope: scope, range: range, maximumBytes: maximumBytes)
        )
        return try DirectHermesManagedFileTransport.response(from: response)
    }

    func uploadManagedFile(
        path: String,
        scope: DirectHermesWorkspaceFileScope,
        fileName: String,
        mimeType: String,
        localFile: URL,
        byteCount: Int,
        overwrite: Bool,
        maximumResponseBytes: Int,
        requireOriginalOwner: @escaping @MainActor () throws -> Void
    ) async throws -> DirectHermesManagedFileUploadResponse {
        let staged = try await DirectHermesManagedFileTransport.stageUpload(
            sourceURL: localFile,
            expectedByteCount: byteCount,
            path: path,
            scope: scope,
            fileName: fileName,
            mimeType: mimeType,
            overwrite: overwrite
        )
        defer { staged.remove() }

        let response: DirectHermesHTTP.Response
        do {
            response = try await managedFileTransportResponse(
                .upload(
                    path: path,
                    scope: scope,
                    fileName: fileName,
                    mimeType: mimeType,
                    staged: staged,
                    overwrite: overwrite,
                    maximumResponseBytes: maximumResponseBytes
                ),
                requireOriginalOwner: requireOriginalOwner
            )
        } catch WorkspaceClientError.outcomeUnknown {
            throw DirectHermesManagedFileUploadError.outcomeUnknown(
                byteCount: staged.payloadByteCount,
                sha256: staged.payloadSHA256
            )
        }
        do {
            let typed = try DirectHermesManagedFileTransport.response(from: response)
            try DirectHermesManagedFileTransport.requireJSON(typed)
            return .init(
                acknowledgement: try response.value(),
                byteCount: staged.payloadByteCount,
                sha256: staged.payloadSHA256
            )
        } catch {
            // A successful HTTP status with malformed or incomplete receipt data
            // cannot prove the multipart mutation failed. The caller reconciles
            // through the authoritative listing and streamed digest readback.
            throw DirectHermesManagedFileUploadError.outcomeUnknown(
                byteCount: staged.payloadByteCount,
                sha256: staged.payloadSHA256
            )
        }
    }

    func verifyManagedFile(
        path: String,
        scope: DirectHermesWorkspaceFileScope,
        expectedByteCount: Int,
        maximumBytes: Int
    ) async throws -> DirectHermesManagedFileReadback {
        let response = try await managedFileTransportResponse(.verifyDownload(
            path: path,
            scope: scope,
            expectedByteCount: expectedByteCount,
            maximumBytes: maximumBytes
        ))
        return try DirectHermesManagedFileTransport.readback(
            from: response,
            expectedByteCount: expectedByteCount
        )
    }
}
