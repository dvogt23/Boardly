import BoardlyKit
import SwiftUI

@main
struct BoardlyApp: App {
    @State private var profileStore = ProfileStore()
    /// Local-first cache + outbox, owned for the app's lifetime (see OfflineCoordinator).
    @State private var offline = OfflineCoordinator()
    @AppStorage(AppTheme.storageKey) private var appearanceRaw = AppTheme.system.rawValue

    init() {
        BoardlyFonts.register()
    }

    private var colorScheme: ColorScheme? {
        AppTheme(rawValue: appearanceRaw)?.colorScheme
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
                if CommandLine.arguments.contains("-mockCard") {
                    MockCardHarness()
                } else if CommandLine.arguments.contains("-mockBoard") {
                    MockBoardHarness()
                } else if CommandLine.arguments.contains("-mockProjects") {
                    MockProjectsHarness()
                } else if CommandLine.arguments.contains("-mockLogin") {
                    MockLoginHarness()
                } else if CommandLine.arguments.contains("-mockProjectDetail") {
                    MockProjectDetailHarness()
                } else if CommandLine.arguments.contains("-mockMembersSheet") {
                    MockMembersSheetHarness()
                } else if CommandLine.arguments.contains("-mockActivity") {
                    MockActivityHarness()
                } else if CommandLine.arguments.contains("-mockProfile") {
                    MockProfileHarness()
                } else if CommandLine.arguments.contains("-mockSearch") {
                    MockSearchHarness()
                } else if CommandLine.arguments.contains("-mockEditProject") {
                    MockEditProjectHarness()
                } else {
                    RootView()
                        .environment(profileStore)
                        .environment(offline)
                        .preferredColorScheme(colorScheme)
                }
            #else
                RootView()
                        .environment(profileStore)
                        .environment(offline)
                        .preferredColorScheme(colorScheme)
            #endif
        }
    }
}
