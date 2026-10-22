import Foundation

enum Config {
    /// 구글 클라우드 콘솔에서 만든 iOS 클라이언트 ID
    static let clientID = "884224606179-3ie8ig9o2p9ptrbs9dshahpf38tj899j.apps.googleusercontent.com"

    static var isConfigured: Bool { !clientID.hasPrefix("PASTE") }

    /// 클라이언트 ID를 뒤집은 형태 (com.googleusercontent.apps.xxxx)
    static var redirectScheme: String {
        clientID.components(separatedBy: ".").reversed().joined(separator: ".")
    }

    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    static let scope = "https://www.googleapis.com/auth/drive.readonly"
}
