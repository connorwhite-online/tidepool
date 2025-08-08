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
    @State private var selection: Int = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if selection == 0 { MapHomeView() } else { ProfileView() }
            }
            .ignoresSafeArea()

            FloatingTabBar(selection: $selection)
                .padding(.bottom, 20)
        }
        .fontDesign(.rounded)
    }
}

struct FloatingTabBar: View {
    @Binding var selection: Int

    private let iconSize: CGFloat = 24

    var body: some View {
        HStack(spacing: 28) {
            tabButton(index: 0, systemName: "map.fill")
            tabButton(index: 1, systemName: "person.circle.fill")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 12, x: 0, y: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func tabButton(index: Int, systemName: String) -> some View {
        Button(action: { selection = index }) {
            if selection == index {
                RadialGradient(gradient: Gradient(colors: [Color(hex: "#9CE3A3")!, Color(hex: "#A6E4F8")!]), center: .center, startRadius: 0, endRadius: 16)
                    .mask(
                        Image(systemName: systemName)
                            .resizable()
                            .scaledToFit()
                    )
                    .frame(width: iconSize, height: iconSize)
            } else {
                Image(systemName: systemName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .frame(width: iconSize, height: iconSize)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .frame(width: 44, height: 44)
    }

    private var backgroundView: some View {
        ZStack {
            // Blur/translucency
            VisualEffectBlur(blurStyle: .systemThinMaterialDark)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            // Subtle vertical gradient (darker bottom to lighter top)
            LinearGradient(
                colors: [Color.black.opacity(0.18), Color.white.opacity(0.08)],
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
