import Foundation

/// Fixed inputs for the only native multipart import route. Callers cannot
/// provide a URL, HTTP method, header, credential, or multipart field name.
struct DirectHermesHostImportUploadRequest: Sendable {
    let filename: String
    let bytes: Data
    let force: Bool
    let maximumResponseBytes: Int
}

enum DirectHermesHostImportTransportBoundary {
    static let maximumArchiveBytes = 16 * 1_024 * 1_024
    static let maximumMultipartOverheadBytes = 16 * 1_024
    static let maximumResponseBytes = 256 * 1_024

    struct PreparedRequest: Sendable {
        let boundary: String
        let body: Data
        let maximumResponseBytes: Int
    }

    static func validate(_ request: DirectHermesHostImportUploadRequest) throws {
        try validateFilename(request.filename)
        guard request.force else { throw DirectHermesError.invalidResponse }
        guard !request.bytes.isEmpty,
              request.bytes.count <= maximumArchiveBytes,
              (1...maximumResponseBytes).contains(request.maximumResponseBytes) else {
            throw DirectHermesError.messageTooLarge
        }
        guard hasZIPSignature(request.bytes) else { throw DirectHermesError.invalidResponse }
    }

    static func prepare(_ request: DirectHermesHostImportUploadRequest) throws -> PreparedRequest {
        try validate(request)
        let boundary = try multipartBoundary(excluding: [
            request.bytes,
            Data(request.filename.utf8),
            Data("true".utf8),
        ])
        let encodedFilename = percentEncodedHeaderValue(request.filename)
        let prefix = Data((
            "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"file\"; "
                + "filename=\"\(encodedFilename)\"; filename*=UTF-8''\(encodedFilename)\r\n"
                + "Content-Type: application/zip\r\n\r\n"
        ).utf8)
        let suffix = Data((
            "\r\n--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"force\"\r\n\r\n"
                + "true"
                + "\r\n--\(boundary)--\r\n"
        ).utf8)
        let overhead = prefix.count.addingReportingOverflow(suffix.count)
        guard !overhead.overflow,
              overhead.partialValue <= maximumMultipartOverheadBytes else {
            throw DirectHermesError.messageTooLarge
        }
        let bodyCount = request.bytes.count.addingReportingOverflow(overhead.partialValue)
        guard !bodyCount.overflow,
              bodyCount.partialValue <= maximumArchiveBytes + maximumMultipartOverheadBytes else {
            throw DirectHermesError.messageTooLarge
        }

        var body = Data()
        body.reserveCapacity(bodyCount.partialValue)
        body.append(prefix)
        body.append(request.bytes)
        body.append(suffix)
        guard body.count == bodyCount.partialValue else {
            throw DirectHermesError.invalidResponse
        }
        return .init(
            boundary: boundary,
            body: body,
            maximumResponseBytes: request.maximumResponseBytes
        )
    }

    static func requireJSON(_ response: HTTPURLResponse) throws {
        guard let raw = response.value(forHTTPHeaderField: "Content-Type"),
              raw.utf8.count <= 256,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              raw.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "application/json" else {
            throw DirectHermesError.invalidResponse
        }
    }

    /// These statuses prove that the import route rejected this invocation.
    /// Every other failure after dispatch remains uncertain and must not retry.
    static func isDefinitiveRejection(_ statusCode: Int?) -> Bool {
        guard let statusCode else { return false }
        return [400, 401, 403, 404, 405, 409, 413, 415, 422, 429].contains(statusCode)
    }

    private static func validateFilename(_ filename: String) throws {
        guard !filename.isEmpty,
              filename.utf8.count <= 255,
              filename.lowercased().hasSuffix(".zip"),
              filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DirectHermesError.invalidResponse
        }
    }

    private static func hasZIPSignature(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        switch Array(data.prefix(4)) {
        case [0x50, 0x4b, 0x03, 0x04],
             [0x50, 0x4b, 0x05, 0x06],
             [0x50, 0x4b, 0x07, 0x08]:
            return true
        default:
            return false
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
            let candidate = "Loopdy-Host-Import-\(UUID().uuidString)"
            let bytes = Data(candidate.utf8)
            if values.allSatisfy({ $0.range(of: bytes) == nil }) { return candidate }
        }
        throw DirectHermesError.invalidResponse
    }
}

extension DirectHermesHTTP {
    /// Reuses the retained ephemeral session and its redirect/TLS delegate. The
    /// route, method, headers, fields, and request-size exception are all fixed.
    func sendHostImportUpload(
        _ operation: DirectHermesHostImportUploadRequest,
        bearer: String?,
        legacyToken: String?,
        willDispatch: @MainActor () throws -> Void,
        didReceiveStatus: @MainActor (Int) -> Void
    ) async throws -> Response {
        try Task.checkCancellation()
        let prepared = try DirectHermesHostImportTransportBoundary.prepare(operation)
        guard (bearer != nil) != (legacyToken != nil) else {
            throw DirectHermesError.unsupportedAuthentication
        }
        let url = try endpoint.url(for: "/api/ops/import-upload")
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(
            "multipart/form-data; boundary=\(prepared.boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(String(prepared.body.count), forHTTPHeaderField: "Content-Length")
        if let bearer {
            try DirectHermesSecretValidation.validate(bearer)
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        if let legacyToken {
            try DirectHermesSecretValidation.validate(legacyToken)
            request.setValue(legacyToken, forHTTPHeaderField: "X-Hermes-Session-Token")
        }
        request.httpBody = prepared.body

        // All validation and authentication work completed before this point.
        // Once session.bytes starts, the archive may have left the process.
        // Keep this outside safeError mapping so pre-dispatch ownership loss is
        // distinguishable from a request whose bytes may have left the process.
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
            guard http.expectedContentLength <= Int64(prepared.maximumResponseBytes) else {
                bytes.task.cancel()
                throw DirectHermesError.messageTooLarge
            }
            let body = try await Self.collectBody(
                bytes,
                maximumBytes: prepared.maximumResponseBytes
            )
            try Task.checkCancellation()
            return .init(http: http, body: body)
        } catch {
            throw Self.safeError(error)
        }
    }
}

extension DirectHermesClient: DirectHermesHostImportUploadHTTP {
    func uploadHermesBackupForImport(
        filename: String,
        bytes: Data,
        force: Bool,
        maximumResponseBytes: Int
    ) async throws -> LoopdyJSONValue {
        let operation = DirectHermesHostImportUploadRequest(
            filename: filename,
            bytes: bytes,
            force: force,
            maximumResponseBytes: maximumResponseBytes
        )
        try DirectHermesHostImportTransportBoundary.validate(operation)
        let response = try await hostImportUploadTransportResponse(operation)
        do {
            try DirectHermesHostImportTransportBoundary.requireJSON(response.http)
            return try response.value()
        } catch {
            // A 2xx response means the host may already have admitted the import.
            // Malformed or incomplete acknowledgement is never retry authority.
            throw WorkspaceClientError.outcomeUnknown
        }
    }
}
