import Foundation

/// A bounded, partial-success result for the Artifacts tree only. Files keeps its
/// strict directory decoder; Artifacts can retain verified siblings while naming
/// branches that could not be indexed.
struct WorkspaceArtifactIndex: Equatable, Sendable {
    let files: [WorkspaceFileListing.Entry]
    let diagnostics: [WorkspaceArtifactScanDiagnostic]
}

struct WorkspaceArtifactDirectoryInspection: Equatable, Sendable {
    let listing: WorkspaceFileListing
    let diagnostics: [WorkspaceArtifactScanDiagnostic]
}

struct WorkspaceArtifactScanDiagnostic: Equatable, Hashable, Sendable {
    enum Kind: String, Equatable, Hashable, Sendable {
        case outsideWorkspace
        case unsupportedEntry
        case unavailableBranch
        case enumerationLimit
        case diagnosticLimit
    }

    let kind: Kind
    /// Always the already-validated in-scope directory being listed. An escaping
    /// resolved target is never surfaced as a path the user could try to open.
    let path: String
    let entryName: String?

    static func outsideWorkspace(directory: String, entryName: String?) -> Self {
        .init(kind: .outsideWorkspace, path: directory, entryName: entryName)
    }

    static func unsupportedEntry(directory: String, entryName: String?) -> Self {
        .init(kind: .unsupportedEntry, path: directory, entryName: entryName)
    }

    static func unavailableBranch(_ path: String) -> Self {
        .init(kind: .unavailableBranch, path: path, entryName: nil)
    }

    static func enumerationLimit(_ path: String) -> Self {
        .init(kind: .enumerationLimit, path: path, entryName: nil)
    }

    static func diagnosticLimit(_ path: String) -> Self {
        .init(kind: .diagnosticLimit, path: path, entryName: nil)
    }

    var message: String {
        switch kind {
        case .outsideWorkspace:
            if let entryName {
                return "Skipped \(entryName) in \(path) because Hermes resolved it outside this configured workspace."
            }
            return "Skipped an entry in \(path) because Hermes resolved it outside this configured workspace."
        case .unsupportedEntry:
            if let entryName {
                return "Skipped unsupported entry \(entryName) in \(path)."
            }
            return "Skipped an unsupported entry in \(path)."
        case .unavailableBranch:
            return "Could not list \(path); verified files from other folders remain available."
        case .enumerationLimit:
            return "Stopped the scan at the bounded Artifacts index limit near \(path)."
        case .diagnosticLimit:
            return "Additional skipped entries were omitted from these bounded scan notes for \(path)."
        }
    }
}

@MainActor
enum WorkspaceArtifactTreeEnumerator {
    /// Bounds total accepted rows across the tree, not merely each host response.
    /// This retains the existing 50,000-row decoder ceiling as a whole-index cap.
    static let maximumAcceptedEntries = WorkspaceManagementDecoder.maximumFileRows
    /// Only used when the host can't answer `files.recent` (plugin before
    /// 2.15). A real workspace can hold over a million files, so the scan
    /// stays shallow and small, skips tooling folders, and shows files as it goes.
    static let maximumListedDirectories = 300
    static let maximumDepth = 3
    static let maximumPublishedDiagnostics = 100
    static let progressInterval = 20
    private static let skippedDirectoryNames: Set<String> = [
        "node_modules", "bower_components", "Pods", "Carthage", "DerivedData", "SourcePackages",
        "build", "dist", "target", "vendor", "venv", "env", "__pycache__", "site-packages",
        "coverage", "xcuserdata",
    ]
    private static let skippedDirectorySuffixes = [
        ".xcodeproj", ".xcworkspace", ".xcassets", ".xcarchive", ".xcresult", ".app", ".framework",
        ".xcframework", ".bundle", ".dSYM", ".photoslibrary", ".lproj",
    ]

    static func skipsDirectory(named name: String) -> Bool {
        name.hasPrefix(".") || skippedDirectoryNames.contains(name)
            || skippedDirectorySuffixes.contains { name.hasSuffix($0) }
    }

    /// One request for what the agent made or changed lately (plugin 2.15+),
    /// in the host's order: newest first.
    static func loadRecent(
        scope: DirectHermesWorkspaceFileScope,
        owner: WorkspaceOwner,
        performer: any WorkspaceOperationPerforming
    ) async throws -> WorkspaceArtifactIndex {
        let payload = try await performer.perform(.filesRecent, payload: [:], owner: owner)
        let inspection = try scope.artifactEnumerationDirectory(payload, expectedPath: scope.root)
        return .init(files: inspection.listing.entries.filter { !$0.isDirectory },
                     diagnostics: inspection.diagnostics)
    }

    static func load(
        scope: DirectHermesWorkspaceFileScope,
        owner: WorkspaceOwner,
        performer: any WorkspaceOperationPerforming,
        canContinue: @MainActor () -> Bool,
        onProgress: (@MainActor ([WorkspaceFileListing.Entry]) -> Void)? = nil
    ) async throws -> WorkspaceArtifactIndex {
        var directories = [scope.root]
        var visited = Set<String>()
        var discovered: [String: WorkspaceFileListing.Entry] = [:]
        var diagnostics: [WorkspaceArtifactScanDiagnostic] = []
        var acceptedEntryCount = 0
        var index = 0
        var reachedLimit = false
        var diagnosticsWereTruncated = false

        func appendDiagnostic(_ diagnostic: WorkspaceArtifactScanDiagnostic) {
            guard !diagnostics.contains(diagnostic) else { return }
            if diagnostics.count < maximumPublishedDiagnostics {
                diagnostics.append(diagnostic)
            } else {
                diagnosticsWereTruncated = true
            }
        }

        while index < directories.count {
            try Task.checkCancellation()
            guard canContinue() else { throw CancellationError() }
            guard visited.count < maximumListedDirectories,
                  acceptedEntryCount < maximumAcceptedEntries else {
                reachedLimit = true
                break
            }

            let path = directories[index]
            index += 1
            guard visited.insert(path).inserted else { continue }
            if let onProgress, visited.count % progressInterval == 0, !discovered.isEmpty {
                onProgress(discovered.values.sorted(by: newestAvailableFirst))
            }

            let inspection: WorkspaceArtifactDirectoryInspection
            do {
                let payload = try await performer.perform(
                    .filesList,
                    payload: ["path": .string(path)],
                    owner: owner
                )
                guard canContinue() else { throw CancellationError() }
                inspection = try scope.artifactEnumerationDirectory(payload, expectedPath: path)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard canContinue() else { throw CancellationError() }
                if mustAbort(for: error) || DirectHermesWorkspaceFileScope.samePath(path, scope.root) {
                    throw error
                }
                appendDiagnostic(.unavailableBranch(path))
                continue
            }

            for diagnostic in inspection.diagnostics {
                appendDiagnostic(diagnostic)
            }
            for entry in inspection.listing.entries {
                guard acceptedEntryCount < maximumAcceptedEntries else {
                    reachedLimit = true
                    break
                }
                acceptedEntryCount += 1
                if entry.isDirectory {
                    if !visited.contains(entry.path), !skipsDirectory(named: entry.name),
                       depth(of: entry.path, root: scope.root) <= maximumDepth {
                        guard directories.count < maximumListedDirectories else {
                            reachedLimit = true
                            break
                        }
                        directories.append(entry.path)
                    }
                } else if !entry.name.hasPrefix("."), discovered[entry.id] == nil {
                    discovered[entry.id] = entry
                }
            }
            if reachedLimit { break }
        }

        if reachedLimit {
            let boundary = index < directories.count ? directories[index] : directories.last ?? scope.root
            let limitDiagnostic = WorkspaceArtifactScanDiagnostic.enumerationLimit(boundary)
            if diagnostics.count < maximumPublishedDiagnostics {
                appendDiagnostic(limitDiagnostic)
            } else if diagnostics.count >= 2 {
                diagnostics[diagnostics.count - 2] = limitDiagnostic
                diagnosticsWereTruncated = true
            }
        }
        if diagnosticsWereTruncated, !diagnostics.isEmpty {
            diagnostics[diagnostics.count - 1] = .diagnosticLimit(scope.root)
        }

        return .init(
            files: discovered.values.sorted(by: newestAvailableFirst),
            diagnostics: diagnostics
        )
    }

    private static func depth(of path: String, root: String) -> Int {
        guard path.count > root.count else { return 0 }
        return path.dropFirst(root.count).split(whereSeparator: { $0 == "/" || $0 == "\\" }).count
    }

    static func mustAbort(for error: any Error) -> Bool {
        if let error = error as? DirectHermesManagedFilesError {
            return error == .scopeChanged || error == .ownerChanged || error == .scopeUnavailable
        }
        if let error = error as? WorkspaceClientError {
            return error == .ownerChanged || error == .authenticationRequired
        }
        if let error = error as? WorkspaceManagementError {
            return error == .staleOwner
        }
        return false
    }

    private static func newestAvailableFirst(
        _ lhs: WorkspaceFileListing.Entry,
        _ rhs: WorkspaceFileListing.Entry
    ) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.path < rhs.path
        }
    }
}
