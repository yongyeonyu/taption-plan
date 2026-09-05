import Foundation
import Observation
import Security
import StoreKit

enum TaptionCommercePolicy {
    static let isAdSupportedFreeMode = false
    static let supportsPaidPurchase = true
    static let proProductID = "com.taption.plan.pro"
    static let trialDuration: TimeInterval = 14 * 24 * 60 * 60

    static func isSupportedProProductType(
        _ productType: Product.ProductType
    ) -> Bool {
        productType == .nonConsumable
    }

    static func grantsProAccess(
        productID: String,
        productType: Product.ProductType = .nonConsumable,
        revocationDate: Date?
    ) -> Bool {
        productID == proProductID
            && isSupportedProProductType(productType)
            && revocationDate == nil
    }
}

struct TaptionProTrialRecord: Equatable, Sendable {
    var startedAt: Date
    var lastObservedAt: Date
}

enum TaptionProAccessState: Equatable, Sendable {
    case loading
    case trialNotStarted
    case trial(expiresAt: Date, remainingDays: Int)
    case purchased
    case expired(expiresAt: Date)

    var grantsAccess: Bool {
        switch self {
        case .trial, .purchased:
            true
        case .loading, .trialNotStarted, .expired:
            false
        }
    }
}

enum TaptionProTrialPolicy {
    static func merged(
        _ records: [TaptionProTrialRecord]
    ) -> TaptionProTrialRecord? {
        guard let first = records.first else { return nil }
        return records.dropFirst().reduce(first) { current, next in
            TaptionProTrialRecord(
                startedAt: min(current.startedAt, next.startedAt),
                lastObservedAt: max(
                    current.lastObservedAt,
                    next.lastObservedAt
                )
            )
        }
    }

    static func state(
        record: TaptionProTrialRecord?,
        now: Date
    ) -> TaptionProAccessState {
        guard let record else { return .trialNotStarted }
        let effectiveNow = max(now, record.lastObservedAt)
        let expiresAt = record.startedAt.addingTimeInterval(
            TaptionCommercePolicy.trialDuration
        )
        guard effectiveNow < expiresAt else {
            return .expired(expiresAt: expiresAt)
        }
        let remainingDays = max(
            1,
            Int(ceil(expiresAt.timeIntervalSince(effectiveNow) / 86_400))
        )
        return .trial(
            expiresAt: expiresAt,
            remainingDays: remainingDays
        )
    }
}

private enum TaptionProKeychainError: Error {
    case unexpectedData
    case status(OSStatus)
}

private struct TaptionProKeychain {
    private let service: String

    init(service: String = "com.taption.plan.pro-trial") {
        self.service = service
    }

    func date(for account: String) throws -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw TaptionProKeychainError.status(status)
        }
        guard let data = item as? Data,
              let rawValue = String(data: data, encoding: .utf8),
              let interval = TimeInterval(rawValue),
              interval.isFinite else {
            throw TaptionProKeychainError.unexpectedData
        }
        return Date(timeIntervalSince1970: interval)
    }

    func setDate(_ date: Date, for account: String) throws {
        let data = Data(
            String(date.timeIntervalSince1970).utf8
        )
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TaptionProKeychainError.status(updateStatus)
        }
        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TaptionProKeychainError.status(addStatus)
        }
    }
}

@MainActor
final class TaptionProTrialPersistence {
    private static let startedAtKey = "TaptionPlan.proTrial.startedAt"
    private static let lastObservedAtKey =
        "TaptionPlan.proTrial.lastObservedAt"
    private static let localStartedAtKey =
        "TaptionPlan.proTrial.local.startedAt"
    private static let localLastObservedAtKey =
        "TaptionPlan.proTrial.local.lastObservedAt"

    private let keychain: TaptionProKeychain?
    private let cloudStore: NSUbiquitousKeyValueStore?
    private let localStore: UserDefaults

    init(
        cloudStore: NSUbiquitousKeyValueStore? = NSUbiquitousKeyValueStore.default,
        localStore: UserDefaults = .standard,
        keychainService: String? = "com.taption.plan.pro-trial"
    ) {
        self.keychain = keychainService.map(TaptionProKeychain.init(service:))
        self.cloudStore = cloudStore
        self.localStore = localStore
    }

    func record(observedAt now: Date) -> TaptionProTrialRecord? {
        _ = cloudStore?.synchronize()
        let merged = TaptionProTrialPolicy.merged(
            [keychainRecord(), cloudRecord(), localRecord()].compactMap { $0 }
        )
        guard var merged else { return nil }
        merged.lastObservedAt = max(merged.lastObservedAt, now)
        persist(merged)
        return merged
    }

    func startTrial(at now: Date) -> TaptionProTrialRecord {
        if let existing = record(observedAt: now) {
            return existing
        }
        let record = TaptionProTrialRecord(
            startedAt: now,
            lastObservedAt: now
        )
        persist(record)
        return record
    }

    private func keychainRecord() -> TaptionProTrialRecord? {
        guard let keychain,
              let startedAt = try? keychain.date(
            for: Self.startedAtKey
        ) else {
            return nil
        }
        let lastObservedAt = try? keychain.date(
            for: Self.lastObservedAtKey
        )
        return TaptionProTrialRecord(
            startedAt: startedAt,
            lastObservedAt: max(lastObservedAt ?? startedAt, startedAt)
        )
    }

    private func cloudRecord() -> TaptionProTrialRecord? {
        guard let startedAt = cloudDate(for: Self.startedAtKey) else {
            return nil
        }
        return TaptionProTrialRecord(
            startedAt: startedAt,
            lastObservedAt: max(
                cloudDate(for: Self.lastObservedAtKey) ?? startedAt,
                startedAt
            )
        )
    }

    private func localRecord() -> TaptionProTrialRecord? {
        guard localStore.object(forKey: Self.localStartedAtKey) != nil else {
            return nil
        }
        let startedAt = localStore.double(forKey: Self.localStartedAtKey)
        let lastObservedAt = localStore.double(
            forKey: Self.localLastObservedAtKey
        )
        guard startedAt.isFinite, lastObservedAt.isFinite else {
            return nil
        }
        let started = Date(timeIntervalSince1970: startedAt)
        return TaptionProTrialRecord(
            startedAt: started,
            lastObservedAt: max(
                Date(timeIntervalSince1970: lastObservedAt),
                started
            )
        )
    }

    private func cloudDate(for key: String) -> Date? {
        guard let cloudStore,
              cloudStore.object(forKey: key) != nil else { return nil }
        let interval = cloudStore.double(forKey: key)
        guard interval.isFinite else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    private func persist(_ record: TaptionProTrialRecord) {
        if let cloudStore {
            cloudStore.set(
                record.startedAt.timeIntervalSince1970,
                forKey: Self.startedAtKey
            )
            cloudStore.set(
                record.lastObservedAt.timeIntervalSince1970,
                forKey: Self.lastObservedAtKey
            )
        }
        if let keychain {
            try? keychain.setDate(
                record.startedAt,
                for: Self.startedAtKey
            )
            try? keychain.setDate(
                record.lastObservedAt,
                for: Self.lastObservedAtKey
            )
        }
        localStore.set(
            record.startedAt.timeIntervalSince1970,
            forKey: Self.localStartedAtKey
        )
        localStore.set(
            record.lastObservedAt.timeIntervalSince1970,
            forKey: Self.localLastObservedAtKey
        )
    }
}

struct StoreProductPresentation: Equatable, Sendable {
    var id: String
    var displayName: String
    var description: String
    var displayPrice: String
}

enum StorePurchaseOutcome: Equatable, Sendable {
    case purchased
    case pending
    case cancelled
}

enum TaptionProMessageCode: Equatable, Sendable {
    case trialStarted
    case trialAlreadyUsed
    case purchaseCompleted
    case purchasePending
    case purchaseUnavailable
    case receiptVerificationFailed
    case purchaseFailed
    case restoreCompleted
    case restoreNotFound
    case restoreFailed
}

enum TaptionProMenuPresentation: Equatable, Sendable {
    case purchase
    case trial(remainingDays: Int)
    case purchased
}

enum StorePurchaseError: LocalizedError {
    case productUnavailable
    case unverifiedTransaction

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            String(localized: "App Store에서 구매 항목을 아직 불러오지 못했습니다.")
        case .unverifiedTransaction:
            String(localized: "구매 영수증을 확인하지 못했습니다.")
        }
    }
}

actor StoreKitPurchaseService {
    private var proProduct: Product?

    func loadProProduct() async throws -> StoreProductPresentation? {
        if proProduct == nil {
            proProduct = try await Product.products(
                for: [TaptionCommercePolicy.proProductID]
            ).first { product in
                product.id == TaptionCommercePolicy.proProductID
                    && TaptionCommercePolicy.isSupportedProProductType(
                        product.type
                    )
            }
        }
        guard let proProduct else { return nil }
        return StoreProductPresentation(
            id: proProduct.id,
            displayName: proProduct.displayName,
            description: proProduct.description,
            displayPrice: proProduct.displayPrice
        )
    }

    func hasProEntitlement() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                continue
            }
            if TaptionCommercePolicy.grantsProAccess(
                productID: transaction.productID,
                productType: transaction.productType,
                revocationDate: transaction.revocationDate
            ) {
                return true
            }
        }
        return false
    }

    func purchasePro() async throws -> StorePurchaseOutcome {
        if proProduct == nil {
            _ = try await loadProProduct()
        }
        guard let proProduct else {
            throw StorePurchaseError.productUnavailable
        }

        switch try await proProduct.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification,
                  TaptionCommercePolicy.grantsProAccess(
                    productID: transaction.productID,
                    productType: transaction.productType,
                    revocationDate: transaction.revocationDate
                  ) else {
                throw StorePurchaseError.unverifiedTransaction
            }
            await transaction.finish()
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func restorePurchases() async throws -> Bool {
        try await AppStore.sync()
        return await hasProEntitlement()
    }
}

@MainActor
@Observable
final class TaptionProAccessController {
    private(set) var state: TaptionProAccessState = .loading
    private(set) var product: StoreProductPresentation?
    private(set) var isActionInFlight = false
    var message: TaptionProMessageCode?
    var isPurchaseSheetPresented = false

    @ObservationIgnored private let purchaseService: StoreKitPurchaseService
    @ObservationIgnored private let trialPersistence:
        TaptionProTrialPersistence
    @ObservationIgnored private var transactionUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var trialExpirationTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0

    init(
        purchaseService: StoreKitPurchaseService = StoreKitPurchaseService(),
        trialPersistence: TaptionProTrialPersistence? = nil,
        now: Date = .now
    ) {
        self.purchaseService = purchaseService
        let resolvedTrialPersistence =
            trialPersistence ?? TaptionProTrialPersistence()
        self.trialPersistence = resolvedTrialPersistence
        state = TaptionProTrialPolicy.state(
            record: resolvedTrialPersistence.record(observedAt: now),
            now: now
        )
    }

    var grantsAccess: Bool { state.grantsAccess }

    var hasPermanentAccess: Bool {
        state == .purchased
    }

    var menuPresentation: TaptionProMenuPresentation {
        switch state {
        case .purchased:
            .purchased
        case .trial(_, let remainingDays):
            .trial(remainingDays: remainingDays)
        case .loading, .trialNotStarted, .expired:
            .purchase
        }
    }

    static func currentAccessGranted(now: Date = .now) async -> Bool {
        if await StoreKitPurchaseService().hasProEntitlement() {
            return true
        }
        let persistence = TaptionProTrialPersistence()
        let record = persistence.record(observedAt: now)
        return TaptionProTrialPolicy.state(
            record: record,
            now: now
        ).grantsAccess
    }

    func refreshAccess(now: Date = .now) async {
        startTransactionUpdatesIfNeeded()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let hasEntitlement = await purchaseService.hasProEntitlement()
        guard generation == refreshGeneration else { return }
        if hasEntitlement {
            setState(.purchased)
        } else {
            let record = trialPersistence.record(observedAt: now)
            setState(TaptionProTrialPolicy.state(record: record, now: now))
        }
    }

    func loadProductIfNeeded() async {
        if product == nil {
            product = try? await purchaseService.loadProProduct()
        }
    }

    func refresh(now: Date = .now) async {
        await refreshAccess(now: now)
        await loadProductIfNeeded()
    }

    func startTrial(now: Date = .now) {
        guard !isActionInFlight, state == .trialNotStarted else { return }
        isActionInFlight = true
        let record = trialPersistence.startTrial(at: now)
        setState(TaptionProTrialPolicy.state(record: record, now: now))
        switch state {
        case .trial:
            message = .trialStarted
        case .expired:
            message = .trialAlreadyUsed
        case .loading, .trialNotStarted, .purchased:
            break
        }
        isActionInFlight = false
    }

    func purchase() async {
        guard !isActionInFlight else { return }
        isActionInFlight = true
        defer { isActionInFlight = false }
        do {
            switch try await purchaseService.purchasePro() {
            case .purchased:
                await refresh()
                message = .purchaseCompleted
                isPurchaseSheetPresented = false
            case .pending:
                message = .purchasePending
            case .cancelled:
                break
            }
        } catch StorePurchaseError.productUnavailable {
            message = .purchaseUnavailable
        } catch StorePurchaseError.unverifiedTransaction {
            message = .receiptVerificationFailed
        } catch {
            message = .purchaseFailed
        }
    }

    func restore() async {
        guard !isActionInFlight else { return }
        isActionInFlight = true
        defer { isActionInFlight = false }
        do {
            if try await purchaseService.restorePurchases() {
                await refresh()
                message = .restoreCompleted
                isPurchaseSheetPresented = false
            } else {
                message = .restoreNotFound
            }
        } catch {
            message = .restoreFailed
        }
    }

    private func startTransactionUpdatesIfNeeded() {
        guard transactionUpdatesTask == nil else { return }
        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                if case .verified(let transaction) = result,
                   transaction.productID == TaptionCommercePolicy.proProductID,
                   TaptionCommercePolicy.isSupportedProProductType(
                       transaction.productType
                   ) {
                    await transaction.finish()
                }
                await self?.refresh()
            }
        }
    }

    private func setState(_ newState: TaptionProAccessState) {
        state = newState
        trialExpirationTask?.cancel()
        trialExpirationTask = nil
        guard case .trial(let expiresAt, _) = newState else { return }
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        let nanoseconds = UInt64(
            min(delay, Double(UInt64.max) / 1_000_000_000)
                * 1_000_000_000
        )
        trialExpirationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            await self?.refresh()
        }
    }
}
