import Foundation
import CoreGraphics

/// Foundation/CoreGraphics, renderer-independent 2D motion for a companion overlay.
///
/// `position` is the pet's center in the host canvas coordinate space (positive Y
/// points down). The host owns gesture routing and calls the drag methods with
/// monotonically increasing timestamps, then calls `step(dt:bounds:)` while the
/// pet is airborne. `bounds` is the usable canvas after safe-area/chat exclusions;
/// constraints account for `size`, so no invisible full-screen hit surface is
/// needed.
struct CompanionPhysics: Equatable, Sendable {
    struct Velocity: Equatable, Sendable {
        var dx: CGFloat
        var dy: CGFloat

        static let zero = Velocity(dx: 0, dy: 0)

        var magnitude: CGFloat {
            hypot(dx, dy)
        }
    }

    struct Configuration: Equatable, Sendable {
        var gravity: CGFloat = 1_150
        var airResistance: CGFloat = 0.8
        var bounceRetention: CGFloat = 0.62
        var floorTangentialRetention: CGFloat = 0.84
        var maximumSpeed: CGFloat = 3_600
        var maximumTimeStep: TimeInterval = 1.0 / 20.0
        var velocitySampleWindow: TimeInterval = 0.12
        var settleSpeed: CGFloat = 18

        static let `default` = Configuration()
    }

    private struct DragSample: Equatable, Sendable {
        let point: CGPoint
        let time: TimeInterval
    }

    var position: CGPoint
    var velocity: Velocity
    var size: CGSize
    let configuration: Configuration

    private(set) var isDragging = false
    private(set) var isSettled = false

    private var dragOffset = CGSize.zero
    private var dragSamples: [DragSample] = []

    init(
        position: CGPoint,
        velocity: Velocity = .zero,
        size: CGSize,
        configuration: Configuration = .default
    ) {
        self.position = Self.sanitized(point: position)
        self.velocity = Self.sanitized(velocity: velocity)
        self.size = Self.sanitized(size: size)
        self.configuration = configuration
        self.velocity = limitedVelocity(self.velocity)
    }

    /// Begins a host-owned drag without snapping the pet's center to the finger.
    mutating func startDrag(
        at fingerPoint: CGPoint,
        time: TimeInterval,
        bounds: CGRect
    ) {
        sanitizeState(in: bounds)
        let point = Self.sanitized(point: fingerPoint, fallback: position)
        dragOffset = CGSize(
            width: position.x - point.x,
            height: position.y - point.y
        )
        dragSamples = [DragSample(point: point, time: Self.sanitized(time: time))]
        velocity = .zero
        isDragging = true
        isSettled = false
    }

    /// Moves the pet and records bounded finger history for release velocity.
    mutating func moveDrag(
        to fingerPoint: CGPoint,
        time: TimeInterval,
        bounds: CGRect
    ) {
        guard isDragging else { return }
        let point = Self.sanitized(point: fingerPoint, fallback: position)
        let timestamp = normalizedSampleTime(time)
        appendSample(point: point, time: timestamp)
        position = constrainedCenter(
            CGPoint(
                x: point.x + dragOffset.width,
                y: point.y + dragOffset.height
            ),
            in: bounds
        )
        velocity = .zero
        isSettled = false
    }

    /// Ends a drag and applies velocity sampled from recent finger movement.
    /// The final point is optional so hosts can use the last move event verbatim.
    mutating func endDrag(
        at fingerPoint: CGPoint? = nil,
        time: TimeInterval,
        bounds: CGRect
    ) {
        guard isDragging else { return }
        let timestamp = normalizedSampleTime(time)
        if let fingerPoint {
            let point = Self.sanitized(point: fingerPoint, fallback: position)
            appendSample(point: point, time: timestamp)
            position = constrainedCenter(
                CGPoint(
                    x: point.x + dragOffset.width,
                    y: point.y + dragOffset.height
                ),
                in: bounds
            )
        } else if let lastPoint = dragSamples.last?.point {
            // A stationary hold must age out prior movement at release time.
            appendSample(point: lastPoint, time: timestamp)
        }

        velocity = sampledVelocity()
        isDragging = false
        let floorY = centerLimits(in: bounds).maxY
        isSettled = abs(position.y - floorY) < 0.5
            && velocity.magnitude < configuration.settleSpeed
        if isSettled {
            velocity = .zero
        }
        dragSamples.removeAll(keepingCapacity: true)
        position = constrainedCenter(position, in: bounds)
    }

    /// Advances gravity, air resistance, size-aware wall collisions, bounce loss,
    /// and floor settling. Nonfinite time is treated as zero; large time is capped.
    mutating func step(dt rawTimeStep: TimeInterval, bounds: CGRect) {
        sanitizeState(in: bounds)
        guard !isDragging else { return }

        let maximumStep = Self.finitePositive(configuration.maximumTimeStep)
            ?? (1.0 / 20.0)
        let timeStep: TimeInterval
        if rawTimeStep.isFinite {
            timeStep = min(max(rawTimeStep, 0), maximumStep)
        } else {
            timeStep = 0
        }
        guard timeStep > 0, !isSettled else { return }

        let substepLimit = 1.0 / 120.0
        let substepCount = max(1, min(8, Int(ceil(timeStep / substepLimit))))
        let substep = CGFloat(timeStep / Double(substepCount))
        for _ in 0..<substepCount {
            integrate(substep: substep, bounds: bounds)
        }
    }

    /// Updates layout size and immediately restores a valid center.
    mutating func setSize(_ size: CGSize, bounds: CGRect) {
        self.size = Self.sanitized(size: size)
        position = constrainedCenter(position, in: bounds)
    }

    /// Repositions without adding launch velocity. Gravity resumes unless the
    /// new center is already resting on the floor constraint.
    mutating func place(at center: CGPoint, bounds: CGRect) {
        position = constrainedCenter(Self.sanitized(point: center), in: bounds)
        velocity = .zero
        isSettled = abs(position.y - centerLimits(in: bounds).maxY) < 0.5
    }

    private mutating func integrate(substep: CGFloat, bounds: CGRect) {
        let gravity = configuration.gravity.isFinite ? configuration.gravity : 0
        let resistance = max(
            configuration.airResistance.isFinite ? configuration.airResistance : 0,
            0
        )
        velocity.dy += gravity * substep
        let drag = exp(-resistance * substep)
        velocity.dx *= drag
        velocity.dy *= drag
        velocity = limitedVelocity(velocity)

        position.x += velocity.dx * substep
        position.y += velocity.dy * substep

        let limits = centerLimits(in: bounds)
        let bounce = min(max(
            configuration.bounceRetention.isFinite
                ? configuration.bounceRetention
                : 0,
            0
        ), 1)
        let floorRetention = min(max(
            configuration.floorTangentialRetention.isFinite
                ? configuration.floorTangentialRetention
                : 0,
            0
        ), 1)

        if position.x < limits.minX {
            position.x = limits.minX
            velocity.dx = abs(velocity.dx) * bounce
        } else if position.x > limits.maxX {
            position.x = limits.maxX
            velocity.dx = -abs(velocity.dx) * bounce
        }

        if position.y < limits.minY {
            position.y = limits.minY
            velocity.dy = abs(velocity.dy) * bounce
        } else if position.y > limits.maxY {
            position.y = limits.maxY
            velocity.dy = -abs(velocity.dy) * bounce
            velocity.dx *= floorRetention
        }

        let restingOnFloor = abs(position.y - limits.maxY) < 0.5
        let settleSpeed = max(
            configuration.settleSpeed.isFinite ? configuration.settleSpeed : 0,
            0
        )
        if restingOnFloor,
           abs(velocity.dy) <= settleSpeed,
           abs(velocity.dx) <= settleSpeed {
            position.y = limits.maxY
            velocity = .zero
            isSettled = true
        }
    }

    private mutating func sanitizeState(in bounds: CGRect) {
        position = constrainedCenter(Self.sanitized(point: position), in: bounds)
        velocity = limitedVelocity(Self.sanitized(velocity: velocity))
        size = Self.sanitized(size: size)
        if isSettled, abs(position.y - centerLimits(in: bounds).maxY) >= 0.5 {
            isSettled = false
        }
    }

    private mutating func appendSample(point: CGPoint, time: TimeInterval) {
        dragSamples.append(DragSample(point: point, time: time))
        let configuredWindow = Self.finitePositive(configuration.velocitySampleWindow) ?? 0.12
        let cutoff = time - min(configuredWindow, 0.5)
        dragSamples.removeAll { $0.time < cutoff }
        if dragSamples.count > 12 {
            dragSamples.removeFirst(dragSamples.count - 12)
        }
    }

    private func sampledVelocity() -> Velocity {
        guard let newest = dragSamples.last else { return .zero }
        let configuredWindow = Self.finitePositive(configuration.velocitySampleWindow) ?? 0.12
        let oldest = dragSamples.first(where: {
            newest.time - $0.time <= configuredWindow
                && newest.time - $0.time >= 0.008
        })
        guard let oldest else { return .zero }
        let duration = newest.time - oldest.time
        guard duration.isFinite, duration >= 0.008 else { return .zero }
        let durationInSeconds = CGFloat(duration)
        return limitedVelocity(
            Velocity(
                dx: (newest.point.x - oldest.point.x) / durationInSeconds,
                dy: (newest.point.y - oldest.point.y) / durationInSeconds
            )
        )
    }

    private func limitedVelocity(_ velocity: Velocity) -> Velocity {
        let sanitized = Self.sanitized(velocity: velocity)
        let configuredMaximum = Self.finitePositive(configuration.maximumSpeed) ?? 3_600
        let magnitude = sanitized.magnitude
        guard magnitude.isFinite, magnitude > configuredMaximum, magnitude > 0 else {
            return sanitized
        }
        let scale = configuredMaximum / magnitude
        return Velocity(dx: sanitized.dx * scale, dy: sanitized.dy * scale)
    }

    private func normalizedSampleTime(_ proposed: TimeInterval) -> TimeInterval {
        let fallback = dragSamples.last?.time ?? 0
        let sanitized = Self.sanitized(time: proposed, fallback: fallback)
        return max(sanitized, fallback)
    }

    private func constrainedCenter(_ proposed: CGPoint, in rawBounds: CGRect) -> CGPoint {
        let limits = centerLimits(in: rawBounds)
        return CGPoint(
            x: min(max(proposed.x, limits.minX), limits.maxX),
            y: min(max(proposed.y, limits.minY), limits.maxY)
        )
    }

    private func centerLimits(in rawBounds: CGRect) -> (
        minX: CGFloat,
        maxX: CGFloat,
        minY: CGFloat,
        maxY: CGFloat
    ) {
        let bounds = Self.sanitized(bounds: rawBounds)
        let safeSize = Self.sanitized(size: size)
        let halfWidth = safeSize.width * 0.5
        let halfHeight = safeSize.height * 0.5

        let availableMinX = bounds.minX + halfWidth
        let availableMaxX = bounds.maxX - halfWidth
        let availableMinY = bounds.minY + halfHeight
        let availableMaxY = bounds.maxY - halfHeight

        let centerX = bounds.midX
        let centerY = bounds.midY
        return (
            minX: availableMinX <= availableMaxX ? availableMinX : centerX,
            maxX: availableMinX <= availableMaxX ? availableMaxX : centerX,
            minY: availableMinY <= availableMaxY ? availableMinY : centerY,
            maxY: availableMinY <= availableMaxY ? availableMaxY : centerY
        )
    }

    private static func sanitized(
        point: CGPoint,
        fallback: CGPoint = .zero
    ) -> CGPoint {
        CGPoint(
            x: point.x.isFinite ? point.x : fallback.x,
            y: point.y.isFinite ? point.y : fallback.y
        )
    }

    private static func sanitized(velocity: Velocity) -> Velocity {
        Velocity(
            dx: velocity.dx.isFinite ? velocity.dx : 0,
            dy: velocity.dy.isFinite ? velocity.dy : 0
        )
    }

    private static func sanitized(size: CGSize) -> CGSize {
        CGSize(
            width: size.width.isFinite ? max(abs(size.width), 0) : 0,
            height: size.height.isFinite ? max(abs(size.height), 0) : 0
        )
    }

    private static func sanitized(bounds: CGRect) -> CGRect {
        guard
            bounds.origin.x.isFinite,
            bounds.origin.y.isFinite,
            bounds.width.isFinite,
            bounds.height.isFinite
        else {
            return .zero
        }
        return bounds.standardized
    }

    private static func sanitized(
        time: TimeInterval,
        fallback: TimeInterval = 0
    ) -> TimeInterval {
        time.isFinite ? time : fallback
    }

    private static func finitePositive(_ value: CGFloat) -> CGFloat? {
        value.isFinite && value > 0 ? value : nil
    }

    private static func finitePositive(_ value: TimeInterval) -> TimeInterval? {
        value.isFinite && value > 0 ? value : nil
    }
}
