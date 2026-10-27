import SwiftUI

@main
struct ProbeApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "archivebox")
                    .font(.system(size: 42, weight: .light))
                Text("SwiftUI 编译链路正常")
                    .font(.system(size: 15, weight: .medium))
            }
            .frame(width: 420, height: 260)
        }
    }
}
