import Foundation

/// Bounded host inventories and reviewed update admission.
extension DirectHermesHostOperationsClient {
    func overview(profileID: String? = nil) async throws -> HermesHostOverview {
        let query = try profileID.map {
            [URLQueryItem(name: "profile", value: try DirectHermesHostPayload.profile($0))]
        } ?? []
        let object = try DirectHermesHostPayload.object(try await json(
            .init(path: "/api/status", method: .get, query: query, maximumResponseBytes: 256 * 1_024),
            feature: "host status"
        ))
        let componentObject = try DirectHermesHostPayload.object(object["components"] ?? .object([:]))
        guard componentObject.count <= 128 else { throw HostOperationsError.invalidResponse }
        let components = try componentObject.map { key, value -> HermesHostOverview.Component in
            let row = try DirectHermesHostPayload.object(value)
            return .init(
                id: try DirectHermesHostPayload.safeIdentifier(key, maximumBytes: 128),
                status: try DirectHermesHostPayload.text(row["status"], maximumBytes: 128)
            )
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }

        return .init(
            version: try DirectHermesHostPayload.text(object["version"], maximumBytes: 128),
            releaseDate: try DirectHermesHostPayload.optionalText(object["release_date"], maximumBytes: 128),
            gatewayRunning: try DirectHermesHostPayload.boolean(object["gateway_running"]),
            gatewayState: try DirectHermesHostPayload.text(object["gateway_state"], maximumBytes: 128),
            gatewayBusy: try DirectHermesHostPayload.boolean(object["gateway_busy"]),
            gatewayDrainable: try DirectHermesHostPayload.boolean(object["gateway_drainable"]),
            gatewayMode: try DirectHermesHostPayload.text(object["gateway_mode"], maximumBytes: 64),
            gatewaySharedWith: try DirectHermesHostPayload.strings(object["gateway_shared_with"], maximum: 128, maximumBytes: 128),
            activeAgents: try DirectHermesHostPayload.integer(object["active_agents"], range: 0...1_000_000),
            activeSessions: try DirectHermesHostPayload.integer(object["active_sessions"], range: 0...1_000_000),
            restartDrainTimeout: try DirectHermesHostPayload.number(object["restart_drain_timeout"], range: 0...86_400),
            overall: try DirectHermesHostPayload.text(object["overall"], maximumBytes: 64),
            components: components
        )
    }

    func systemStats() async throws -> HermesSystemStats {
        let object = try DirectHermesHostPayload.object(try await json(
            .init(path: "/api/system/stats", method: .get, maximumResponseBytes: 128 * 1_024),
            feature: "system statistics"
        ))
        return .init(
            operatingSystem: try DirectHermesHostPayload.text(object["os"], maximumBytes: 128),
            operatingSystemRelease: try DirectHermesHostPayload.optionalText(object["os_release"], maximumBytes: 256),
            architecture: try DirectHermesHostPayload.text(object["arch"], maximumBytes: 128),
            hostname: try DirectHermesHostPayload.text(object["hostname"], maximumBytes: 512),
            pythonVersion: try DirectHermesHostPayload.text(object["python_version"], maximumBytes: 128),
            pythonImplementation: try DirectHermesHostPayload.optionalText(object["python_impl"], maximumBytes: 128),
            hermesVersion: try DirectHermesHostPayload.text(object["hermes_version"], maximumBytes: 128),
            cpuCount: try DirectHermesHostPayload.optionalInteger(object["cpu_count"], range: 1...65_536),
            cpuPercent: try DirectHermesHostPayload.optionalNumber(object["cpu_percent"], range: 0...1_000_000),
            loadAverage: try DirectHermesHostPayload.numbers(object["load_avg"], maximum: 3, range: 0...1_000_000),
            uptimeSeconds: try DirectHermesHostPayload.optionalInteger(object["uptime_seconds"], range: 0...Int.max),
            memory: try DirectHermesHostPayload.capacity(object["memory"], availableKey: "available"),
            disk: try DirectHermesHostPayload.capacity(object["disk"], availableKey: "free"),
            process: try DirectHermesHostPayload.process(object["process"]),
            hasExtendedMetrics: try DirectHermesHostPayload.boolean(object["psutil"])
        )
    }

    func egressStatus() async throws -> HermesEgressStatus {
        let object = try DirectHermesHostPayload.object(try await json(
            .init(path: "/api/egress/status", method: .get, maximumResponseBytes: 64 * 1_024),
            feature: "egress status"
        ))
        return .init(text: try DirectHermesHostPayload.text(object["text"], maximumBytes: 48 * 1_024))
    }

    func checkForUpdate(force: Bool = false) async throws -> HermesUpdateCheck {
        let object = try DirectHermesHostPayload.object(try await json(
            .init(
                path: "/api/hermes/update/check", method: .get,
                query: [.init(name: "force", value: force ? "true" : "false")],
                maximumResponseBytes: 256 * 1_024
            ),
            feature: "Hermes update checks"
        ))
        let rows = try DirectHermesHostPayload.array(object["commits"] ?? .array([]), maximum: 200)
        let commits = try rows.map { value -> HermesUpdateCheck.Commit in
            let row = try DirectHermesHostPayload.object(value)
            return .init(
                sha: try DirectHermesHostPayload.sha(row["sha"]),
                summary: try DirectHermesHostPayload.text(row["summary"], maximumBytes: 2_048),
                occurredAt: DirectHermesHostPayload.date(
                    try DirectHermesHostPayload.optionalInteger(row["at"], range: 0...Int.max)
                )
            )
        }
        return .init(
            installMethod: try DirectHermesHostPayload.text(object["install_method"], maximumBytes: 64),
            currentVersion: try DirectHermesHostPayload.text(object["current_version"], maximumBytes: 128),
            commitsBehind: try DirectHermesHostPayload.optionalInteger(object["behind"], range: -1...1_000_000),
            updateAvailable: try DirectHermesHostPayload.boolean(object["update_available"]),
            canApply: try DirectHermesHostPayload.boolean(object["can_apply"]),
            updateCommand: try DirectHermesHostPayload.text(object["update_command"], maximumBytes: 1_024),
            message: try DirectHermesHostPayload.optionalText(object["message"], maximumBytes: 4_096),
            commits: commits
        )
    }

    func latestUpdateReceipt() async throws -> HermesUpdateReceipt? {
        let request = DirectHermesHTTPRequest(
            path: "/api/hermes/update/receipt", method: .get,
            maximumResponseBytes: 512 * 1_024
        )
        let value: BighelpJSONValue
        if let raw = http as? any DirectHermesNativeHTTP {
            try requireOwner()
            let response = try await raw.nativeResponse(request, requestGuard: nil)
            try requireOwner()
            if response.http.statusCode == 404 {
                let responseObject = try? response.object()
                if responseObject?["detail"]?.string?.hasPrefix("No update receipt found") == true {
                    return nil
                }
                throw HostOperationsError.unavailable("structured update receipts")
            }
            guard (200...299).contains(response.http.statusCode) else {
                if response.http.statusCode == 405 {
                    throw HostOperationsError.unavailable("structured update receipts")
                }
                throw HostOperationsError.invalidResponse
            }
            value = try response.value()
        } else {
            value = try await json(request, feature: "structured update receipts")
        }
        return try DirectHermesHostPayload.updateReceipt(value)
    }

    func launchUpdate(reviewed check: HermesUpdateCheck) async throws -> HermesHostActionReceipt {
        guard check.updateAvailable, check.canApply else { throw HostOperationsError.invalidRequest }
        let current = try await checkForUpdate()
        guard current.installMethod == check.installMethod,
              current.currentVersion == check.currentVersion,
              current.updateAvailable, current.canApply else {
            throw HostOperationsError.reviewChanged
        }
        return try await launch(
            .init(path: "/api/hermes/update", method: .post, body: [:]),
            expectedAction: .hermesUpdate,
            feature: "in-place Hermes updates"
        )
    }

    func checkpoints() async throws -> HermesCheckpointSnapshot {
        let object = try DirectHermesHostPayload.object(try await json(
            .init(path: "/api/ops/checkpoints", method: .get, maximumResponseBytes: 256 * 1_024),
            feature: "checkpoint inventory"
        ))
        let rows = try DirectHermesHostPayload.array(object["sessions"], maximum: 5_000)
        var seen = Set<Data>()
        let sessions = try rows.map { value -> HermesCheckpointSnapshot.Session in
            let row = try DirectHermesHostPayload.object(value)
            let session = try DirectHermesHostPayload.text(row["session"], maximumBytes: 512)
            guard seen.insert(Data(session.utf8)).inserted else { throw HostOperationsError.invalidResponse }
            return .init(
                id: session,
                fileCount: try DirectHermesHostPayload.integer(row["files"], range: 0...Int.max),
                bytes: try DirectHermesHostPayload.integer(row["bytes"], range: 0...Int.max)
            )
        }
        return .init(
            sessions: sessions,
            totalBytes: try DirectHermesHostPayload.integer(object["total_bytes"], range: 0...Int.max)
        )
    }

    func launchBackup() async throws -> HermesHostActionReceipt {
        try await launch(
            .init(path: "/api/ops/backup", method: .post, body: ["output": .null]),
            expectedAction: .backup,
            feature: "host backups"
        )
    }

    func launchCheckpointPrune() async throws -> HermesHostActionReceipt {
        try await launch(
            .init(path: "/api/ops/checkpoints/prune", method: .post, body: [:]),
            expectedAction: .checkpointsPrune,
            feature: "checkpoint pruning"
        )
    }
}
