import SwiftUI

@main
struct PhotoCleanerApp: App {
    @StateObject private var scanner = Scanner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scanner)
        }
    }
}
