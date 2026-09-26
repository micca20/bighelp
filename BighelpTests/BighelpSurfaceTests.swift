import Foundation
import Testing
@testable import Bighelp

struct BighelpSurfaceTests {
    private struct RoleExpectation {
        let role: BighelpSurfaceRole
        let alwaysOpaque: Bool
        let shape: BighelpSurfaceShape
        let cornerRadius: CGFloat
        let standardElevation: BighelpSurfaceElevation
        let increasedElevation: BighelpSurfaceElevation
        let allowsInteractiveGlass: Bool
    }

    private let roleExpectations: [RoleExpectation] = [
        RoleExpectation(
            role: .card,
            alwaysOpaque: true,
            shape: .roundedRectangle,
            cornerRadius: 20,
            standardElevation: .low,
            increasedElevation: .medium,
            allowsInteractiveGlass: false
        ),
        RoleExpectation(
            role: .menu,
            alwaysOpaque: false,
            shape: .roundedRectangle,
            cornerRadius: 28,
            standardElevation: .high,
            increasedElevation: .high,
            allowsInteractiveGlass: false
        ),
        RoleExpectation(
            role: .sheet,
            alwaysOpaque: false,
            shape: .roundedRectangle,
            cornerRadius: 28,
            standardElevation: .high,
            increasedElevation: .high,
            allowsInteractiveGlass: false
        ),
        RoleExpectation(
            role: .navigation,
            alwaysOpaque: false,
            shape: .roundedRectangle,
            cornerRadius: 28,
            standardElevation: .medium,
            increasedElevation: .high,
            allowsInteractiveGlass: false
        ),
        RoleExpectation(
            role: .composer,
            alwaysOpaque: false,
            shape: .roundedRectangle,
            cornerRadius: 28,
            standardElevation: .medium,
            increasedElevation: .high,
            allowsInteractiveGlass: false
        ),
        RoleExpectation(
            role: .input,
            alwaysOpaque: false,
            shape: .roundedRectangle,
            cornerRadius: 16,
            standardElevation: .none,
            increasedElevation: .low,
            allowsInteractiveGlass: true
        ),
        RoleExpectation(
            role: .circularControl,
            alwaysOpaque: false,
            shape: .circle,
            cornerRadius: 22,
            standardElevation: .low,
            increasedElevation: .medium,
            allowsInteractiveGlass: true
        ),
        RoleExpectation(
            role: .capsuleControl,
            alwaysOpaque: false,
            shape: .capsule,
            cornerRadius: 999,
            standardElevation: .low,
            increasedElevation: .medium,
            allowsInteractiveGlass: true
        ),
        RoleExpectation(
            role: .selected,
            alwaysOpaque: true,
            shape: .roundedRectangle,
            cornerRadius: 12,
            standardElevation: .none,
            increasedElevation: .low,
            allowsInteractiveGlass: false
        ),
    ]

    @Test func resolverCoversEveryRoleAndPlatformAccessibilityCombination() {
        #expect(roleExpectations.map(\.role) == BighelpSurfaceRole.allCases)

        for expectation in roleExpectations {
            for supportsLiquidGlass in [false, true] {
                for reduceTransparency in [false, true] {
                    for increaseContrast in [false, true] {
                        let value = BighelpSurfacePresentation.resolve(
                            role: expectation.role,
                            supportsLiquidGlass: supportsLiquidGlass,
                            reduceTransparency: reduceTransparency,
                            increaseContrast: increaseContrast
                        )
                        let expectedFill: BighelpSurfaceFill

                        if expectation.alwaysOpaque || reduceTransparency {
                            expectedFill = .opaque
                        } else if supportsLiquidGlass {
                            expectedFill = .liquidGlass
                        } else {
                            expectedFill = .material
                        }

                        #expect(value.fill == expectedFill)
                        #expect(value.shape == expectation.shape)
                        #expect(value.cornerRadius == expectation.cornerRadius)
                        #expect(value.elevation == (
                            increaseContrast
                                ? expectation.increasedElevation
                                : expectation.standardElevation
                        ))
                        #expect(value.outline == (increaseContrast ? .increased : .standard))
                        #expect(value.allowsInteractiveGlass == expectation.allowsInteractiveGlass)
                        #expect(value.usesInteractiveGlass == (
                            expectedFill == .liquidGlass && expectation.allowsInteractiveGlass
                        ))
                    }
                }
            }
        }
    }

    @Test func selectedRenderingPlanUsesOpaqueNeutralBaseWithRestrainedAccentOverlay() {
        for reduceTransparency in [false, true] {
            let presentation = BighelpSurfacePresentation.resolve(
                role: .selected,
                supportsLiquidGlass: true,
                reduceTransparency: reduceTransparency,
                increaseContrast: false
            )
            let plan = BighelpSurfaceRenderingPlan.resolve(for: presentation)

            #expect(plan.opaqueBase == .surface)
            #expect(plan.accentOverlay == .restrainedAccent)
        }
    }

    @Test(arguments: BighelpSurfaceRole.allCases)
    func callerRequestCannotOverrideRoleInteractivityPolicy(_ role: BighelpSurfaceRole) {
        let value = BighelpSurfacePresentation.resolve(
            role: role,
            supportsLiquidGlass: true,
            reduceTransparency: false,
            increaseContrast: false
        )

        #expect(!value.usesInteractiveGlass(whenRequested: false))
        #expect(value.usesInteractiveGlass(whenRequested: true) == [
            BighelpSurfaceRole.input,
            .circularControl,
            .capsuleControl,
        ].contains(role))
    }

    @Test(arguments: BighelpSurfaceRole.allCases)
    func liquidGlassUsesItsNativeEdgeInsteadOfAThemeColoredOutline(_ role: BighelpSurfaceRole) {
        let glass = BighelpSurfacePresentation.resolve(
            role: role,
            supportsLiquidGlass: true,
            reduceTransparency: false,
            increaseContrast: false
        )

        if glass.fill == .liquidGlass {
            #expect(!glass.drawsExplicitOutline)
        }

        let fallback = BighelpSurfacePresentation.resolve(
            role: role,
            supportsLiquidGlass: false,
            reduceTransparency: false,
            increaseContrast: false
        )
        #expect(fallback.drawsExplicitOutline)
    }
}
