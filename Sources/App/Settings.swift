import Foundation
import Observation

@MainActor @Observable
final class Settings {
    /// 지금 곡 다음으로 미리 받아 둘 곡 수
    var prefetchCount: Int { didSet { defaults.set(prefetchCount, forKey: "prefetchCount") } }
    /// 오프라인 저장하지 않은 곡의 저장 한도 (GB, 0 = 무제한)
    var cacheLimitGB: Double { didSet { defaults.set(cacheLimitGB, forKey: "cacheLimitGB") } }
    /// 모든 곡을 폰에 저장
    var offlineAll: Bool { didSet { defaults.set(offlineAll, forKey: "offlineAll") } }
    /// 셀룰러에서도 오프라인 저장 진행
    var offlineOnCellular: Bool { didSet { defaults.set(offlineOnCellular, forKey: "offlineOnCellular") } }
    /// 셀룰러에서도 곡 정보(태그·표지) 읽기
    var scanOnCellular: Bool { didSet { defaults.set(scanOnCellular, forKey: "scanOnCellular") } }

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        prefetchCount = d.object(forKey: "prefetchCount") as? Int ?? 3
        cacheLimitGB = d.object(forKey: "cacheLimitGB") as? Double ?? 2
        offlineAll = d.object(forKey: "offlineAll") as? Bool ?? false
        offlineOnCellular = d.object(forKey: "offlineOnCellular") as? Bool ?? false
        scanOnCellular = d.object(forKey: "scanOnCellular") as? Bool ?? false
    }

    var cacheLimitBytes: Int64? {
        cacheLimitGB <= 0 ? nil : Int64(cacheLimitGB * 1_000_000_000)
    }
}
