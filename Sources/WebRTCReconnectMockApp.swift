import SwiftUI

@main
struct WebRTCReconnectMockApp: App {
    @StateObject private var statusLog: StatusLog
    @StateObject private var webRTCClient: WebRTCClient

    init() {
        let log = StatusLog()
        _statusLog = StateObject(wrappedValue: log)
        _webRTCClient = StateObject(wrappedValue: WebRTCClient(log: log))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(webRTCClient)
                .environmentObject(statusLog)
        }
    }
}
