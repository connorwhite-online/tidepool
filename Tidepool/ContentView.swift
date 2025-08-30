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
    @State private var showLayers: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MapHomeView()
                .ignoresSafeArea()

            LayersButton(showLayers: $showLayers)
                .padding(.trailing, 20)
                .padding(.bottom, 20)
        }
        .fontDesign(.rounded)
        .onAppear { showOnboarding = !hasOnboarded }
        .onChange(of: hasOnboarded) { _, newValue in
            showOnboarding = !newValue
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .sheet(isPresented: $showLayers) {
            ProfileView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }
}

struct LayersButton: View {
    @Binding var showLayers: Bool
    @Environment(\.colorScheme) private var colorScheme

    private let iconSize: CGFloat = 28

    var body: some View {
        Button(action: { 
            HapticFeedbackManager.shared.impact(.light)
            showLayers = true 
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
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.1 : 0.06), radius: 12, x: 0, y: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder((colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)), lineWidth: 1)
        )
    }

    private var backgroundView: some View {
        ZStack {
            // Blur/translucency adaptive to color scheme
            VisualEffectBlur(blurStyle: colorScheme == .dark ? .systemMaterialDark : .systemThinMaterialLight)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            // Subtle vertical gradient (tuned per scheme)
            LinearGradient(
                colors: colorScheme == .dark
                ? [Color.black.opacity(0.28), Color.black.opacity(0.16)]
                : [Color.black.opacity(0.06), Color.white.opacity(0.10)],
                startPoint: .bottom,
                endPoint: .top
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
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
