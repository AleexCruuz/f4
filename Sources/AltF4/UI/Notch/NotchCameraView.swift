// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The mirror, filling the island. It starts the moment the page shows and
/// stops when the page goes, so opening the page is the whole gesture.
struct NotchCameraView: View {
    let size: CGSize
    @ObservedObject private var service = CameraPreviewService.shared

    var body: some View {
        CameraPreviewView(size: size, showsCameraMenu: true, cornerRadius: 0)
            .onAppear { service.showEmbedded() }
            .onDisappear { service.hideEmbedded() }
    }
}
