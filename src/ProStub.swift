// Free build: AkiGuard Pro adds battery health, heat protection and a one-click signed installer.
// Get it at https://wildan17.gumroad.com/l/akiguard — buying Pro supports development of AkiGuard.
import Cocoa

enum Pro {
    static let buyURL = "https://wildan17.gumroad.com/l/akiguard"
    static func startBackgroundCheck() {}
    static func addMenuItems(_ menu: NSMenu, config: Config, status s: [String: String],
                             update: @escaping ((Config) -> Void) -> Void) {
        menu.addItem(ActionItem("★ Get AkiGuard Pro (battery health, heat protection)…") {
            NSWorkspace.shared.open(URL(string: Pro.buyURL)!)
        })
    }
}
