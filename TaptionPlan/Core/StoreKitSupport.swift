import Foundation
import StoreKit

enum TaptionCommercePolicy {
    static let isAdSupportedFreeMode = true
    static let supportsPaidPurchase = false
    static let proProductID = "com.taption.plan.pro"

    static func grantsProAccess(
        productID: String,
        revocationDate: Date?
    ) -> Bool {
        productID == proProductID && revocationDate == nil
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

enum StorePurchaseError: LocalizedError {
    case productUnavailable
    case unverifiedTransaction

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            "App Store에서 구매 항목을 아직 불러오지 못했습니다."
        case .unverifiedTransaction:
            "구매 영수증을 확인하지 못했습니다."
        }
    }
}

actor StoreKitPurchaseService {
    private var proProduct: Product?

    func loadProProduct() async throws -> StoreProductPresentation? {
        if proProduct == nil {
            proProduct = try await Product.products(
                for: [TaptionCommercePolicy.proProductID]
            ).first
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
