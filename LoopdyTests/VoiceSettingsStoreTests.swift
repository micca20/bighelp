import Foundation
import Testing
@testable import Loopdy

@MainActor
struct VoiceSettingsStoreTests {
    @Test func loadsCurrentHostConfigurationWithoutReadingBackTheSecret() async {
        let client = VoiceSettingsProbe()
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        #expect(store.providerID == "openai")
        #expect(store.voiceID == "alloy")
        #expect(store.configuration?.providers.first?.apiKeyConfigured == true)
        #expect(store.apiKey.isEmpty)
        #expect(!store.canSave)
    }

    @Test func savesProviderVoiceAndReplacementKeyOnlyAfterHostConfirmation() async {
        let client = VoiceSettingsProbe()
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.selectProvider("elevenlabs")
        store.voiceID = "fixture-voice-id"
        store.apiKey = "fixture-provider-key"
        #expect(store.canSave)
        await store.save()
        #expect(client.updates == [VoiceSettingsUpdate(expectedRevision: "revision-1",
            providerID: "elevenlabs", voiceID: "fixture-voice-id", apiKey: "fixture-provider-key")])
        #expect(store.configuration?.revision == "revision-2")
        #expect(store.providerID == "elevenlabs")
        #expect(store.apiKey.isEmpty)
        #expect(store.confirmation == "Voice settings saved.")
        #expect(!store.canSave)
    }

    @Test func unchangedSettingsAndSameProviderDoNotWriteOrConfirm() async {
        let client = VoiceSettingsProbe()
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.selectProvider("openai")
        await store.save()
        #expect(client.updates.isEmpty)
        #expect(store.confirmation == nil)
    }

    @Test func switchingProvidersClearsTheOtherProvidersUnsentKey() async {
        let store = VoiceSettingsStore(agentID: "finance", client: VoiceSettingsProbe())
        await store.load()
        store.apiKey = "unsent-openai-key"
        store.selectProvider("elevenlabs")
        #expect(store.apiKey.isEmpty)
        #expect(store.voiceID == "")
    }

    @Test func failedSaveKeepsEditsAndDoesNotClaimSuccess() async {
        let client = VoiceSettingsProbe()
        client.saveError = VoiceSettingsError.conflict
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.voiceID = "nova"
        await store.save()
        #expect(store.configuration?.revision == "revision-1")
        #expect(store.voiceID == "nova")
        #expect(store.confirmation == nil)
        #expect(store.errorMessage != nil)
    }
    @Test func lateLoadAndSaveCannotPublishAfterHostOwnershipChanges() async {
        let client = VoiceSettingsProbe()
        client.holdLoad = true
        let owner = VoiceSettingsOwner()
        let store = VoiceSettingsStore(agentID: "finance", client: client, isCurrent: { owner.current })
        let loading = Task { await store.load() }
        while client.pendingLoad == nil { await Task.yield() }
        owner.current = false
        client.pendingLoad?.resume(returning: client.configuration)
        await loading.value
        #expect(store.configuration == nil)
        #expect(store.errorMessage == nil)

        owner.current = true
        client.holdLoad = false
        await store.load()
        store.voiceID = "nova"
        client.holdSave = true
        let saving = Task { await store.save() }
        while client.pendingSave == nil { await Task.yield() }
        owner.current = false
        store.invalidate()
        client.pendingSave?.resume()
        await saving.value
        #expect(store.configuration == nil)
        #expect(store.confirmation == nil)
        #expect(store.apiKey.isEmpty)
    }

    @Test func doubleSaveIsIgnoredAndLateSuccessPreservesNewerEdits() async {
        let client = VoiceSettingsProbe()
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.voiceID = "nova"
        client.holdSave = true
        let saving = Task { await store.save() }
        while client.pendingSave == nil { await Task.yield() }
        await store.save()
        store.voiceID = "coral"
        client.pendingSave?.resume()
        await saving.value
        #expect(client.updates.count == 1)
        #expect(store.configuration?.providers.first?.voiceID == "nova")
        #expect(store.voiceID == "coral")
        #expect(store.confirmation == nil)
        #expect(store.canSave)
    }

    @Test func clearingASecretForBackgroundPrivacyDoesNotLoseSaveConfirmation() async {
        let client = VoiceSettingsProbe()
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.apiKey = "fixture-replacement-key"
        client.holdSave = true
        let saving = Task { await store.save() }
        while client.pendingSave == nil { await Task.yield() }
        store.clearAPIKey()
        #expect(store.apiKey.isEmpty)
        client.pendingSave?.resume()
        await saving.value
        #expect(store.confirmation == "Voice settings saved.")
        #expect(!store.canSave)
    }

    @Test func changingOnlyVoiceDoesNotTransmitAKeyReplacement() async {
        let client = VoiceSettingsProbe()
        let store = VoiceSettingsStore(agentID: "finance", client: client)
        await store.load()
        store.voiceID = "nova"
        await store.save()
        #expect(client.updates.first?.apiKey == nil)
        #expect(store.selectedProvider?.apiKeyConfigured == true)
    }

}

@MainActor
private final class VoiceSettingsProbe: VoiceSettingsClient {
    var updates: [VoiceSettingsUpdate] = []
    var saveError: (any Error)?
    var holdLoad = false
    var holdSave = false
    var pendingLoad: CheckedContinuation<VoiceSettingsConfiguration, Never>?
    var pendingSave: CheckedContinuation<Void, Never>?
    var configuration = VoiceSettingsConfiguration(revision: "revision-1", providerID: "openai",
        providers: [.init(id: "openai", title: "OpenAI", voiceID: "alloy", apiKeyConfigured: true),
                    .init(id: "elevenlabs", title: "ElevenLabs", voiceID: "", apiKeyConfigured: false)])

    func load(agentID: String) async throws -> VoiceSettingsConfiguration {
        if holdLoad { return await withCheckedContinuation { pendingLoad = $0 } }
        return configuration
    }
    func update(agentID: String, settings: VoiceSettingsUpdate) async throws -> VoiceSettingsConfiguration {
        updates.append(settings)
        if holdSave { await withCheckedContinuation { pendingSave = $0 } }
        if let saveError { throw saveError }
        configuration = VoiceSettingsConfiguration(revision: "revision-2", providerID: settings.providerID,
            providers: configuration.providers.map { provider in
                provider.id == settings.providerID
                    ? VoiceProviderConfiguration(id: provider.id, title: provider.title,
                        voiceID: settings.voiceID, apiKeyConfigured: settings.apiKey != nil || provider.apiKeyConfigured)
                    : provider
            })
        return configuration
    }
}

@MainActor private final class VoiceSettingsOwner { var current = true }
