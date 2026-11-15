// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct Hello: View {
    @EnvironmentObject var pane: RexPaneState
    @State private var clicks = 0
    @State private var text = ""
    @State private var spin = false
    @State private var picked: Int?

    var body: some View {
        HStack(spacing: 0) {
            List(0..<40, id: \.self, selection: $picked) { i in
                Label("Row \(i)", systemImage: i % 3 == 0 ? "star" : "circle")
            }
            .frame(width: 180)
            VStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 44))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 4).repeatForever(autoreverses: false), value: spin)
                Text("Hello from a native pane").font(.title2.bold())
                Text(pane.focused ? "focused" : "not focused").foregroundStyle(.secondary)
                Button("Clicked \(clicks)") { clicks += 1 }
                TextField("Type here", text: $text).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                if !text.isEmpty { Text("“\(text)”") }
                if let picked { Text("Picked row \(picked)").foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { spin = true }
    }
}

RexPane.run(name: "hello") { Hello() }
