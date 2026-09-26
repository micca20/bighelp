import CoreGraphics
import Foundation

/// How the eyes look in one frame.
enum BuddyEyeState: Equatable, Sendable {
    /// Open eyes. `openness` 0…1 animates blinks; `look` shifts the gaze (−1…1).
    case open(openness: CGFloat, look: CGPoint)
    case wide(look: CGPoint)
    case happy
    case closed
    case squint(look: CGPoint)
    case sad
}

enum BuddyMouth: Equatable, Sendable {
    case smile
    case grin
    /// Talking or gasping; `amount` 0…1.
    case open(CGFloat)
    case small
    case flat
    case frown
}

/// Little extras drawn around the character.
enum BuddyEffect: Equatable, Sendable {
    case thought
    case sparkles
    case question
    case alert
    case sleep
    case notes
    case tear
    case hearts
    case code
}

/// One frame of motion for a character, in 100×100 design units.
struct BuddyPose: Equatable, Sendable {
    var offset = CGSize.zero
    /// Degrees, clockwise.
    var rotation: CGFloat = 0
    /// Squash and stretch around the feet: >1 is wider, <1 is taller.
    var squash: CGFloat = 1
    var eyes = BuddyEyeState.open(openness: 1, look: .zero)
    var mouth = BuddyMouth.smile
    var effect: BuddyEffect?
    var blush = true
    /// 0…1: how much a character plays its own flourish (claw snaps, wing flaps).
    var flourish: CGFloat = 0.4
    /// Seconds, for character flourishes and effects.
    var time: Double = 0

    /// Every mood ID the characters act out.
    static let moods: Set<String> = [
        "idle", "listening", "thinking", "bounce", "curious", "excited", "alert", "sad", "dance",
        "happy", "lookAround", "sleepy", "meditate", "spin", "scan", "nod", "peek", "squint"
    ]

    /// Pose for an engine mood ID at `time` seconds. Unknown moods idle.
    /// `breathes: false` leaves idle breathing to a renderer that has its own.
    static func make(mood: String?, time t: Double, audioLevel: Double = 0, seed: Double = 0, breathes: Bool = true) -> BuddyPose {
        var pose = BuddyPose(time: t)
        let blink = blinkOpenness(t + seed)
        let breathe = breathes ? CGFloat(sin(t * 1.8)) : 0
        pose.offset.height = breathe * 1.1
        pose.squash = 1 + breathe * 0.012
        pose.eyes = .open(openness: blink, look: .zero)

        switch mood ?? "idle" {
        case "listening":
            pose.rotation = 5 + CGFloat(sin(t * 1.4)) * 2
            pose.eyes = .wide(look: CGPoint(x: 0.25, y: -0.1))
            pose.mouth = .small
        case "thinking":
            pose.rotation = -5 + CGFloat(sin(t * 0.9)) * 3
            pose.eyes = .open(openness: blink, look: CGPoint(x: -0.6, y: -0.7))
            pose.mouth = .flat
            pose.effect = .thought
            pose.flourish = 0.2
        case "bounce":
            let hop = abs(sin(t * 5))
            pose.offset.height = -CGFloat(hop) * 6
            pose.squash = hop < 0.15 ? 1.08 : 0.97
            pose.eyes = .open(openness: blink, look: .zero)
            pose.mouth = audioLevel > 0 ? .open(CGFloat(0.35 + audioLevel * 0.65)) : .grin
            pose.flourish = 1
        case "curious":
            pose.rotation = 11
            pose.eyes = .wide(look: CGPoint(x: 0.5, y: -0.2))
            pose.mouth = .small
        case "excited":
            let hop = abs(sin(t * 6))
            pose.offset.height = -CGFloat(hop) * 9
            pose.rotation = CGFloat(sin(t * 12)) * 6
            pose.squash = hop < 0.15 ? 1.1 : 0.96
            pose.eyes = .happy
            pose.mouth = .grin
            pose.effect = .sparkles
            pose.flourish = 1
        case "alert":
            let shake = t.truncatingRemainder(dividingBy: 2.4) < 0.5 ? sin(t * 40) * 5 : 0
            pose.rotation = CGFloat(shake)
            pose.eyes = .wide(look: .zero)
            pose.mouth = .small
            pose.effect = .alert
            pose.flourish = 0.8
        case "sad":
            pose.offset.height = 2.5 + breathe * 0.5
            pose.squash = 0.97
            pose.rotation = -3
            pose.eyes = .sad
            pose.mouth = .frown
            pose.effect = .tear
            pose.blush = false
            pose.flourish = 0
        case "dance":
            let beat = sin(t * 4.2)
            pose.offset.width = CGFloat(beat) * 5
            pose.offset.height = -CGFloat(abs(cos(t * 4.2))) * 4
            pose.rotation = CGFloat(beat) * 11
            pose.eyes = .happy
            pose.mouth = .grin
            pose.effect = .notes
            pose.flourish = 1
        case "happy":
            let hop = abs(sin(t * 3))
            pose.offset.height = -CGFloat(hop) * 3
            pose.eyes = .happy
            pose.mouth = .grin
            pose.effect = .hearts
            pose.flourish = 0.7
        case "lookAround":
            let side = sin(t * 1.3)
            pose.rotation = CGFloat(side) * 4
            pose.eyes = .open(openness: blink, look: CGPoint(x: CGFloat(side) * 0.9, y: -0.1))
            pose.flourish = 0.5
        case "sleepy":
            pose.offset.height = 1.5 + breathe * 1.4
            pose.squash = 1.02 + breathe * 0.02
            pose.rotation = -4
            pose.eyes = .closed
            pose.mouth = .small
            pose.effect = .sleep
            pose.flourish = 0
        case "meditate":
            pose.offset.height = -4 - CGFloat(sin(t * 1.1)) * 3
            pose.eyes = .closed
            pose.mouth = .smile
            pose.effect = .sparkles
            pose.flourish = 0.1
        case "spin":
            let cycle = t.truncatingRemainder(dividingBy: 3.2)
            if cycle < 1.1 {
                let progress = cycle / 1.1
                let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
                pose.rotation = CGFloat(eased * 360)
                pose.offset.height = -CGFloat(sin(progress * .pi)) * 7
                pose.eyes = .happy
                pose.mouth = .grin
            }
            pose.flourish = 0.8
        case "scan":
            let sweep = sin(t * 2.6)
            pose.eyes = .squint(look: CGPoint(x: CGFloat(sweep) * 0.9, y: 0.2))
            pose.mouth = .flat
            pose.effect = .code
            pose.rotation = CGFloat(sweep) * 2
            pose.flourish = 0.6
        case "nod":
            pose.offset.height = CGFloat(abs(sin(t * 4))) * 2.5
            pose.rotation = CGFloat(sin(t * 4)) * 2
            pose.eyes = .happy
            pose.mouth = .smile
        case "peek":
            pose.offset.width = 4
            pose.rotation = 9
            pose.eyes = .open(openness: blink, look: CGPoint(x: 0.9, y: 0))
            pose.mouth = .small
        case "squint":
            pose.rotation = -2 + CGFloat(sin(t * 3)) * 1.5
            pose.eyes = .squint(look: CGPoint(x: 0, y: 0.3))
            pose.mouth = .flat
            pose.flourish = 0.9
        default:
            break
        }
        return pose
    }

    /// Eyes close briefly every few seconds; a double blink now and then.
    static func blinkOpenness(_ t: Double) -> CGFloat {
        let period = 3.9
        let local = t.truncatingRemainder(dividingBy: period)
        let first = abs(local - 2.2)
        let second = abs(local - 2.45)
        let closest = min(first, t.truncatingRemainder(dividingBy: period * 3) > period * 2 ? second : first)
        guard closest < 0.09 else { return 1 }
        return CGFloat(max(0.08, closest / 0.09))
    }
}
