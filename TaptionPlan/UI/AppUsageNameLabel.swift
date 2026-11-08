import SwiftUI

#if canImport(FamilyControls) && canImport(ManagedSettings)
import FamilyControls
import ManagedSettings
#endif

/// 스크린 타임은 앱 이름 문자열을 늘 주지는 않는다. 토큰이 남아 있으면
/// 시스템이 그리는 실제 앱 이름·아이콘으로 채우고, 없으면 아무것도 그리지
/// 않아 기록 제목만 남긴다.
struct AppUsageNameLabel: View {
    let tokenData: Data?
    var size: CGFloat = 13
    var tint: Color = .tpInk

    init(tokenData: Data?, size: CGFloat = 13, tint: Color = .tpInk) {
        self.tokenData = tokenData
        self.size = size
        self.tint = tint
    }

    init(
        record: ActualRecord,
        tokenIndex: [UUID: Data],
        size: CGFloat = 13,
        tint: Color = .tpInk
    ) {
        self.init(tokenData: tokenIndex[record.id], size: size, tint: tint)
    }

    /// 토큰을 실제로 그릴 수 있을 때만 true. 그릴 수 없으면 호출부가
    /// 문자열 제목으로 되돌아간다.
    static func canRender(_ tokenData: Data?) -> Bool {
#if canImport(FamilyControls) && canImport(ManagedSettings)
        ApplicationTokenCache.token(for: tokenData) != nil
#else
        false
#endif
    }

    var body: some View {
#if canImport(FamilyControls) && canImport(ManagedSettings)
        if let token = ApplicationTokenCache.token(for: tokenData) {
            Label(token)
                .labelStyle(.titleAndIcon)
                .font(.taption(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
#endif
    }
}

#if canImport(FamilyControls) && canImport(ManagedSettings)
/// 시간표 막대는 드래그 중에도 다시 그려진다. 토큰을 매번 디코딩하면
/// 프레임 예산을 갉아먹으므로 한 번만 풀고 메모리에만 들고 있는다.
@MainActor
enum ApplicationTokenCache {
    private static var decoded: [Data: ApplicationToken] = [:]

    static func token(for data: Data?) -> ApplicationToken? {
        guard let data else { return nil }
        if let cached = decoded[data] { return cached }
        guard let token = try? JSONDecoder().decode(
            ApplicationToken.self,
            from: data
        ) else {
            return nil
        }
        if decoded.count >= 256 { decoded.removeAll() }
        decoded[data] = token
        return token
    }
}
#endif
