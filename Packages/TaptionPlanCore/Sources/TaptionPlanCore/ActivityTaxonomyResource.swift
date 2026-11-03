import Foundation

/// 대분류·상세분류 표(v4) 원본 JSON 하나. 앱·위젯·분류 엔진이 모두 이 바이트를 읽는다.
public enum ActivityTaxonomyResource {
    public static let data: Data? = Bundle.module
        .url(forResource: "record-classification", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
}
