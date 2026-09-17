//
//  IrysMarkView.swift
//  Irys
//
//  The brand mark, drawn.
//
//  Replaces `logoanimation.mp4`, which was the previous app's logo — a blue
//  rounded square with a smiley face — and was still playing on the first
//  onboarding screen under the name "Irys". That is the most visible piece of
//  inherited art in the product, and no amount of renaming elsewhere fixes a
//  screen that literally shows someone else's logo.
//
//  Drawn rather than re-exported as a video for the same reasons the rest of
//  this app is moving away from clips: it scales to any size, it costs no
//  decode, it can respond to reduce-motion, and it can be recoloured in one
//  place instead of re-rendered.
//
//  The mark itself is two rings that ought to be concentric and are not. The
//  offset is the idea rather than decoration: depth moves a real face's
//  features off-axis as the head turns, and a flat photograph's do not, which
//  is the cue the whole liveness check is built on. Here the inner ring drifts
//  slowly around that offset, so the parallax is something you watch happen.
//

import SwiftUI

struct IrysMarkView: View {
    /// Edge length of the rounded tile.
    var size: CGFloat = 120

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Double = 0

    // Proportions, so the mark is identical at any size.
    private var outerRadius: CGFloat { size * 0.293 }
    private var innerRadius: CGFloat { size * 0.168 }
    private var strokeWidth: CGFloat { size * 0.040 }
    /// How far the inner ring sits off-centre at rest.
    private var offset: CGFloat { size * 0.055 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.455, green: 0.510, blue: 1.0),
                                 Color(red: 0.180, green: 0.200, blue: 0.478)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            // Where the iris should be. Quiet, so the displaced ring reads as
            // the thing that moved.
            Circle()
                .stroke(Color.white.opacity(0.42), lineWidth: strokeWidth)
                .frame(width: outerRadius * 2, height: outerRadius * 2)

            // Displaced, and catching light from a single upper-right source —
            // the gradient is what makes the offset read as depth rather than
            // as a mistake.
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [.white, Color.white.opacity(0.28)],
                        startPoint: .topTrailing, endPoint: .bottomLeading
                    ),
                    lineWidth: strokeWidth
                )
                .frame(width: innerRadius * 2, height: innerRadius * 2)
                .offset(
                    x: offset * cos(phase) * 0.6 + offset * 0.7,
                    y: offset * sin(phase) * 0.6 - offset * 0.5
                )
        }
        .frame(width: size, height: size)
        .task {
            guard !reduceMotion else { return }
            // Hand-advanced rather than `.repeatForever`, so the drift is a
            // continuous orbit instead of a loop that visibly restarts.
            while !Task.isCancelled {
                withAnimation(.linear(duration: 0.032)) { phase += 0.032 * 0.55 }
                try? await Task.sleep(for: .milliseconds(32))
            }
        }
        .accessibilityHidden(true)
    }
}
