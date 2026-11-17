import SwiftUI

struct NativeModPreviewView: View {
    @ObservedObject var model: Model
    let review: NativeModPackages.Review
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review original mods").font(.title2)
            ScrollView { Text(review.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            if model.busy { ProgressView(model.busyDetail) }
            HStack {
                Button("Cancel") { model.cancelNativeModImport() }.disabled(model.busy)
                Spacer()
                Button("Install") { model.confirmNativeModImport(review) }.keyboardShortcut(.defaultAction).disabled(model.busy || model.gameIsRunning)
            }
        }
        .padding(24).frame(width: 600, height: 470)
        .interactiveDismissDisabled(model.busy)
    }
}
