//
//  OnboardingNotchView.swift
//  glance
//
//  Routes `controller.step` to its screen and applies the scroll-with-blur transition
//  between them: Next travels upward, Back is the mirror, travelling downward.
//

import SwiftUI
import AppKit

struct OnboardingNotchView: View {
    let controller: OnboardingController

    var body: some View {
        ZStack {
            switch controller.step {
            case .intro:
                IntroStepView(controller: controller)
            case .permissions:
                PermissionsStepView(controller: controller)
            case .securityNotice:
                SecurityNoticeStepView(controller: controller)
            case .preSetup:
                PreSetupStepView(controller: controller)
            case .selectCamera:
                SelectCameraStepView(controller: controller)
            case .enroll:
                EnrollStepView(controller: controller)
            case .name:
                NameStepView(controller: controller)
            case .password:
                PasswordStepView(controller: controller)
            case .complete:
                CompleteStepView()
            }
        }
        .id(controller.step)
        .frame(width: controller.panelSize.width, height: controller.panelSize.height)
        .transition(stepTransition)
        // A way out, on every step.
        //
        // Onboarding previously had no exit at all: the panel is a non-activating
        // notch window, so it takes no key events and Cmd-Q never reaches it, and
        // the flow itself only moves forward. Someone who opened the app to look at
        // it was stuck with a panel they could not dismiss. The menu bar Quit does
        // work, but expecting a user mid-setup to go hunting for it is not an
        // answer.
        //
        // Outside the ZStack's `.id(step)` so it does not get torn down and
        // re-inserted by the step transition on every screen change.
        .overlay(alignment: .topTrailing) { quitButton }
    }

    @ViewBuilder
    private var quitButton: some View {
        // Hidden on the final screen: at that point the flow dismisses itself, and
        // a quit control next to "Done" invites the wrong click.
        if controller.step != .complete {
            OnboardingQuitButton()
                .padding(.top, 8)
                .padding(.trailing, 10)
        }
    }

    private var stepTransition: AnyTransition {
        let travel = controller.panelSize.height
        let insertionOffset: CGFloat = controller.navDirection == .forward ? travel : -travel
        let removalOffset: CGFloat = controller.navDirection == .forward ? -travel : travel
        return .asymmetric(
            insertion: .modifier(
                active: OffsetBlurOpacity(offset: insertionOffset, blur: 12, opacity: 0),
                identity: OffsetBlurOpacity(offset: 0, blur: 0, opacity: 1)
            ),
            removal: .modifier(
                active: OffsetBlurOpacity(offset: removalOffset, blur: 12, opacity: 0),
                identity: OffsetBlurOpacity(offset: 0, blur: 0, opacity: 1)
            )
        )
    }
}

/// Backing modifier for the scroll+blur transition — offsets, blurs, and fades at once
/// so content reads as scrolling past with a dissolve rather than a hard cut.
private struct OffsetBlurOpacity: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

/// Small dismiss control for the onboarding panel.
///
/// Quits rather than hiding. Onboarding is not optional — the app cannot unlock
/// anything until it has a face and a password — so a control that merely hid
/// the panel would leave a running app in a state with no way back into setup
/// except quitting anyway. Being honest about that is better than a dismiss that
/// strands the user.
private struct OnboardingQuitButton: View {
    @State private var isHovering = false

    var body: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovering ? Color.white.opacity(0.95) : Color.white.opacity(0.42))
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(Color.white.opacity(isHovering ? 0.16 : 0.07))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .help("Quit Irys")
        .accessibilityLabel("Quit Irys")
    }
}
