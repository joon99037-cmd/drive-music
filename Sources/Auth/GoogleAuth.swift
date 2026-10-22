import Foundation
import AuthenticationServices
import CryptoKit
import Observation
import Security
import UIKit

enum AuthError: LocalizedError {
    case notConfigured
    case notSignedIn
    case noCode
    case tokenFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "앱에 구글 클라이언트 ID가 아직 들어 있지 않아요."
        case .notSignedIn: return "구글 로그인이 필요해요."
        case .noCode: return "구글 로그인 응답이 올바르지 않아요."
        case .tokenFailed(let body): return "구글 인증 실패: \(body)"
        }
    }
}

private struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
}

/// 구글 OAuth (PKCE, 클라이언트 비밀 없이). 갱신 토큰은 키체인에 저장
@MainActor @Observable
final class GoogleAuth {
    private(set) var isSignedIn: Bool

    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var expiry = Date.distantPast
    @ObservationIgnored private var refreshTask: Task<String, Error>?
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    @ObservationIgnored private let presenter = AuthPresenter()

    init() {
        isSignedIn = Keychain.get("refresh_token") != nil
    }

    func signIn() async throws {
        guard Config.isConfigured else { throw AuthError.notConfigured }
        let verifier = Self.randomString()
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: Config.clientID),
            URLQueryItem(name: "redirect_uri", value: Config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Config.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        let authURL = comps.url!

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: authURL, callbackURLScheme: Config.redirectScheme) { url, error in
                if let url {
                    cont.resume(returning: url)
                } else {
                    cont.resume(throwing: error ?? AuthError.noCode)
                }
            }
            s.presentationContextProvider = presenter
            s.prefersEphemeralWebBrowserSession = false
            session = s
            s.start()
        }
        session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw AuthError.noCode }

        let token = try await Self.tokenRequest([
            "code": code,
            "client_id": Config.clientID,
            "redirect_uri": Config.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refresh = token.refresh_token else { throw AuthError.tokenFailed("갱신 토큰이 오지 않았어요") }
        Keychain.set(refresh, for: "refresh_token")
        accessToken = token.access_token
        expiry = Date().addingTimeInterval(TimeInterval(token.expires_in))
        isSignedIn = true
    }

    func signOut() {
        Keychain.set(nil, for: "refresh_token")
        accessToken = nil
        expiry = .distantPast
        isSignedIn = false
    }

    /// 유효한 접근 토큰. 만료가 가까우면 갱신 토큰으로 새로 받는다
    func validToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let token = accessToken, expiry.timeIntervalSinceNow > 60 {
            return token
        }
        if let running = refreshTask {
            return try await running.value
        }
        let task = Task { () throws -> String in
            defer { refreshTask = nil }
            guard let refresh = Keychain.get("refresh_token") else { throw AuthError.notSignedIn }
            do {
                let token = try await Self.tokenRequest([
                    "client_id": Config.clientID,
                    "refresh_token": refresh,
                    "grant_type": "refresh_token",
                ])
                accessToken = token.access_token
                expiry = Date().addingTimeInterval(TimeInterval(token.expires_in))
                return token.access_token
            } catch AuthError.tokenFailed(let body) where body.contains("invalid_grant") {
                // 권한이 취소됐거나 만료됨 → 다시 로그인
                signOut()
                throw AuthError.notSignedIn
            }
        }
        refreshTask = task
        return try await task.value
    }

    private nonisolated static func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.tokenFailed(String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private nonisolated static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private nonisolated static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    private nonisolated static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first ?? ASPresentationAnchor()
    }
}

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "drivemusic",
            kSecAttrAccount as String: key,
        ]
    }

    static func set(_ value: String?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var add = query(key)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
