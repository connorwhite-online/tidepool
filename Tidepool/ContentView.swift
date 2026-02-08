//
//  ContentView.swift
//  Tidepool
//
//  Created by Connor White on 8/7/25.
//

import SwiftUI
import MapKit
import UIKit

struct ContentView: View {
    @AppStorage("has_onboarded") private var hasOnboarded: Bool = false
    @State private var showOnboarding: Bool = false
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack(alignment: .bottomTrailing) {
                MapHomeView()
                    .ignoresSafeArea()

                LayersButton {
                    navigationPath.append("layers")
                }
                .padding(.trailing, 20)
                .padding(.bottom, 20)
            }
            .navigationBarHidden(true)
            .navigationDestination(for: String.self) { destination in
                if destination == "layers" {
                    ProfileView()
                        .navigationBarBackButtonHidden(true)
                }
            }
        }
        .fontDesign(.rounded)
        .onAppear { showOnboarding = !hasOnboarded }
        .onChange(of: hasOnboarded) { _, newValue in
            showOnboarding = !newValue
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
    }
}

struct LayersButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private let iconSize: CGFloat = 28
    private let cornerRadius: CGFloat = 20

    var body: some View {
        Button(action: {
            HapticFeedbackManager.shared.impact(.light)
            action()
        }) {
            Image(systemName: "square.stack.3d.down.right.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(colorScheme == .dark ? .white : .black)
                .frame(width: iconSize, height: iconSize)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .frame(width: 44, height: 44)
        .padding(.leading, 22)
        .padding(.trailing, 22)
        .padding(.vertical, 12)
        .background(backgroundView)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: cornerRadius,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.1 : 0.06), radius: 12, x: 0, y: 8)
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: cornerRadius,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .strokeBorder((colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)), lineWidth: 1)
        )
    }

    private var backgroundView: some View {
        ZStack {
            // Blur/translucency adaptive to color scheme
            VisualEffectBlur(blurStyle: colorScheme == .dark ? .systemMaterialDark : .systemThinMaterialLight)
            // Subtle vertical gradient (tuned per scheme)
            LinearGradient(
                colors: colorScheme == .dark
                ? [Color.black.opacity(0.28), Color.black.opacity(0.16)]
                : [Color.black.opacity(0.06), Color.white.opacity(0.10)],
                startPoint: .bottom,
                endPoint: .top
            )
        }
    }
}

struct VisualEffectBlur: UIViewRepresentable {
    var blurStyle: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

#Preview {
    ContentView()
}
