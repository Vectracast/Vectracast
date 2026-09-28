import Foundation

enum SettingsSizing {
    static let width: CGFloat = 1000
    static let headerHeight: CGFloat = 80
    static let maximumHeight: CGFloat = 650
    static let standardHeight: CGFloat = 648
    static func height(forPage page: String, body: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let desired = page == "about" ? max(300, headerHeight + body) : standardHeight
        return min(maximumHeight, max(1, availableHeight - 40), desired)
    }
}
