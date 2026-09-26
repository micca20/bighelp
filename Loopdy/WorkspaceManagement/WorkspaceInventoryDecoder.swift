import Foundation

enum WorkspaceInventoryDecoder {
    typealias D = WorkspaceManagementDecoder
    typealias Object = [String: LoopdyJSONValue]

    static func bool(_ row: Object, _ key: String) throws -> Bool {
        guard let value = row[key]?.boolean else { throw WorkspaceManagementError.invalidResponse }
        return value
    }

    static func number(_ value: LoopdyJSONValue?) throws -> Double? {
        guard let value, value != .null else { return nil }
        guard let number = value.number, number.isFinite, number >= 0 else {
            throw WorkspaceManagementError.invalidResponse
        }
        return number
    }

    static func countText(_ value: LoopdyJSONValue?) throws -> String {
        guard let value = try number(value) else { return "Not reported" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    static func plugins(_ payload: Object) throws -> [WorkspaceInventoryItem] {
        try D.unique(D.rows(payload["plugins"]).map {
            let row = try D.object($0)
            return try .init(
                id: D.text(row["key"], maximum: 256),
                title: D.text(row["name"], maximum: 200),
                summary: D.text(row["description"], maximum: 8_192, empty: true),
                status: D.text(row["status"], maximum: 128),
                details: [
                    .init(label: "Version", value: D.text(row["version"], maximum: 128, empty: true)),
                    .init(label: "Source", value: D.text(row["source"], maximum: 128))
                ]
            )
        })
    }

    static func toolsets(_ payload: Object) throws -> [WorkspaceInventoryItem] {
        try D.unique(D.rows(payload["toolsets"]).map {
            let row = try D.object($0)
            let tools = try D.rows(row["tools"]).map { try D.text($0, maximum: 256) }
            let enabled = try bool(row, "enabled")
            let configured = try bool(row, "configured")
            return try .init(
                id: D.text(row["name"], maximum: 256),
                title: D.text(row["label"], maximum: 200),
                summary: D.text(row["description"], maximum: 8_192, empty: true),
                status: enabled ? "Enabled" : "Disabled",
                details: [
                    .init(label: "Setup", value: configured ? "Configured" : "Configuration required"),
                    .init(label: "Platform", value: D.text(row["platform_label"], maximum: 200)),
                    .init(label: "Tools", value: tools.isEmpty ? "None listed" : tools.joined(separator: ", "))
                ]
            )
        })
    }

    static func mcp(_ payload: Object) throws -> [WorkspaceInventoryItem] {
        try D.unique(D.rows(payload["servers"]).map {
            let row = try D.object($0)
            let enabled = try bool(row, "enabled")
            let environment = try D.rows(row["env"]).map { try D.text($0, maximum: 128) }
            return try .init(
                id: D.text(row["name"], maximum: 200),
                title: D.text(row["name"], maximum: 200),
                summary: "Connection managed by Hermes",
                status: enabled ? "Enabled in configuration" : "Disabled",
                details: [
                    .init(label: "Transport", value: D.text(row["transport"], maximum: 32)),
                    .init(label: "Environment variables", value: environment.count.formatted()),
                    .init(label: "Runtime connection", value: "Not checked by this inventory")
                ]
            )
        })
    }

    static func messaging(_ payload: Object) throws -> [WorkspaceInventoryItem] {
        try D.unique(D.rows(payload["platforms"], maximum: 100).map {
            let row = try D.object($0)
            return try .init(
                id: D.text(row["id"], maximum: 128),
                title: D.text(row["name"], maximum: 200),
                summary: D.text(row["description"], maximum: 8_192, empty: true),
                status: D.text(row["state"], maximum: 128),
                details: [
                    .init(label: "Enabled", value: bool(row, "enabled") ? "Yes" : "No"),
                    .init(label: "Configured", value: bool(row, "configured") ? "Yes" : "No"),
                    .init(label: "Gateway running", value: bool(row, "gateway_running") ? "Yes" : "No")
                ]
            )
        })
    }

    static func memory(_ payload: Object) throws -> [WorkspaceInventoryItem] {
        let active = try D.text(payload["active"], maximum: 128, empty: true)
        guard let files = payload["builtin_files"]?.object else { throw WorkspaceManagementError.invalidResponse }
        var result = [WorkspaceInventoryItem(
            id: "builtin", title: "Built-in memory",
            summary: "Memory contents stay on Hermes. This API reports storage, not editable documents.",
            status: active.isEmpty || active == "built-in" ? "Selected" : nil,
            details: [
                .init(label: "Memory bytes", value: try countText(files["memory"])),
                .init(label: "User context bytes", value: try countText(files["user"]))
            ]
        )]
        result += try D.rows(payload["providers"], maximum: 100).map {
            let row = try D.object($0)
            let name = try D.text(row["name"], maximum: 128)
            return try .init(
                id: "provider:\(name)", title: name,
                summary: D.text(row["description"], maximum: 8_192, empty: true),
                status: D.text(row["status"], maximum: 128),
                details: [
                    .init(label: "Selected", value: active == name ? "Yes" : "No"),
                    .init(label: "Configured", value: bool(row, "configured") ? "Yes" : "No")
                ]
            )
        }
        return try D.unique(result)
    }

    static func usage(_ payload: Object) throws -> [WorkspaceInventoryItem] {
        guard payload["period_days"]?.integer == 30, let totals = payload["totals"]?.object else {
            throw WorkspaceManagementError.invalidResponse
        }
        let fields = [
            ("Input tokens", "total_input"), ("Output tokens", "total_output"),
            ("Cache-read tokens", "total_cache_read"), ("Reasoning tokens", "total_reasoning"),
            ("Sessions", "total_sessions"), ("API calls", "total_api_calls"),
            ("Estimated cost (USD)", "total_estimated_cost"), ("Actual cost (USD)", "total_actual_cost")
        ]
        var result = [WorkspaceInventoryItem(
            id: "totals", title: "Last 30 days", summary: "Sessions started in this period. Not a ledger of only calls made during these days.",
            status: nil, details: try fields.map { .init(label: $0.0, value: try countText(totals[$0.1])) }
        )]
        result += try D.rows(payload["by_model"]).enumerated().map { index, value in
            let row = try D.object(value)
            return try .init(
                id: "model:\(index)", title: D.text(row["model"], maximum: 256),
                summary: "Includes host-reported model accounting; auxiliary work may be included.",
                status: nil, details: [
                    .init(label: "Input tokens", value: countText(row["input_tokens"])),
                    .init(label: "Output tokens", value: countText(row["output_tokens"])),
                    .init(label: "Estimated cost (USD)", value: countText(row["estimated_cost"]))
                ]
            )
        }
        return result
    }

    static func keys(_ payload: Object) throws -> [WorkspaceCredentialStatus] {
        guard payload.count <= 500 else { throw WorkspaceManagementError.invalidResponse }
        return try payload.keys.sorted().map { key in
            guard validKey(key), let value = payload[key] else { throw WorkspaceManagementError.invalidResponse }
            let row = try D.object(value)
            return try .init(
                id: key,
                description: D.text(row["description"], maximum: 8_192, empty: true),
                category: D.text(row["category"], maximum: 128, empty: true),
                isSet: bool(row, "is_set"),
                canReplace: bool(row, "is_password") && !bool(row, "channel_managed")
            )
        }
    }

    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 128
            && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            && key.first?.isNumber == false
    }

    static func webhooks(_ payload: Object) throws -> [WorkspaceWebhook] {
        try D.unique(D.rows(payload["subscriptions"]).map {
            let row = try D.object($0)
            return try .init(
                id: D.text(row["name"], maximum: 128),
                description: D.text(row["description"], maximum: 8_192, empty: true),
                events: D.rows(row["events"], maximum: 100).map { try D.text($0, maximum: 128) },
                isEnabled: bool(row, "enabled"),
                hasSecret: bool(row, "secret_set")
            )
        })
    }

    static func system(_ payload: Object) throws -> [WorkspaceInventoryItem] {
        let fields = [
            ("Hermes", "hermes_version"), ("Operating system", "os"),
            ("OS release", "os_release"), ("Architecture", "arch"), ("Python", "python_version")
        ]
        let details = try fields.map { label, key in
            WorkspaceInventoryItem.Detail(label: label, value: try D.text(payload[key], maximum: 256))
        }
        return [.init(id: "system", title: "Host system", summary: "Read-only host information. No update, restart or process-control operation is performed.", status: nil, details: details)]
    }
}
