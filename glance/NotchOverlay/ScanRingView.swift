//
//  ScanRingView.swift
//  Irys
//
//  A drawn scan indicator, replacing the pre-rendered video for the `.ring`
//  unlock style.
//
//  This exists because the video could not express the one thing the overlay
//  most needs to say: "still working." `ScanMedia` has exactly three cases —
//  idle, success, failure — and that is not an oversight, it is the shape a
//  clip forces. A clip has a fixed duration, so a failed attempt could only
//  play out and stop, which is why the old flow dead-ends on "hover the notch
//  to try again". A vector ring has no duration, so it can keep going.
//
//  Three rules from the interaction spec, and each is a deliberate choice
//  rather than a default:
//
//    1. The arc never resets to zero between attempts. Snapping back to the
//       start reads as "something crashed"; carrying the sweep across a retry
//       reads as "still looking".
//    2. Colour changes are slower than the events that cause them. A tint that
//       snaps on every state change reads as malfunctioning, however correct
//       it is. The colour transition here is deliberately ~2.4x the duration
//       of the geometry change.
//    3. Nothing flashes. The overlay can appear on the lock screen, and a
//       later feature modulates real screen brightness for liveness, so a
//       flashing idiom here would be a bad habit to establish. The maximum
//       rate of any change below is well under 3Hz (WCAG 2.3.1).
//

import SwiftUI

/// What the ring is saying, derived from the overlay's phase and media rather
/// than stored, so the controller's state machine is untouched.
enum ScanRingState: Equatable {
    /// Armed but not scanning. A slow breath, not a spinner — a spinner at
    /// rest implies work that is not happening.
    case dormant
    /// Actively looking for, or evaluating, a face.
    case searching
    case success
    /// A failed attempt. Deliberately not a terminal state: the ring keeps
    /// sweeping underneath the tint, because the app is about to try again.
    case failure

    init(phase: NotchOverlayController.Phase, media: ScanMedia) {
        switch (phase, media) {
        case (_, .success): self = .success
        case (_, .failure): self = .failure
        case (.scanning, _): self = .searching
        default: self = .dormant
        }
    }
}

struct ScanRingView: View {
    let state: ScanRingState

    /// Honour the system setting rather than inventing an app-level one. With
    /// reduced motion the ring still changes — it just does so by opacity and
    /// arc length instead of by continuous rotation.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives the continuous sweep. Kept as a plain angle rather than a
    /// repeating SwiftUI animation so a state change can adjust speed without
    /// the arc jumping — see rule 1 above.
    @State private var sweep: Angle = .zero
    @State private var breathe = false

    private var lineWidth: CGFloat { 3.5 }

    /// Fraction of the circle the moving arc covers.
    private var arcLength: CGFloat {
        switch state {
        case .dormant: return 0.14
        case .searching: return 0.30
        case .success: return 1.0
        case .failure: return 0.42
        }
    }

    /// Seconds per revolution. Failure sweeps slightly slower — the pace drop
    /// is what reads as "reconsidering" rather than "erroring".
    private var revolution: Double {
        switch state {
        case .dormant: return 6.0
        case .searching: return 1.5
        case .success: return 1.5
        case .failure: return 2.1
        }
    }

    private var tint: Color {
        switch state {
        case .dormant, .searching, .success:
            // Achromatic on purpose. Once the modulated-flash liveness probe
            // ships, any coloured light this view emits is light the camera
            // has to measure and discount. White keeps that problem simple.
            return .white
        case .failure:
            // Amber, not red. Red reads as "broken"; this is a retry, and the
            // app is still working.
            return Color(red: 1.0, green: 0.72, blue: 0.30)
        }
    }

    private var trackOpacity: Double { state == .success ? 0.0 : 0.16 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(trackOpacity), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: arcLength)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(sweep)
                // Geometry settles quickly; see rule 2 for why the colour does not.
                .animation(.easeInOut(duration: 0.26), value: arcLength)
                .animation(.easeInOut(duration: 0.62), value: tint)

            if state == .success {
                Checkmark()
                    .trim(from: 0, to: 1)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    .frame(width: 26, height: 26)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .opacity(state == .dormant && !reduceMotion ? (breathe ? 0.85 : 0.45) : 1)
        .animation(.easeInOut(duration: 0.45), value: state)
        .task(id: state) { await run() }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch state {
        case .dormant: return "Face unlock ready"
        case .searching: return "Looking for your face"
        case .success: return "Recognized"
        case .failure: return "Not recognized, trying again"
        }
    }

    /// Advances the sweep by hand rather than with `.repeatForever`.
    ///
    /// A repeating animation restarts from its own beginning whenever the view
    /// re-renders with a new state, which is exactly the reset-to-zero that
    /// rule 1 forbids. Driving the angle means a change of pace is continuous:
    /// the arc is wherever it was, and simply starts moving at a new speed.
    private func run() async {
        guard !reduceMotion else {
            // No rotation under reduced motion, but the arc length and tint
            // still carry the state, so nothing is lost but the spin.
            breathe = false
            return
        }
        if state == .dormant {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                breathe = true
            }
        } else {
            breathe = false
        }

        let tick: Duration = .milliseconds(16)
        while !Task.isCancelled {
            withAnimation(.linear(duration: 0.016)) {
                sweep += .degrees(360.0 * 0.016 / revolution)
            }
            try? await Task.sleep(for: tick)
        }
    }
}

/// Drawn rather than an SF Symbol so its stroke weight matches the ring's
/// exactly; `checkmark` at this size sits visibly lighter beside a 3.5pt arc.
private struct Checkmark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.midY + rect.height * 0.02))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.midY + rect.height * 0.26))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.86, y: rect.midY - rect.height * 0.26))
        return path
    }
}
