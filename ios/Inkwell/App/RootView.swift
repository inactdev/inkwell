import SwiftUI

struct RootView: View {
    @State private var store = InklingStore()
    @State private var showingList = false

    private var unsyncedCount: Int {
        store.inklings.filter { !$0.isSynced }.count
    }

    var body: some View {
        CaptureView(store: store, unsyncedCount: unsyncedCount) {
            showingList = true
        }
        .sheet(isPresented: $showingList) {
            store.reload()
        } content: {
            ListView(store: store)
        }
    }
}

#Preview {
    RootView()
}
