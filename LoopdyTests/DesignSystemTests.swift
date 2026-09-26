import Photos
import SwiftUI
import Testing
import UIKit
@testable import Loopdy

@MainActor
struct DesignSystemTests {
    @Test func newChatTabUsesTheRequiredVisibleAndAccessibilityLabels() {
        #expect(FloatingTabBar.newChatVisibleLabel == "New chat")
        #expect(FloatingTabBar.newChatAccessibilityLabel == "New chat")
    }

    @Test func primaryNavigationUsesRegularUntintedGlassOrSemanticAccessibilityFallbacks() {
        #expect(FloatingTabBar.backgroundSurface(supportsLiquidGlass: true,
            reduceTransparency: false, increasedContrast: false) == .regularLiquidGlass)
        #expect(FloatingTabBar.backgroundSurface(supportsLiquidGlass: true,
            reduceTransparency: false, increasedContrast: true) == .regularLiquidGlass)
        #expect(FloatingTabBar.backgroundSurface(supportsLiquidGlass: false,
            reduceTransparency: false, increasedContrast: false) == .regularMaterial)
        #expect(FloatingTabBar.backgroundSurface(supportsLiquidGlass: false,
            reduceTransparency: false, increasedContrast: true) == .thickMaterial)
        for supportsGlass in [false, true] {
            #expect(FloatingTabBar.backgroundSurface(supportsLiquidGlass: supportsGlass,
                reduceTransparency: true, increasedContrast: true) == .opaque)
        }
    }

    @Test func primaryNavigationRowMeasuresFiniteUniformCellsForEveryLayoutProposal() {
        let items = [CGSize(width: 44, height: 56), CGSize(width: 60, height: 56),
                     CGSize(width: 58, height: 56), CGSize(width: 54, height: 56),
                     CGSize(width: 46, height: 56)]
        let proposals: [CGFloat?] = [nil, 0, 200, .infinity]
        for width in proposals {
            #expect(NavigationRowLayout.fittingSize(proposedWidth: width, itemSizes: items)
                == CGSize(width: 300, height: 56))
        }
        #expect(NavigationRowLayout.fittingSize(proposedWidth: 620, itemSizes: items)
            == CGSize(width: 620, height: 56))
    }

    @Test func rootNavigationDoesNotDuplicatePushedDestinationBars() {
        #expect(FloatingTabBar.isRootBarVisible(for: []))
        #expect(!FloatingTabBar.isRootBarVisible(for: [.chat(conversationID: "current")]))
    }

    @Test func expandedNavigationRowsRespectTheWidthReservedBesideNewChat() {
        let items = [CGSize(width: 160, height: 180), CGSize(width: 200, height: 180)]
        let viewports: [CGFloat] = [320, 375, 402, 430, 620]
        for viewport in viewports {
            let rowWidth = viewport - 24 - 60 - 8 - 12
            let fitted = NavigationRowLayout.fittingSize(
                proposedWidth: rowWidth, itemSizes: items, constrainsWidth: true
            )
            #expect(fitted.width == rowWidth)
            #expect(fitted.width / 2 >= 44)
            #expect(fitted.height == 180)
        }
        #expect(NavigationRowLayout.fittingSize(
            proposedWidth: 20, itemSizes: items, constrainsWidth: true
        ).width == 88)
    }

    @Test func workspaceHeaderUsesCompactLayoutBeforeControlsCanOverlap() {
        #expect(WorkspaceHeaderLayout.mode(for: 320) == .compact)
        #expect(WorkspaceHeaderLayout.mode(for: 390) == .compact)
        #expect(WorkspaceHeaderLayout.mode(for: 430) == .regular)
    }

    @Test func sessionControlsUseAvailableHeightResponsively() {
        #expect(
            ChatSessionControlsPresentation.preferredHeight(isVerticallyCompact: true)
                < ChatSessionControlsPresentation.preferredHeight(isVerticallyCompact: false)
        )
        #expect(ChatSessionControlsPresentation.preferredHeight(isVerticallyCompact: true) == 320)
        #expect(ChatSessionControlsPresentation.preferredHeight(isVerticallyCompact: false) == 560)
    }

    @Test func agentAttachmentActionsExposeExactlyOneSaveForAValidatedDestination() {
        #expect(ChatAttachmentActionPolicy.actions(for: .photosImage) == [.preview, .save])
        #expect(ChatAttachmentActionPolicy.actions(for: .photosVideo) == [.preview, .save])
        #expect(ChatAttachmentActionPolicy.actions(for: .files) == [.preview, .save])
        #expect(ChatAttachmentActionPolicy.actions(for: .unavailable(.invalidVideo)) == [.preview])
    }

    @Test func attachmentSaveDestinationsUseNativeAppleActionNames() {
        #expect(ChatAttachmentSaveDestination.photosImage.accessibilityLabel == "Save Image")
        #expect(ChatAttachmentSaveDestination.photosVideo.accessibilityLabel == "Save Video")
        #expect(ChatAttachmentSaveDestination.files.accessibilityLabel == "Save to Files")
    }

    @Test func attachmentSaveGateRejectsConcurrentTapsUntilTheOperationFinishes() {
        var activity = ChatAttachmentSaveActivity()
        let firstBegan = activity.begin()
        #expect(firstBegan)
        #expect(activity.isBusy)
        let secondBegan = activity.begin()
        #expect(!secondBegan)
        activity.finish()
        let thirdBegan = activity.begin()
        #expect(thirdBegan)
    }

    @MainActor
    @Test func realImagePayloadRoutesOnlyToPhotosAndSpoofedImageIsUnavailable() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let pngData = renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let image = try ChatAttachment(
            id: "validated_image_attachment_0001",
            fileName: "sample.png",
            mimeType: "image/png",
            data: pngData
        )
        let spoofed = try ChatAttachment(
            id: "spoofed_image_attachment_0001",
            fileName: "sample.png",
            mimeType: "image/png",
            data: Data("not an image".utf8)
        )

        #expect(await ChatAttachmentMediaValidator.destination(for: image) == .photosImage)
        #expect(await ChatAttachmentMediaValidator.destination(for: spoofed) == .unavailable(.invalidImage))
    }

    @MainActor
    @Test func documentRoutesOnlyToFilesAndInvalidVideoNeverFallsBackToPhoto() async throws {
        let document = try ChatAttachment(
            id: "document_attachment_fixture_0001",
            fileName: "notes.txt",
            mimeType: "text/plain",
            data: Data("hello".utf8)
        )
        let invalidVideo = try ChatAttachment(
            id: "invalid_video_attachment_0001",
            fileName: "clip.mp4",
            mimeType: "video/mp4",
            data: Data("not a video or photo".utf8)
        )

        #expect(await ChatAttachmentMediaValidator.destination(for: document) == .files)
        #expect(
            await ChatAttachmentMediaValidator.destination(for: invalidVideo)
                == .unavailable(.invalidVideo)
        )
    }

    @MainActor
    @Test func dedicatedVideoResourceLivesThroughImportThenIsRemoved() async throws {
        let validator = AcceptingVideoValidator()
        let writer = RecordingPhotoLibraryWriter()

        try await ChatAttachmentPhotosSaver.saveVideo(
            data: Data("test video resource".utf8),
            fileName: "clip.mp4",
            videoValidator: validator,
            writer: writer
        )

        let observedURL = try #require(writer.observedVideoURL)
        #expect(writer.videoExistedDuringImport)
        #expect(!FileManager.default.fileExists(atPath: observedURL.path))
        #expect(writer.imageWriteCount == 0)
    }

    @Test func photoLibraryWriterContractDoesNotHopToMainActor() async throws {
        let writer = ExecutorRecordingPhotoLibraryWriter()
        let contract: any ChatAttachmentPhotoLibraryWriting = writer

        try await Task.detached {
            try await contract.addImage(Data([1]))
        }.value

        #expect(!writer.imageCallWasOnMainThread)
    }

    @Test func deniedAndRestrictedPhotosAuthorizationOfferSettingsRecovery() {
        #expect(ChatAttachmentPhotosAuthorizationRecovery.requiresSettings(.denied))
        #expect(ChatAttachmentPhotosAuthorizationRecovery.requiresSettings(.restricted))
        #expect(!ChatAttachmentPhotosAuthorizationRecovery.requiresSettings(.authorized))
    }

    @Test func chatHeaderSharesOneVerticalCenterAxisAcrossLayoutsAndContentHeights() {
        let policy = ChatView.HeaderControlAlignmentPolicy.sharedCenterAxis
        let layouts: [(rowHeight: CGFloat, controlHeights: [CGFloat])] = [
            (48, [48, 44, 48]),
            (72, [48, 72, 48]),
            (96, [48, 96, 48]),
        ]

        for layout in layouts {
            let centers = layout.controlHeights.map {
                policy.controlCenterY(rowHeight: layout.rowHeight, controlHeight: $0)
            }
            #expect(centers.allSatisfy { $0 == layout.rowHeight / 2 })
        }
    }

    @Test func liquidGlassChatHeaderPresentsOnlyCurrentActivityAsTransparentShimmeringText() throws {
        let presentation = try #require(ChatHeaderLiveActivityPresentation.resolve(
            phrase: "  Burning the draft…  ",
            isActive: true
        ))

        #expect(presentation.text == "Burning the draft…")
        #expect(presentation.lineLimit == 1)
        #expect(presentation.maximumWidth == 240)
        #expect(presentation.shimmers)
        #expect(!presentation.usesOwnSurface)
        #expect(LoopdyActiveCallShimmerPolicy.isAnimated(isActive: true, reduceMotion: false))
        #expect(!LoopdyActiveCallShimmerPolicy.isAnimated(isActive: true, reduceMotion: true))
        #expect(ChatHeaderLiveActivityPresentation.resolve(phrase: "Old turn", isActive: false) == nil)
        #expect(ChatHeaderLiveActivityPresentation.resolve(phrase: "   ", isActive: true) == nil)
        #expect(ChatHeaderLiveActivityPresentation.resolve(phrase: nil, isActive: true) == nil)
    }

    @Test func compactChatHeaderKeepsSessionAndActionsOnOneTopRow() {
        #expect(WorkspaceHeaderLayout.compactControlPlacement == .singleRow)
    }

    @Test func compactChatHeaderCentersThePickerAndSeparatesTrailingActions() {
        #expect(WorkspaceHeaderLayout.compactCentersSessionControl)
        #expect(WorkspaceHeaderLayout.compactSessionControlMaximumWidth == 160)
        #expect(WorkspaceHeaderLayout.compactSessionControlWidth(isBotMode: false) == 160)
        #expect(WorkspaceHeaderLayout.compactSessionControlWidth(isBotMode: true) == 136)
        #expect(WorkspaceHeaderLayout.compactTrailingActionSpacing == 12)
        #expect(WorkspaceHeaderLayout.headerTopPadding < WorkspaceHeaderLayout.headerBottomPadding)
        #expect(ChatSessionControlsPresentation.choiceAlignment == .center)
        #expect(ChatSessionControlsPresentation.choicesFillAvailableWidth)
        #expect(ChatSessionControlsPresentation.quickChoiceCentersTextIndependentlyOfAccessories)
        #expect(ChatSessionControlsPresentation.quickChoiceAccessoryWidth == 40)
        #expect(ChatSessionControlsPresentation.compactChipCentersModelIndependentlyOfProviderMark)
        #expect(!ChatSessionControlsPresentation.showsCompactChipDisclosureIndicator)
        #expect(ChatSessionControlsPresentation.compactChipAccessoryWidth == 24)
        #expect(LoopdyPickerSheetLayout.centersProviderHeaders)
        #expect(LoopdyPickerSheetLayout.centersModelRows)
        #expect(LoopdyPickerSheetLayout.centersReasoningRows)
    }

    @Test func providerMarksGrowAcrossEveryPickerAndActionDrawerSurfaceAtRegularWidth() {
        let expected: [(AIProviderMarkContext, CGFloat, CGFloat)] = [
            (.agentRuntimeSelection, 40, 48),
            (.modelPickerProviderHeader, 44, 52),
            (.chatSessionCompactControl, 24, 32),
            (.chatQuickChoice, 40, 48),
            (.chatLegacyModelRow, 40, 48),
            (.chatLegacyProviderHeader, 32, 40),
            (.chatActionMenuProviderHeader, 36, 44),
        ]

        for (context, compactSize, regularSize) in expected {
            #expect(AIProviderMarkLayout.size(for: context, isRegularWidth: false) == compactSize)
            #expect(AIProviderMarkLayout.size(for: context, isRegularWidth: true) == regularSize)
            #expect(regularSize > compactSize)
        }
        #expect(AIProviderMarkLayout.centersMarksVertically)
    }

    @Test func modelPickerDarkSurfaceAndApplyButtonUseExplicitContrastStates() {
        #expect(
            LoopdyPickerSheetSurfacePresentation.resolve(isDarkMode: false)
                == .init(base: .clear, opacity: 0)
        )
        #expect(
            LoopdyPickerSheetSurfacePresentation.resolve(isDarkMode: true)
                == .init(base: .canvas, opacity: 0.72)
        )
        #expect(
            ChatSessionControlsPresentation.surfacePresentation(isDarkMode: true)
                == .init(base: .canvas, opacity: 0.72)
        )
        #expect(!LoopdyPickerSheetSurfacePresentation.usesColoredOutline)
        #expect(LoopdyModelPickerApplyPresentation.disabledBackgroundOpacity(isDarkMode: false) == 0.10)
        #expect(LoopdyModelPickerApplyPresentation.disabledBackgroundOpacity(isDarkMode: true) == 0.28)

        #expect(
            LoopdyModelPickerApplyPresentation.resolve(
                hasChanges: false,
                isApplying: false
            ) == .init(
                state: .disabled,
                background: .disabledGray,
                foreground: .secondaryText,
                isInteractive: false
            )
        )
        #expect(
            LoopdyModelPickerApplyPresentation.resolve(
                hasChanges: true,
                isApplying: false
            ) == .init(
                state: .enabled,
                background: .action,
                foreground: .actionForeground,
                isInteractive: true
            )
        )
        #expect(
            LoopdyModelPickerApplyPresentation.resolve(
                hasChanges: true,
                isApplying: true
            ).state == .applying
        )
    }

    @Test func modelPickerDismissUsesNeutralGlassWithoutThemeDecoration() {
        #expect(LoopdyPickerSheetLayout.dismissButtonStyle == .neutralGlass)

        let presentation = LoopdyIconButtonPresentation.resolve(
            LoopdyPickerSheetLayout.dismissButtonStyle
        )
        #expect(presentation.surfaceRole == .circularControl)
        #expect(presentation.foreground == .primaryText)
        #expect(!presentation.usesThemedIconWell)
        #expect(!presentation.usesAccentTint)
    }

    @Test func partnerThemesUseStrictMonochromeLogosWhileLoopdyKeepsItsBrandMark() {
        for themeID in [LoopdyThemeID.nous, .superpilot] {
            #expect(
                LoopdyLogoPresentation.resolve(themeID: themeID, colorScheme: .light)
                    == .init(
                        mark: .fixedHex("000000"),
                        wordmark: .fixedHex("000000"),
                        usesReflectiveMaterial: false
                    )
            )
            #expect(
                LoopdyLogoPresentation.resolve(themeID: themeID, colorScheme: .dark)
                    == .init(
                        mark: .fixedHex("FFFFFF"),
                        wordmark: .fixedHex("FFFFFF"),
                        usesReflectiveMaterial: false
                    )
            )
        }

        for colorScheme in [ColorScheme.light, .dark] {
            #expect(
                LoopdyLogoPresentation.resolve(themeID: .loopdy, colorScheme: colorScheme)
                    == .init(
                        mark: .assetOriginal,
                        wordmark: .themePrimaryText,
                        usesReflectiveMaterial: true
                    )
            )
        }
    }

    @Test func messageBubblesKeepTheirSurfaceOnPhoneAndIPad() throws {
        let theme = LoopdyTheme.resolve(appearance: .light, colorScheme: .light, contrast: .standard)
        for (role, sizeClass, paintsSurface) in [
            (TimelineRole.assistant, UserInterfaceSizeClass.regular, true),
            (.assistant, .compact, true),
            (.human, .regular, true),
        ] {
            let renderer = ImageRenderer(content:
                Color.clear.frame(width: 100, height: 30)
                    .modifier(LoopdyV3MessageSurface(role: role, theme: theme, increasedContrast: false))
                    .environment(\.horizontalSizeClass, sizeClass)
            )
            let image = try #require(renderer.cgImage)
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try #require(CGContext(data: &pixel, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            #expect((pixel[3] > 0) == paintsSurface)
        }
    }

    @Test func animatedLoopdyMarkRunsOnlyForVisibleActiveWorkWhenMotionIsAllowed() {
        #expect(LoopdyAnimatedMarkPolicy.shouldAnimate(
            isActive: true,
            reduceMotion: false,
            sceneIsActive: true,
            isVisible: true
        ))
        #expect(!LoopdyAnimatedMarkPolicy.shouldAnimate(
            isActive: false,
            reduceMotion: false,
            sceneIsActive: true,
            isVisible: true
        ))
        #expect(!LoopdyAnimatedMarkPolicy.shouldAnimate(
            isActive: true,
            reduceMotion: true,
            sceneIsActive: true,
            isVisible: true
        ))
        #expect(!LoopdyAnimatedMarkPolicy.shouldAnimate(
            isActive: true,
            reduceMotion: false,
            sceneIsActive: false,
            isVisible: true
        ))
        #expect(!LoopdyAnimatedMarkPolicy.shouldAnimate(
            isActive: true,
            reduceMotion: false,
            sceneIsActive: true,
            isVisible: false
        ))
    }

    @Test func customThemeNormalizesValidatedFieldsIntoEverySemanticThemeRole() throws {
        let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let originalBuiltIns = LoopdyThemeRegistry.builtIns

        let custom = try CustomTheme(
            id: id,
            name: "  Studio Blue  ",
            font: .serif,
            accentHex: "#3366cc",
            light: CustomThemePalette(
                backgroundHex: "#ffffff",
                primaryTextHex: "111111",
                secondaryTextHex: "333333",
                tertiaryTextHex: "555555"
            ),
            dark: CustomThemePalette(
                backgroundHex: "101010",
                primaryTextHex: "ffffff",
                secondaryTextHex: "e0e0e0",
                tertiaryTextHex: "b0b0b0"
            )
        )

        #expect(custom.name == "Studio Blue")
        #expect(custom.accentHex == "3366CC")
        #expect(custom.light.backgroundHex == "FFFFFF")
        #expect(custom.dark.primaryTextHex == "FFFFFF")
        #expect(custom.themeID.rawValue == "custom.11111111-2222-3333-4444-555555555555")

        let definition = custom.definition
        #expect(definition.id == custom.themeID)
        #expect(definition.name == "Studio Blue")
        #expect(definition.light.typeface == .serif)
        #expect(definition.dark.typeface == .serif)
        #expect(definition.light.canvasHex == "FFFFFF")
        #expect(definition.dark.canvasHex == "101010")
        #expect(definition.light.primaryTextHex == "111111")
        #expect(definition.light.secondaryTextHex == "333333")
        #expect(definition.light.tertiaryTextHex == "555555")
        #expect(definition.dark.primaryTextHex == "FFFFFF")
        #expect(definition.dark.secondaryTextHex == "E0E0E0")
        #expect(definition.dark.tertiaryTextHex == "B0B0B0")
        #expect(definition.light.actionHex == "3366CC")
        #expect(definition.dark.actionHex == "3366CC")
        #expect(LoopdyThemeRegistry.builtIns == originalBuiltIns)
    }

    @Test func conversationBubblesRetainPartnerAndCustomPalettes() throws {
        let custom = try validCustomTheme()
        let themes = [LoopdyTheme.nousLight, .nousDark, .superpilotLight,
                      .superpilotDark, custom.definition.light, custom.definition.dark]
        for theme in themes {
            let outgoing = LoopdyV3MessageSurface(
                role: .human,
                theme: theme,
                increasedContrast: false
            ).fillColor
            for style: UIUserInterfaceStyle in [.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: style)
                let previewColor = UIColor(outgoing).resolvedColor(with: traits)
                let shippingColor = UIColor(theme.outgoingMessageBackground).resolvedColor(with: traits)
                #expect(previewColor.isEqual(shippingColor))
            }
            // Saved palettes remain portable, but incoming chrome is the warm Ember neutral in every theme.
            #expect(LoopdyV3MessageSurface(role: .assistant, theme: theme, increasedContrast: true).fillColor == theme.incomingMessageBackground)
        }
    }

    @Test func customThemeDefinitionFlowsThroughAppearanceContext() throws {
        let custom = try validCustomTheme()
        let context = LoopdyAppearanceContext(
            appearance: .dark,
            themeID: custom.themeID,
            customTheme: custom
        )
        let resolved = LoopdyTheme.resolve(
            appearance: context,
            colorScheme: .light,
            contrast: .standard
        )
        #expect(resolved.themeID == custom.themeID)
        // The default dark page (Graphite), not the custom theme's document colors.
        #expect(resolved.canvasHex == LoopdyTheme.graphiteDark.canvasHex)
        #expect(resolved.typeface == .system)
        #expect(custom.definition.dark.canvasHex == custom.dark.backgroundHex)
        #expect(custom.accentHex == "3366CC")
        #expect(resolved.action != LoopdyTheme.resolve(themeID: .loopdy, appearance: .dark,
                                                      colorScheme: .dark, contrast: .standard).action)
    }

    @Test func customThemesOfferExactlyFiveCuratedDynamicTypeFontChoices() throws {
        #expect(CustomThemeFontChoice.allCases == [
            .system,
            .rounded,
            .serif,
            .monospaced,
            .notoSans,
        ])
        #expect(CustomThemeFontChoice.allCases.map(\.title) == [
            "System",
            "Rounded",
            "Serif",
            "Monospaced",
            "Noto Sans",
        ])

        let regularTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let accessibilityTraits = UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        let themes = try CustomThemeFontChoice.allCases.map { choice in
            try validCustomTheme(font: choice).definition.light
        }

        #expect(themes.map(\.typeface) == [
            .system,
            .rounded,
            .serif,
            .monospaced,
            .system,
        ])
        #expect(themes.last?.typography.bodyFontNames.first == "Noto Sans")
        for theme in themes {
            #expect(
                theme.uiFont(.body, compatibleWith: accessibilityTraits).pointSize
                    > theme.uiFont(.body, compatibleWith: regularTraits).pointSize
            )
        }
    }

    @Test func customThemeRejectsInvalidNamesColorsAndUnreadableSemanticText() throws {
        #expect(throws: CustomThemeValidationError.invalidName) {
            try validCustomTheme(name: " \n ")
        }
        #expect(throws: CustomThemeValidationError.invalidColor(.accent)) {
            try validCustomTheme(accentHex: "not-a-color")
        }
        #expect(throws: CustomThemeValidationError.insufficientContrast(.lightSecondaryText)) {
            try validCustomTheme(light: CustomThemePalette(
                backgroundHex: "FFFFFF",
                primaryTextHex: "111111",
                secondaryTextHex: "F0F0F0",
                tertiaryTextHex: "555555"
            ))
        }
    }

    @Test func headerActionsAreTransparentMonochromeControlsWithFullHitTargets() {
        let presentation = LoopdyHeaderActionPresentation.standard

        #expect(presentation.iconPointSize == 17)
        #expect(presentation.hitTarget == 44)
        #expect(presentation.renderingMode == .monochrome)
        #expect(!presentation.showsBackground)
        #expect(!presentation.showsBorder)
        #expect(!presentation.usesTintFill)
    }

    @Test func chatHeaderActionsUseLargerSymbolsAndHitTargets() {
        let presentation = LoopdyHeaderActionPresentation.chatPrimary

        #expect(presentation.iconPointSize == 22)
        #expect(presentation.hitTarget == 48)
    }

    @Test func localGreetingUsesExactMorningAfternoonAndEveningBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))

        #expect(DashboardGreeting.title(at: dashboardDate(hour: 4, minute: 59, calendar: calendar), calendar: calendar) == "Good evening")
        #expect(DashboardGreeting.title(at: dashboardDate(hour: 5, minute: 0, calendar: calendar), calendar: calendar) == "Good morning")
        #expect(DashboardGreeting.title(at: dashboardDate(hour: 11, minute: 59, calendar: calendar), calendar: calendar) == "Good morning")
        #expect(DashboardGreeting.title(at: dashboardDate(hour: 12, minute: 0, calendar: calendar), calendar: calendar) == "Good afternoon")
        #expect(DashboardGreeting.title(at: dashboardDate(hour: 16, minute: 59, calendar: calendar), calendar: calendar) == "Good afternoon")
        #expect(DashboardGreeting.title(at: dashboardDate(hour: 17, minute: 0, calendar: calendar), calendar: calendar) == "Good evening")
    }

    @Test func localGreetingSchedulesTheNextDaypartBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))

        let morning = dashboardDate(hour: 8, minute: 15, calendar: calendar)
        let afternoon = dashboardDate(hour: 13, minute: 30, calendar: calendar)
        let evening = dashboardDate(hour: 20, minute: 45, calendar: calendar)

        #expect(calendar.component(.hour, from: DashboardGreeting.nextTransition(after: morning, calendar: calendar)) == 12)
        #expect(calendar.component(.hour, from: DashboardGreeting.nextTransition(after: afternoon, calendar: calendar)) == 17)
        let nextMorning = DashboardGreeting.nextTransition(after: evening, calendar: calendar)
        #expect(calendar.component(.hour, from: nextMorning) == 5)
        #expect(calendar.isDate(nextMorning, inSameDayAs: evening) == false)
    }

    @Test func rootAndDashboardHeadersExposeOnlyTheRequestedItems() {
        #expect(ShellWorkspaceMenuBarPresentation.trailingTitle == nil)
        #expect(DashboardHeaderPresentation.showsSessionsShortcut == false)
        #expect(DashboardHeaderPresentation.logoPlacement == .greetingRow)
    }

    @Test func primaryNavigationActionUsesNeutralGlassAndThemeAccentWithoutAnOutline() {
        for definition in LoopdyThemeRegistry.builtIns {
            let presentation = FloatingTabBar.newChatPresentation(for: definition.id)

            #expect(presentation.surface == .neutralGlass)
            #expect(presentation.foreground == .themeAccent)
            #expect(!presentation.usesGradient)
            #expect(!presentation.showsBorder)
            #expect(!presentation.usesGlow)
        }
    }

    private func dashboardDate(hour: Int, minute: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 31,
            hour: hour,
            minute: minute
        ))!
    }

    private func validCustomTheme(
        name: String = "Studio",
        font: CustomThemeFontChoice = .system,
        accentHex: String = "3366CC",
        light: CustomThemePalette = CustomThemePalette(
            backgroundHex: "FFFFFF",
            primaryTextHex: "111111",
            secondaryTextHex: "333333",
            tertiaryTextHex: "555555"
        )
    ) throws -> CustomTheme {
        try CustomTheme(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: name,
            font: font,
            accentHex: accentHex,
            light: light,
            dark: CustomThemePalette(
                backgroundHex: "101010",
                primaryTextHex: "FFFFFF",
                secondaryTextHex: "E0E0E0",
                tertiaryTextHex: "B0B0B0"
            )
        )
    }

    @Test func primitiveSpectrumAndStatusColorsMatchTheApprovedPalette() {
        #expect([
            LoopdyTokens.Palette.coralHex,
            LoopdyTokens.Palette.pinkHex,
            LoopdyTokens.Palette.magentaHex,
            LoopdyTokens.Palette.orangeHex,
            LoopdyTokens.Palette.goldHex,
            LoopdyTokens.Palette.violetHex
        ] == ["D33F42", "E44778", "B7356F", "F28B32", "F7C84A", "9A6BFF"])

        #expect([
            LoopdyTokens.Palette.successHex,
            LoopdyTokens.Palette.warningHex,
            LoopdyTokens.Palette.dangerHex,
            LoopdyTokens.Palette.informationHex
        ] == ["176B37", "A85D00", "B42318", "1769AA"])
        #expect(LoopdyTokens.Palette.coralHex != LoopdyTokens.Palette.successHex)
    }

    @Test func geometrySpacingRadiiAndMotionMatchTheApprovedScales() {
        #expect([
            LoopdyTokens.space4,
            LoopdyTokens.space8,
            LoopdyTokens.space12,
            LoopdyTokens.space16,
            LoopdyTokens.space20,
            LoopdyTokens.space24,
            LoopdyTokens.space32,
            LoopdyTokens.space40,
            LoopdyTokens.space48
        ] == [4, 8, 12, 16, 20, 24, 32, 40, 48])
        #expect([
            LoopdyTokens.radius8,
            LoopdyTokens.radius12,
            LoopdyTokens.radius16,
            LoopdyTokens.radius20,
            LoopdyTokens.radius28,
            LoopdyTokens.radiusPill
        ] == [8, 12, 16, 20, 28, 999])
        #expect([
            LoopdyTokens.pressDuration,
            LoopdyTokens.stateDuration,
            LoopdyTokens.transitionDuration,
            LoopdyTokens.sceneDuration
        ] == [0.12, 0.18, 0.26, 0.42])
        #expect([
            LoopdyTokens.hitTarget,
            LoopdyTokens.controlHeight,
            LoopdyTokens.composerHeight,
            LoopdyTokens.primaryActionSize
        ] == [44, 48, 52, 56])
        #expect([
            LoopdyTokens.hairline,
            LoopdyTokens.shadowRadius,
            LoopdyTokens.shadowY
        ] == [1, 12, 4])
    }

    @Test func typographyUsesSemanticSystemTextStyles() {
        #expect(LoopdyTokens.displayTextStyle == .largeTitle)
        #expect(LoopdyTokens.screenTitleTextStyle == .title2)
        #expect(LoopdyTokens.sectionTitleTextStyle == .title3)
        #expect(LoopdyTokens.bodyTextStyle == .body)
        #expect(LoopdyTokens.labelTextStyle == .subheadline)
        #expect(LoopdyTokens.metadataTextStyle == .caption)
    }

    @Test func sharedComponentsResolveFixedSemanticGeometry() {
        let card = LoopdyComponentPresentation.resolve(.card)
        #expect(card.surfaceRole == .card)
        #expect(card.cornerRadius == 20)
        #expect(card.minimumHeight == nil)
        #expect(!card.usesInteractiveSurface)

        let iconButton = LoopdyComponentPresentation.resolve(.iconButton)
        #expect(iconButton.surfaceRole == .circularControl)
        #expect(iconButton.cornerRadius == 22)
        #expect(iconButton.minimumHeight == 44)
        #expect(iconButton.fixedWidth == 44)
        #expect(iconButton.fixedHeight == 44)
        #expect(iconButton.usesInteractiveSurface)

        let pill = LoopdyComponentPresentation.resolve(.pillControl)
        #expect(pill.surfaceRole == .capsuleControl)
        #expect(pill.cornerRadius == 999)
        #expect(pill.minimumHeight == 44)
        #expect(pill.fixedWidth == nil)
        #expect(pill.fixedHeight == nil)
        #expect(pill.usesInteractiveSurface)

        let menu = LoopdyComponentPresentation.resolve(.menuPanel)
        #expect(menu.surfaceRole == .menu)
        #expect(menu.cornerRadius == 28)
        #expect(menu.minimumHeight == nil)
        #expect(!menu.usesInteractiveSurface)

        let clearRow = LoopdyComponentPresentation.resolve(.menuRow)
        let selectedRow = LoopdyComponentPresentation.resolve(.menuRow, isSelected: true)
        #expect(clearRow.surfaceRole == nil)
        #expect(clearRow.cornerRadius == 12)
        #expect(clearRow.minimumHeight == 44)
        #expect(selectedRow.surfaceRole == .selected)
        #expect(!selectedRow.usesInteractiveSurface)

        let composer = LoopdyComponentPresentation.resolve(.composer)
        #expect(composer.surfaceRole == .composer)
        #expect(composer.cornerRadius == 28)
        #expect(composer.minimumHeight == 52)
        #expect(!composer.usesInteractiveSurface)

        let search = LoopdyComponentPresentation.resolve(.searchField)
        #expect(search.surfaceRole == .input)
        #expect(search.cornerRadius == 16)
        #expect(search.minimumHeight == 48)
        #expect(search.usesInteractiveSurface)
    }

    @Test func generatedContentInsetIsRolelessOpaqueAndUnelevated() {
        let generated = LoopdyComponentPresentation.resolve(.generatedContentInset)

        #expect(LoopdySurfaceRole.allCases.count == 9)
        #expect(generated.surfaceRole == nil)
        #expect(generated.cornerRadius == 12)
        #expect(generated.minimumHeight == nil)
        #expect(generated.opaqueBase == .raisedSurface)
        #expect(generated.elevation == .none)
        #expect(!generated.usesInteractiveSurface)
    }

    @Test func semanticComponentAliasesRemainIndependentOfThemeCornerScale() {
        #expect(LoopdyTokens.cardCornerRadius == LoopdyTokens.radius20)
        #expect(LoopdyTokens.menuCornerRadius == LoopdyTokens.radius28)
        #expect(LoopdyTokens.composerCornerRadius == LoopdyTokens.radius28)
        #expect(LoopdyTokens.inputCornerRadius == LoopdyTokens.radius16)
        #expect(LoopdyTokens.menuRowCornerRadius == LoopdyTokens.radius12)
        #expect(LoopdyTokens.generatedContentInsetCornerRadius == LoopdyTokens.radius12)
        #expect(LoopdyTokens.minimumControlSize == LoopdyTokens.hitTarget)
        #expect(LoopdyTokens.composerMinimumHeight == LoopdyTokens.composerHeight)
        #expect(LoopdyTokens.searchMinimumHeight == LoopdyTokens.controlHeight)
    }

    @Test func everyThemeIconStyleHasDistinctObservablePresentation() throws {
        let soft = LoopdyIconPresentation.resolve(style: .soft)
        let technical = LoopdyIconPresentation.resolve(style: .technical)
        let crisp = LoopdyIconPresentation.resolve(style: .crisp)

        #expect(soft == LoopdyIconPresentation(
            renderingMode: .hierarchical,
            symbolVariant: .filled,
            glyphWeight: .semibold,
            innerWell: .tintedCircle
        ))
        #expect(technical == LoopdyIconPresentation(
            renderingMode: .monochrome,
            symbolVariant: .outline,
            glyphWeight: .regular,
            innerWell: .outlinedRoundedRectangle
        ))
        #expect(crisp == LoopdyIconPresentation(
            renderingMode: .monochrome,
            symbolVariant: .outline,
            glyphWeight: .semibold,
            innerWell: .none
        ))
        #expect(soft != technical)
        #expect(soft != crisp)
        #expect(technical != crisp)

        #expect(LoopdyTheme.light.iconStyle == .crisp)
        #expect(LoopdyTheme.nousLight.iconStyle == .technical)
        #expect(LoopdyTheme.superpilotLight.iconStyle == .crisp)
        #expect(LoopdyTheme.light.typeface == .system)
        #expect(LoopdyTheme.light.typography.bodyFontNames.isEmpty)
        #expect(LoopdyTheme.nousLight.typography.displayFontNames.first == "Sigurd Variable")
        #expect(LoopdyTheme.superpilotLight.typography.displayFontNames.first == "Segoe UI Semibold")
    }

    @Test func allSemanticThemeVariantsExposeExactRoles() {
        #expect(roleHexes(LoopdyTheme.light) == [
            "FFF9F5", "FFFFFF", "FFFFFF", "1C1A19", "6F6762", "8F8781",
            "E9E1DB", "EDE6E0", "7B52E0", "FFFFFF", "7B52E0", "1C1A19",
            "1E7A4E", "A85D00", "D33F42", "1769AA", "9A6BFF"
        ])
        #expect(roleHexes(LoopdyTheme.lightHighContrast) == [
            "FFFFFF", "FFFFFF", "FFFFFF", "000000", "3F3A36", "514B47",
            "6F6660", "8A817B", "5E36C7", "FFFFFF", "5E36C7", "1B1917",
            "0E572B", "7A4200", "8F1710", "0D568D", "5E36C7"
        ])
        #expect(roleHexes(LoopdyTheme.dark) == [
            "121110", "1E1C1B", "292624", "F5F2EF", "A39B95", "857D77",
            "33302E", "292624", "C9B6FF", "1C1A19", "9A6BFF", "000000",
            "5BC98A", "F3B24F", "FF8A7A", "69B7ED", "C9B6FF"
        ])
        #expect(roleHexes(LoopdyTheme.darkHighContrast) == [
            "000000", "1C1A19", "292624", "FFFFFF", "E5DED9", "CFC6C0",
            "B8AEA7", "817871", "DCCFFF", "1C1A19", "DCCFFF", "000000",
            "82E39E", "FFD06D", "FF9B93", "8FD0FF", "DCCFFF"
        ])

        #expect(LoopdyTheme.light.actionHex != LoopdyTheme.light.successHex)
        #expect(LoopdyTheme.dark.actionHex != LoopdyTheme.dark.successHex)
        #expect([
            LoopdyTheme.light.actionGlowOpacity,
            LoopdyTheme.light.cardShadowOpacity,
            LoopdyTheme.light.navigationShadowOpacity,
            LoopdyTheme.lightHighContrast.actionGlowOpacity,
            LoopdyTheme.lightHighContrast.cardShadowOpacity,
            LoopdyTheme.lightHighContrast.navigationShadowOpacity,
            LoopdyTheme.dark.actionGlowOpacity,
            LoopdyTheme.dark.cardShadowOpacity,
            LoopdyTheme.dark.navigationShadowOpacity,
            LoopdyTheme.darkHighContrast.actionGlowOpacity,
            LoopdyTheme.darkHighContrast.cardShadowOpacity,
            LoopdyTheme.darkHighContrast.navigationShadowOpacity
        ] == [0.30, 0.06, 0.12, 0.35, 0.12, 0.20, 0.35, 0.20, 0.30, 0.40, 0.32, 0.45])
    }

    @Test func sendButtonColorsMeetNonTextControlContrastAcrossEveryThemeVariant() {
        let variants = LoopdyThemeRegistry.builtIns.flatMap {
            [$0.light, $0.lightHighContrast, $0.dark, $0.darkHighContrast]
        }

        for theme in variants {
            #expect(
                contrastRatio(theme.actionHex, theme.actionForegroundHex) >= 3,
                "\(theme.themeID.rawValue) send button must remain readable in every appearance"
            )
        }
    }

    @Test func chatSendAndStopControlUsesActionTintedLiquidGlass() {
        #expect(AdaptiveComposerActionPresentation.tintOpacity == 0.82)
    }

    @Test func resolverMatrixHonorsSystemAndExplicitAppearance() {
        let cases: [(
            appearance: AppAppearance,
            scheme: ColorScheme,
            contrast: ColorSchemeContrast,
            canvas: String,
            border: String
        )] = [
            (.system, .light, .standard, "FFF9F5", "E9E1DB"),
            (.system, .light, .increased, "FFFFFF", "6F6660"),
            (.system, .dark, .standard, "1C1C1F", "3B3B41"),
            (.system, .dark, .increased, "000000", "B8AEA7"),
            (.light, .light, .standard, "FFF9F5", "E9E1DB"),
            (.light, .dark, .standard, "FFF9F5", "E9E1DB"),
            (.light, .light, .increased, "FFFFFF", "6F6660"),
            (.light, .dark, .increased, "FFFFFF", "6F6660"),
            (.dark, .light, .standard, "1C1C1F", "3B3B41"),
            (.dark, .dark, .standard, "1C1C1F", "3B3B41"),
            (.dark, .light, .increased, "000000", "B8AEA7"),
            (.dark, .dark, .increased, "000000", "B8AEA7")
        ]

        for item in cases {
            let resolved = LoopdyTheme.resolve(
                appearance: item.appearance,
                colorScheme: item.scheme,
                contrast: item.contrast
            )

            #expect(resolved.canvasHex == item.canvas)
            #expect(resolved.borderHex == item.border)
        }
    }

    @Test func compiledBrandAssetsArePresentWithExpectedPixelContracts() throws {
        let mark = try #require(UIImage(named: "LoopdyMarkColor")?.cgImage)
        let wordmarkImage = try #require(UIImage(named: "LoopdyWordmarkMask"))
        let wordmark = try #require(wordmarkImage.cgImage)

        #expect(mark.width == 269)
        #expect(mark.height == 200)
        #expect(hasAlpha(mark.alphaInfo))
        #expect(wordmark.width == 675)
        #expect(wordmark.height == 210)
        #expect(hasAlpha(wordmark.alphaInfo))
        #expect(wordmarkImage.renderingMode == .alwaysTemplate)
    }

    private func roleHexes(_ theme: LoopdyTheme) -> [String] {
        [
            theme.canvasHex,
            theme.surfaceHex,
            theme.raisedSurfaceHex,
            theme.primaryTextHex,
            theme.secondaryTextHex,
            theme.tertiaryTextHex,
            theme.borderHex,
            theme.separatorHex,
            theme.actionHex,
            theme.actionForegroundHex,
            theme.actionGlowHex,
            theme.elevationShadowHex,
            theme.successHex,
            theme.warningHex,
            theme.dangerHex,
            theme.informationHex,
            theme.focusHex
        ]
    }

    private func contrastRatio(_ firstHex: String, _ secondHex: String) -> Double {
        let first = relativeLuminance(firstHex)
        let second = relativeLuminance(secondHex)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func relativeLuminance(_ hex: String) -> Double {
        let value = UInt64(hex, radix: 16) ?? 0
        let components = [
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255,
        ]
        let linear = components.map { component in
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return (0.2126 * linear[0]) + (0.7152 * linear[1]) + (0.0722 * linear[2])
    }

    private func hasAlpha(_ alphaInfo: CGImageAlphaInfo) -> Bool {
        switch alphaInfo {
        case .premultipliedLast, .premultipliedFirst, .last, .first, .alphaOnly:
            true
        case .none, .noneSkipLast, .noneSkipFirst:
            false
        @unknown default:
            false
        }
    }
}

@MainActor
private struct AcceptingVideoValidator: ChatAttachmentVideoValidating {
    func isPlayableVideo(at url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

@MainActor
private final class RecordingPhotoLibraryWriter: ChatAttachmentPhotoLibraryWriting {
    private(set) var observedVideoURL: URL?
    private(set) var videoExistedDuringImport = false
    private(set) var imageWriteCount = 0

    func addImage(_ data: Data) async throws {
        imageWriteCount += 1
    }

    func addVideo(at url: URL) async throws {
        observedVideoURL = url
        videoExistedDuringImport = FileManager.default.fileExists(atPath: url.path)
        try await Task.sleep(for: .milliseconds(10))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

private final class ExecutorRecordingPhotoLibraryWriter: ChatAttachmentPhotoLibraryWriting, @unchecked Sendable {
    private(set) var imageCallWasOnMainThread = false

    func addImage(_ data: Data) async throws {
        imageCallWasOnMainThread = currentThreadIsMain()
    }

    func addVideo(at url: URL) async throws {}

    private func currentThreadIsMain() -> Bool {
        Thread.isMainThread
    }
}
