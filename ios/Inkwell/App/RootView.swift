import SwiftUI

struct RootView: View {
    @State private var store = InklingStore()
    @State private var syncCoordinator: SyncCoordinator?
    @State private var showingList = false
    @Environment(\.scenePhase) private var scenePhase

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
        .task {
            let coordinator = SyncCoordinator(store: store)
            syncCoordinator = coordinator
            coordinator.start()
        }
        .onChange(of: store.inklings.count) {
            Task { await syncCoordinator?.syncAll() }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task { await syncCoordinator?.syncAll() }
            }
        }
    }
}

#Preview {
    RootView()
}
