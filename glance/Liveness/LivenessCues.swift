//
//  LivenessCues.swift
//  glance
//
//  Liveness decision model: five independent cues. DENY cues override CONFIRM
//  cues unconditionally, in every mode.
//
//  What a confirm cue's *absence* means depends on the mode, and this is the
//  security-relevant sentence in the whole file:
//
//    .light   absence is never a failure  (defeated by a matte print — not the default)
//    .medium  absence is a failure unless the confirm cues *together* clear
//             `mediumConfirmScore`
//    .heavy   absence is a failure unless one confirm cue fully fires
//

import CoreGraphics

/// One cue's latest reading. `confidence` 0 is always an abstention, never a reading of
/// zero — a cue that can't see anything must not be able to convict or acquit.
struct CueReading: Equatable {
    /// 0...1 strength of this cue's own evidence, in the direction that
    /// cue argues for (spoof-ness for deny cues, liveness for confirm cues).
    let level: Float
    let confidence: Float

    nonisolated static let none = CueReading(level: 0, confidence: 0)
}

enum LivenessCueRole: Equatable {
    /// Evidence of a spoof. Firing fails the scan and overrides confirmation.
    case deny
    /// Evidence of a real face. Firing passes the liveness half of the scan.
    case confirm
}

enum LivenessCue: String, CaseIterable, Hashable, Identifiable {
    case glossGlare
    case deviceDetected
    case flatVs3D
    case depthPose
    case blink

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .glossGlare: return "Gloss/glare"
        case .deviceDetected: return "Device detected"
        case .flatVs3D: return "Flat vs 3D"
        case .depthPose: return "Depth/pose"
        case .blink: return "Blink"
        }
    }

    nonisolated var role: LivenessCueRole {
        switch self {
        case .glossGlare, .deviceDetected: return .deny
        case .flatVs3D, .depthPose, .blink: return .confirm
        }
    }

    /// One-line explanation of what firing actually means, for Face Lab.
    nonisolated var explanation: String {
        switch self {
        case .glossGlare: return "Large flat specular highlight — glass/screen glare rather than skin's small scattered shine."
        case .deviceDetected: return "A device-shaped rectangle overlaps the face — a phone or tablet held up."
        case .flatVs3D: return "Held-out nose points miss the plane fit — the face has real depth."
        case .depthPose: return "Nose offset tracks head yaw — the nose sits off the eye plane, so this isn't flat."
        case .blink: return "Eye aspect ratio dipped and recovered — a photo cannot blink."
        }
    }
}

/// How much liveness checking runs. Both modes always run the deny cues —
/// the difference is only whether a *positive* proof of life is also
/// required before unlocking.
enum LivenessMode: String, CaseIterable, Identifiable, Sendable {
    /// Deny-only: "confirmed unless proven wrong." Never blocks a user who sits still.
    ///
    /// Defeated by a matte print with its edges out of frame: neither deny cue has
    /// anything to fire on, and no confirm cue is required. Reproduced on a real
    /// device. Offered, but deliberately not the default.
    case light

    /// Deny cues, plus confirm evidence *summed across cues* after normalising each
    /// cue's level against its own fire threshold (`normalizedEvidence(for:reading:)`).
    ///
    /// Exists because Heavy's per-cue fire thresholds sit above what a real face
    /// actually produces at realistic landmark noise. Measured in the self-test at
    /// 1.0px noise, the flat-vs-3D cue reads 0.21 for a live head against a 0.25 fire
    /// level — so Heavy falls through to "blink or rotate 12deg+" — while a tilted
    /// print reads 0.02. The separation is ~10x; only the threshold was misplaced.
    /// Normalising and summing recovers that separation without demanding any single
    /// cue clear a bar a live face barely reaches.
    case medium

    /// Deny cues plus at least one confirm cue fully fired. Can block a user who holds
    /// perfectly still and never blinks for the whole scan.
    case heavy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Minimal"
        case .medium: return "Balanced"
        case .heavy: return "Strict"
        }
    }

    var summary: String {
        switch self {
        case .light: return "Only rejects obvious spoofs."
        case .medium: return "Requires combined proof of a real face."
        case .heavy: return "Requires one full proof of life."
        }
    }

    /// The default, and what the UI marks as recommended.
    nonisolated static let recommended = LivenessMode.medium

    /// True for any mode weaker than `recommended`. Drives the confirmation the UI
    /// puts in front of a downgrade — see `LivenessModePicker`.
    var isWeakerThanRecommended: Bool { self == .light }

    /// Shown verbatim when the user downgrades to this mode. Plain, once, no hedging.
    var downgradeWarning: String? {
        switch self {
        case .light:
            return "Minimal only rejects obvious spoofs. A printed photo of your face "
                 + "can unlock your Mac. This has been reproduced on real hardware."
        case .medium, .heavy:
            return nil
        }
    }
}

/// Fire thresholds per cue: a cue counts a frame when its reading is confident and
/// at/above `level`, and fires once it has counted `frames` of them within the scan.
/// Seeded from real-device observation; retune from Face Lab.
struct LivenessTuning: Equatable {
    var glossLevel: Float = 0.04
    var glossFrames: Int = 3

    /// Deliberately lower than `glossLevel` — the device rectangle detector was already
    /// the one signal proven reliable in real-device testing.
    var deviceLevel: Float = 0.15
    var deviceFrames: Int = 3

    /// Not the 0.5 you might expect: real-world Vision jitter alone measures ~0.21-0.46
    /// in the self-test, so 0.5 would mean this cue essentially never fires.
    var flatVs3DLevel: Float = 0.25
    var flatVs3DFrames: Int = 2

    /// Deliberately high: this level is a remapped correlation `(r + 1) / 2`, so 0.5 is
    /// zero correlation (evidence of nothing) — 0.8 requires r >= 0.6.
    var depthPoseLevel: Float = 0.8
    var depthPoseFrames: Int = 2

    /// A blink is already a discrete dip-and-recover event (see `LivenessScoring.blinkDynamics`),
    /// not a ramping level, so one firing frame is the event itself.
    var blinkFrames: Int = 1

    /// Frames Light mode waits before auto-confirming, so deny cues get a fair chance to
    /// fire first — otherwise a first-frame match could unlock before glare/device ever ran.
    var lightModeMinimumFrames: Int = 3

    /// Medium mode: summed peak `normalizedEvidence` across the confirm cues needed to pass.
    ///
    /// 1.0 would mean "one cue fully fired", which Heavy already handles, so this must sit
    /// below 1. At 1.0px landmark noise the self-test measures a live head at ~0.68 on
    /// flat-vs-3D alone against ~0.05 for a tilted print; 0.55 sits inside that gap with
    /// room on both sides. Retune from Face Lab, and re-run `tools/liveness_selftest.swift`.
    var mediumConfirmScore: Float = 0.55

    /// Minimum yaw range, in degrees, the geometry-based confirm cues need before they
    /// read at all. Below this the predicted landmark displacement is sub-pixel, so a
    /// reading would be measuring Vision's noise rather than the user's head.
    ///
    /// Balanced runs a lower gate than Minimal and Strict. It can afford to, because it
    /// never trusts one cue on its own — a weak reading contributes a little to a sum
    /// instead of deciding by itself, and confidence still ramps from wherever the gate
    /// sits, so a smaller rotation is worth proportionally less.
    var minYawRangeDegrees: CGFloat = 12
    /// 6, not lower. Swept in `tools/liveness_selftest.swift`: at a 6-degree gate a live
    /// head scores 0.86 once its yaw range reaches 9 degrees — half the rotation the
    /// 12-degree gate demands — while every photo sequence stays at or below 0.29 against
    /// the 0.55 threshold. At a 4-degree gate the planar-wobble attack (a flat photo moved
    /// in a pure homography, the hardest 2D spoof here) reaches 0.465, which is 85% of the
    /// way in. That is why this is 6 and not 4.
    var mediumMinYawRangeDegrees: CGFloat = 6

    /// Medium waits at least this long before it can pass, for the same reason Light does:
    /// the deny cues need frames on the board before anything is allowed to confirm. Higher
    /// than Light's because the confirm cues read a window, not a single frame.
    var mediumModeMinimumFrames: Int = 6

    nonisolated static let `default` = LivenessTuning()

    nonisolated func minYawRange(for mode: LivenessMode) -> CGFloat {
        mode == .medium ? mediumMinYawRangeDegrees : minYawRangeDegrees
    }

    /// The level at which a cue is saying *nothing*, which is not always zero.
    /// `depthPose` reports a remapped correlation `(r + 1) / 2`, so its "no evidence"
    /// point is 0.5 — feeding its raw level into a sum would credit a cue that has
    /// measured exactly zero correlation with half a cue's worth of proof of life.
    nonisolated func neutralLevel(for cue: LivenessCue) -> Float {
        switch cue {
        case .depthPose: return 0.5
        case .glossGlare, .deviceDetected, .flatVs3D, .blink: return 0
        }
    }

    /// This reading as a 0...1 fraction of "would have fired on its own", weighted by
    /// the cue's own confidence. An abstention (confidence 0) contributes nothing, which
    /// is the whole point of keeping confidence separate from level.
    nonisolated func normalizedEvidence(for cue: LivenessCue, reading: CueReading) -> Float {
        let neutral = neutralLevel(for: cue)
        let fire = level(for: cue)
        guard fire > neutral else { return 0 }
        let normalized = min(max((reading.level - neutral) / (fire - neutral), 0), 1)
        return normalized * min(max(reading.confidence, 0), 1)
    }

    nonisolated func level(for cue: LivenessCue) -> Float {
        switch cue {
        case .glossGlare: return glossLevel
        case .deviceDetected: return deviceLevel
        case .flatVs3D: return flatVs3DLevel
        case .depthPose: return depthPoseLevel
        // Any confident blink reading is the event; see `blinkFrames`.
        case .blink: return 0.5
        }
    }

    nonisolated func frames(for cue: LivenessCue) -> Int {
        switch cue {
        case .glossGlare: return glossFrames
        case .deviceDetected: return deviceFrames
        case .flatVs3D: return flatVs3DFrames
        case .depthPose: return depthPoseFrames
        case .blink: return blinkFrames
        }
    }
}

enum LivenessDecision: Equatable {
    /// Nothing decided yet. Not a failure — the scan should keep going.
    case pending
    /// Cue is `nil` when Light mode auto-confirmed rather than any cue firing.
    case confirmed(by: LivenessCue?)
    case denied(by: LivenessCue)

    var isConfirmed: Bool { if case .confirmed = self { return true }; return false }
    var isDenied: Bool { if case .denied = self { return true }; return false }

    /// User-facing explanation for a denial, matching the tone of the
    /// coordinator's other outcome strings.
    var denialReason: String? {
        guard case .denied(let cue) = self else { return nil }
        switch cue {
        case .glossGlare: return "Screen glare detected — this looks like a photo on a display."
        case .deviceDetected: return "A device-shaped rectangle was detected around the face — this looks like a photo or screen."
        default: return "Liveness check failed."
        }
    }
}

/// Running state for one cue across a scan.
struct LivenessCueState: Equatable {
    var reading: CueReading = .none
    /// Cumulative, not consecutive — forgiving of one-frame dropouts Vision produces mid-scan.
    var framesCounted: Int = 0
    var hasFired: Bool = false
    /// Best `normalizedEvidence` this cue has reached in the scan, latched like `hasFired`.
    /// Latched rather than instantaneous so a cue that briefly saw good evidence still
    /// counts toward Medium's sum after the head settles back to centre.
    var peakEvidence: Float = 0

    /// 0...1 progress toward firing, for Face Lab's progress bars.
    func progress(threshold: Int) -> Float {
        guard threshold > 0 else { return hasFired ? 1 : 0 }
        return min(1, Float(framesCounted) / Float(threshold))
    }
}

struct LivenessSnapshot: Equatable {
    let decision: LivenessDecision
    let mode: LivenessMode
    let cueStates: [LivenessCue: LivenessCueState]
    let frameCount: Int
    /// Medium's running total, surfaced for Face Lab. Meaningful in every mode —
    /// it is just not what Light or Heavy decide on.
    var confirmEvidenceTotal: Float = 0

    nonisolated static let empty = LivenessSnapshot(
        decision: .pending, mode: .light, cueStates: [:], frameCount: 0
    )

    func state(for cue: LivenessCue) -> LivenessCueState {
        cueStates[cue] ?? LivenessCueState()
    }
}

/// The stateful decision core, kept as a plain `struct` rather than folded
/// into `LivenessAnalyzer` so `tools/liveness_selftest.swift` can drive the
/// real firing/latching logic frame by frame with no actor or camera.
struct LivenessEvaluator {
    var mode: LivenessMode
    var tuning: LivenessTuning
    /// Face Lab can switch individual cues off to isolate one; the unlock
    /// path leaves this at "all enabled."
    var enabledCues: Set<LivenessCue>

    private(set) var states: [LivenessCue: LivenessCueState] = [:]
    private(set) var framesObserved: Int = 0

    init(
        mode: LivenessMode = .medium,
        tuning: LivenessTuning = .default,
        enabledCues: Set<LivenessCue> = Set(LivenessCue.allCases)
    ) {
        self.mode = mode
        self.tuning = tuning
        self.enabledCues = enabledCues
    }

    mutating func reset() {
        states = [:]
        framesObserved = 0
    }

    /// Firing is latched: a cue that has fired stays fired for the rest of the scan.
    mutating func observe(_ readings: [LivenessCue: CueReading]) -> LivenessSnapshot {
        framesObserved += 1

        for cue in LivenessCue.allCases {
            var state = states[cue] ?? LivenessCueState()
            let reading = readings[cue] ?? .none
            state.reading = reading
            if reading.confidence > 0 {
                state.peakEvidence = max(
                    state.peakEvidence, tuning.normalizedEvidence(for: cue, reading: reading)
                )
            }
            if reading.confidence > 0, reading.level >= tuning.level(for: cue) {
                state.framesCounted += 1
                if state.framesCounted >= tuning.frames(for: cue) {
                    state.hasFired = true
                }
            }
            states[cue] = state
        }

        return LivenessSnapshot(
            decision: currentDecision(), mode: mode, cueStates: states,
            frameCount: framesObserved, confirmEvidenceTotal: confirmEvidenceTotal
        )
    }

    /// Deny is evaluated first and is unconditional — it overrides any confirmation already reached.
    private func currentDecision() -> LivenessDecision {
        for cue in LivenessCue.allCases
        where cue.role == .deny && enabledCues.contains(cue) && (states[cue]?.hasFired ?? false) {
            return .denied(by: cue)
        }

        if mode == .light {
            return framesObserved >= tuning.lightModeMinimumFrames ? .confirmed(by: nil) : .pending
        }

        for cue in LivenessCue.allCases
        where cue.role == .confirm && enabledCues.contains(cue) && (states[cue]?.hasFired ?? false) {
            return .confirmed(by: cue)
        }

        if mode == .medium, framesObserved >= tuning.mediumModeMinimumFrames,
           confirmEvidenceTotal >= tuning.mediumConfirmScore {
            // Attributed to whichever cue contributed most, so Face Lab and the unlock
            // log name something useful rather than "the sum".
            return .confirmed(by: strongestConfirmCue)
        }

        return .pending
    }

    /// Summed latched evidence across the enabled confirm cues. Not capped at 1 —
    /// several cues each half-convinced is exactly the case Medium exists to pass.
    var confirmEvidenceTotal: Float {
        LivenessCue.allCases
            .filter { $0.role == .confirm && enabledCues.contains($0) }
            .reduce(0) { $0 + (states[$1]?.peakEvidence ?? 0) }
    }

    private var strongestConfirmCue: LivenessCue? {
        LivenessCue.allCases
            .filter { $0.role == .confirm && enabledCues.contains($0) }
            .max { (states[$0]?.peakEvidence ?? 0) < (states[$1]?.peakEvidence ?? 0) }
    }
}

/// Turns a rolling window into this frame's reading for every cue. Deny cues read only
/// the latest frame (per-frame appearance); confirm cues read the whole window (cross-frame motion).
nonisolated enum LivenessCues {
    nonisolated static func readings(
        window: [LivenessFrame], geometry: GeometryLivenessResult,
        minYawRangeDegrees: CGFloat = 12
    ) -> [LivenessCue: CueReading] {
        [
            .glossGlare: glossGlare(window.last),
            .deviceDetected: deviceDetected(window.last),
            .flatVs3D: geometry.planarReading,
            .depthPose: LivenessScoring.poseDepthConsistency(
                window, minYawRangeDegrees: minYawRangeDegrees
            ),
            .blink: LivenessScoring.blinkDynamics(window),
        ]
    }

    /// Skin gives many small scattered specular points; glass gives one big
    /// flat blob. `specularFraction` alone would fire on a bright forehead,
    /// so it's gated by how concentrated that glare is.
    nonisolated static func glossGlare(_ frame: LivenessFrame?) -> CueReading {
        guard let glare = frame?.glare else { return .none }
        let fractionScore = ramp(glare.specularFraction, floor: 0.01, ceiling: 0.08)
        let clusterFactor = ramp(glare.specularClusterRatio, floor: 0.3, ceiling: 1.0)
        let level = fractionScore * (0.3 + 0.7 * clusterFactor)
        // Below ~50 native px of face there isn't enough detail to tell a
        // glare blob from a bright patch; ramps to full trust by ~130px.
        let confidence = ramp(Float(glare.cropPixelWidth), floor: 50, ceiling: 130)
        return CueReading(level: level, confidence: confidence)
    }

    /// Raw overlap fraction from `DeviceBezelDetector`, used directly rather than re-scaled.
    nonisolated static func deviceDetected(_ frame: LivenessFrame?) -> CueReading {
        guard let overlap = frame?.deviceOverlapFraction else { return .none }
        return CueReading(level: Float(min(max(overlap, 0), 1)), confidence: 1)
    }

    nonisolated static func ramp(_ value: Float, floor: Float, ceiling: Float) -> Float {
        min(max((value - floor) / max(ceiling - floor, 0.0001), 0), 1)
    }
}
