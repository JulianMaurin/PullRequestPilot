import SwiftUI

struct ContentView: View {
    let viewModel: ReviewQueueViewModel

    var body: some View {
        NavigationStack {
            ReviewQueueView(viewModel: viewModel)
                .navigationTitle("Review Queue")
        }
    }
}
