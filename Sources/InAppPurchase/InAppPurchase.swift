import StoreKit
import SwiftGodot

#initSwiftExtension(
	cdecl: "swift_entry_point",
	types: [
		InAppPurchase.self,
		IAPProduct.self,
	]
)

public enum StoreError: Error {
	case failedVerification
}

let OK: Int = 0

@Godot
class InAppPurchase: RefCounted {
	enum InAppPurchaseStatus: Int {
		case purchaseOK = 0
		case purchaseSuccessfulButUnverified = 2
		case purchasePendingAuthorization = 3
		case purchaseCancelledByUser = 4
	}
	enum InAppPurchaseError: Int, Error {
		case failedToGetProducts = 1
		case purchaseFailed = 2
		case noSuchProduct = 3
		case failedToRestorePurchases = 4
	}
	enum AppTransactionError: Int, Error {
		case ok = 0
		case unverified = 1
		case error = 2
	}

	/// Called when a product is purchased — (productID: String, jwsRepresentation: String, transactionId: String, originalTransactionId: String)
	@Signal var productPurchased: SignalWithArguments<String, String, String, String>
	/// Called when a purchase is revoked — (productID: String, revocationDateMs: String, revocationReason: String, transactionId: String)
	@Signal var productRevoked: SignalWithArguments<String, String, String, String>

	private(set) var productIDs: [String] = []

	private(set) var products: [Product]
	private(set) var purchasedProducts: Set<String> = Set<String>()

	var updateListenerTask: Task<Void, Error>? = nil

	required init(_ context: InitContext) {
		products = []
		super.init(context)
	}

	deinit {
		updateListenerTask?.cancel()
	}

	/// Initialize purchases
	///
	/// - Parameters:
	/// 	- productIdentifiers: An array of product identifiers that you enter in App Store Connect.
	@Callable
	func initialize(productIDs: [String], onComplete: Callable) {
		self.productIDs = productIDs

		updateListenerTask = self.listenForTransactions()

		Task {
			await updateProducts()
			await updateProductStatus()

			onComplete.callDeferred()
		}
	}

	/// Purchase a product
	///
	/// - Parameters:
	/// 	- productID: The identifier of the product that you enter in App Store Connect.
	/// 	- onComplete: Callback with parameter: (error: Variant, status: Variant) -> (error: Int `InAppPurchaseError`, status: Int `InAppPurchaseStatus`)
	@Callable
	func purchase(_ productID: String, onComplete: Callable) {
		Task {
			do {
				if let product: Product = try await getProduct(productID) {
					let result: Product.PurchaseResult = try await product.purchase()
					switch result {
				case .success(let verification):
					// Success — extract JWS from VerificationResult before unwrapping
					let (transaction, jws, txId, origTxId) = try self.extractVerified(verification)
					await transaction.finish()

					self.purchasedProducts.insert(transaction.productID)

					self.productPurchased.emit(transaction.productID, jws, txId, origTxId)

						onComplete.callDeferred(
							Variant(OK),
							Variant(InAppPurchaseStatus.purchaseOK.rawValue)
						)
						break
					case .pending:
						// Transaction waiting on authentication or approval
						onComplete.callDeferred(
							Variant(OK),
							Variant(InAppPurchaseStatus.purchasePendingAuthorization.rawValue)
						)
						break
					case .userCancelled:
						// User cancelled the purchase
						onComplete.callDeferred(
							Variant(OK),
							Variant(InAppPurchaseStatus.purchaseCancelledByUser.rawValue)
						)
						break
					}
				} else {
					GD.pushError("IAP Product doesn't exist: \(productID)")
					onComplete.callDeferred(
						Variant(InAppPurchaseError.noSuchProduct.rawValue),
						nil
					)
				}
			} catch {
				GD.pushError("IAP Failed to get products from App Store, error: \(error)")
				onComplete.callDeferred(
					Variant(InAppPurchaseError.purchaseFailed.rawValue),
					nil
				)
			}
		}
	}

	/// Check if a product is purchased
	///
	/// - Parameters:
	/// 	- productID: The identifier of the product that you enter in App Store Connect.,
	///
	/// - Returns: True if a product is purchased
	@Callable(autoSnakeCase: true)
	func isPurchased(_ productID: String) -> Bool {
		return purchasedProducts.contains(productID)
	}

	/// Get display info for a single product.
	///
	/// - Parameters:
	/// 	- productID: The product identifier.
	/// 	- onComplete: Callback with parameters: (error: Variant, info: Variant) -> (error: Int, info: Dictionary)
	@Callable(autoSnakeCase: true)
	func getProductInfo(productID: String, onComplete: Callable) {
		Task {
			do {
				let storeProducts = try await Product.products(for: [productID])
				guard let storeProduct = storeProducts.first else {
					onComplete.callDeferred(Variant(InAppPurchaseError.noSuchProduct.rawValue), nil)
					return
				}
				var info: [Variant: Variant] = [:]
				info[Variant("display_name")] = Variant(storeProduct.displayName)
				info[Variant("display_price")] = Variant(storeProduct.displayPrice)
				info[Variant("description")] = Variant(storeProduct.description)
				info[Variant("product_id")] = Variant(storeProduct.id)
				var typeInt: Int = IAPProduct.TYPE_UNKNOWN
				switch storeProduct.type {
				case .consumable: typeInt = IAPProduct.TYPE_CONSUMABLE
				case .nonConsumable: typeInt = IAPProduct.TYPE_NON_CONSUMABLE
				case .autoRenewable: typeInt = IAPProduct.TYPE_AUTO_RENEWABLE
				case .nonRenewable: typeInt = IAPProduct.TYPE_NON_RENEWABLE
				default: typeInt = IAPProduct.TYPE_UNKNOWN
				}
				info[Variant("type")] = Variant(typeInt)
				onComplete.callDeferred(Variant(OK), Variant(info))
			} catch {
				onComplete.callDeferred(
					Variant(InAppPurchaseError.failedToGetProducts.rawValue),
					nil
				)
			}
		}
	}

	/// Get products
	///
	/// - Parameters:
	/// 	- identifiers: An array of product identifiers that you enter in App Store Connect.
	/// 	- onComplete: Callback with parameters: (error: Variant, products: Variant) -> (error: Int, products: [``IAPProduct``])
	@Callable(autoSnakeCase: true)
	func getProducts(identifiers: [String], onComplete: Callable) {
		Task {
			do {
				let storeProducts: [Product] = try await Product.products(for: identifiers)
				var products = VariantArray()

				for storeProduct: Product in storeProducts {
					var product: IAPProduct = IAPProduct()
					product.displayName = storeProduct.displayName
					product.displayPrice = storeProduct.displayPrice
					product.storeDescription = storeProduct.description
					product.productID = storeProduct.id
					switch storeProduct.type {
					case .consumable:
						product.type = IAPProduct.TYPE_CONSUMABLE
					case .nonConsumable:
						product.type = IAPProduct.TYPE_NON_CONSUMABLE
					case .autoRenewable:
						product.type = IAPProduct.TYPE_AUTO_RENEWABLE
					case .nonRenewable:
						product.type = IAPProduct.TYPE_NON_RENEWABLE
					default:
						product.type = IAPProduct.TYPE_UNKNOWN
					}

					products.append(Variant(product))
				}
				onComplete.callDeferred(Variant(OK), Variant(products))
			} catch {
				GD.pushError("Failed to get products from App Store, error: \(error)")
				onComplete.callDeferred(
					Variant(InAppPurchaseError.failedToGetProducts.rawValue),
					nil
				)
			}
		}
	}

	/// Restore purchases
	///
	/// - Parameter onComplete: Callback with parameter: (error: Variant) -> (error: Int)
	@Callable(autoSnakeCase: true)
	func restorePurchases(onComplete: Callable) {
		Task {
			do {
				try await AppStore.sync()
			// Re-emit JWS for server-side reconciliation
			for await result in Transaction.currentEntitlements {
				if case .verified(let transaction) = result {
					let jws: String
					if #available(iOS 16.0, macOS 13.0, *) {
						jws = result.jwsRepresentation
					} else {
						jws = ""
					}
					let txId = String(transaction.id)
					let origTxId = String(transaction.originalID)
					await MainActor.run {
						self.productPurchased.emit(transaction.productID, jws, txId, origTxId)
					}
				}
			}
				onComplete.callDeferred(Variant(OK))
			} catch {
				GD.pushError("Failed to restore purchases: \(error)")
				onComplete.callDeferred(
					Variant(InAppPurchaseError.failedToRestorePurchases.rawValue)
				)
			}
		}
	}

	/// Get pending transactions (awaiting parental approval, payment processing, etc.)
	///
	/// - Parameter onComplete: Callback with parameters: (error: Variant, productIDs: Variant) -> (error: Int, productIDs: [String])
	@Callable(autoSnakeCase: true)
	func getPendingTransactions(onComplete: Callable) {
		Task {
			var pending = VariantArray()
			for await result: VerificationResult<Transaction> in Transaction.unfinished {
				if case .verified(let transaction) = result {
					pending.append(Variant(transaction.productID))
				}
			}
			onComplete.callDeferred(Variant(OK), Variant(pending))
		}
	}

	/// Restore purchases and return productID → JWS dictionary directly.
	/// Unlike restorePurchases (signal-based), this returns results via callback.
	/// Only non-consumable and auto-renewable entitlements are returned.
	///
	/// - Parameter onComplete: Callback with parameters: (error: Variant, result: Variant) -> (error: Int, result: Dictionary[String, String])
	@Callable(autoSnakeCase: true)
	func restoreAndReconcile(onComplete: Callable) {
		Task {
			do {
				try await AppStore.sync()
				var result: [Variant: Variant] = [:]
				for await vr: VerificationResult<Transaction> in Transaction.currentEntitlements {
					if case .verified(let transaction) = vr {
						let jws: String
						if #available(iOS 16.0, macOS 13.0, *) {
							jws = vr.jwsRepresentation
						} else {
							jws = ""
						}
						let txId = String(transaction.id)
						let origTxId = String(transaction.originalID)
						// Pipe-separated: jws|transactionId|originalTransactionId
						result[Variant(transaction.productID)] = Variant("\(jws)|\(txId)|\(origTxId)")
					}
				}
				onComplete.callDeferred(Variant(OK), Variant(result))
			} catch {
				onComplete.callDeferred(
					Variant(InAppPurchaseError.failedToRestorePurchases.rawValue),
					nil
				)
			}
		}
	}

	/// Get the current app environment
	///
	/// NOTE: On iOS 16 this might display a system prompt that asks users to authenticate
	///
	/// - Parameter onComplete: Callback with parameter: (error: Variant, data: Variant) -> (error: Int, data: String)
	@Callable(autoSnakeCase: true)
	public func getEnvironment(onComplete: Callable) {
		if #available(iOS 16.0, *) {
			Task {
				do {
					let result = try await AppTransaction.shared
					switch result {
					case .verified(let appTransaction):
						onComplete.callDeferred(
							Variant(AppTransactionError.ok.rawValue),
							Variant(appTransaction.environment.rawValue)
						)
					case .unverified(let appTransaction, let verificationError):
						onComplete.callDeferred(
							Variant(AppTransactionError.unverified.rawValue),
							Variant(appTransaction.environment.rawValue)
						)
					}
				} catch {
					GD.print("Failed to get appTransaction, error: \(error)")
					onComplete.callDeferred(Variant(AppTransactionError.error.rawValue), Variant(""))
				}
			}
		} else {
			guard let path = Bundle.main.appStoreReceiptURL?.path else {
				onComplete.callDeferred(Variant(AppTransactionError.error.rawValue), Variant(""))
				return
			}

			if path.contains("CoreSimulator") {
				onComplete.callDeferred(Variant(AppTransactionError.ok.rawValue), Variant("xcode"))
			} else if path.contains("sandboxReceipt") {
				onComplete.callDeferred(Variant(AppTransactionError.ok.rawValue), Variant("sandbox"))
			} else {
				onComplete.callDeferred(Variant(AppTransactionError.ok.rawValue), Variant("production"))
			}
		}
	}

	/// Refresh the App Store signed app transaction (only iOS 16+)
	///
	/// NOTE: This will display a system prompt that asks users to authenticate
	@Callable(autoSnakeCase: true)
	public func refreshAppTransaction(onComplete: Callable) {
		if #available(iOS 16.0, *) {
			Task {
				do {
					try await AppTransaction.refresh()
					onComplete.callDeferred(Variant(AppTransactionError.ok.rawValue))
				} catch {
					onComplete.callDeferred(Variant(AppTransactionError.unverified.rawValue))
				}
			}
		} else {
			onComplete.callDeferred(Variant(OK))
		}
	}

	// Internal functionality

	func getProduct(_ productIdentifier: String) async throws -> Product? {
		var product: [Product] = []
		do {
			product = try await Product.products(for: [productIdentifier])
		} catch {
			GD.pushError("Unable to get product with identifier: \(productIdentifier): \(error)")
		}

		return product.first
	}

	func updateProducts() async {
		do {
			let storeProducts = try await Product.products(for: productIDs)
			products = storeProducts
		} catch {
			GD.pushError("Failed to get products from App Store: \(error)")
		}
	}

	func updateProductStatus() async {
		for await result: VerificationResult<Transaction> in Transaction.currentEntitlements {
			guard case .verified(let transaction) = result else {
				continue
			}

			if transaction.revocationDate == nil {
				self.purchasedProducts.insert(transaction.productID)
			} else {
				self.purchasedProducts.remove(transaction.productID)
			}
		}
	}

	/// Extract a verified transaction and its JWS from a VerificationResult.
	/// jwsRepresentation is only defined on VerificationResult<Transaction>,
	/// so this method is non-generic to satisfy the type checker.
	/// Returns: (transaction, jws, transactionId, originalTransactionId)
	func extractVerified(_ result: VerificationResult<Transaction>) throws -> (Transaction, String, String, String) {
		let jws: String
		if #available(iOS 16.0, macOS 13.0, *) {
			jws = result.jwsRepresentation
		} else {
			jws = ""
		}
		switch result {
		case .verified(let transaction):
			let txId = String(transaction.id)
			let origTxId = String(transaction.originalID)
			return (transaction, jws, txId, origTxId)
		case .unverified:
			throw StoreError.failedVerification
		}
	}

	func listenForTransactions() -> Task<Void, Error> {
		return Task.detached {
			for await result: VerificationResult<Transaction> in Transaction.updates {
				do {
					let (transaction, jws, txId, origTxId) = try self.extractVerified(result)

					if transaction.revocationDate == nil {
						// Purchased — update status and finish before emitting
						await self.updateProductStatus()
						await transaction.finish()
						await MainActor.run {
							self.productPurchased.emit(transaction.productID, jws, txId, origTxId)
						}
					} else {
						// Revoked — do NOT finish; let Apple handle cleanup
						guard let revDate = transaction.revocationDate else {
							GD.pushWarning("Revocation signal fired but revocationDate is nil")
							continue
						}
						let revDateMs = String(Int64(revDate.timeIntervalSince1970 * 1000))
						let revReason: String
						if #available(iOS 16.0, macOS 13.0, *) {
							revReason = transaction.revocationReason == .developerIssue ? "developer_issue" : "other"
						} else {
							revReason = ""
						}
						await MainActor.run {
							self.productRevoked.emit(transaction.productID, revDateMs, revReason, txId)
						}
					}
				} catch {
					GD.pushWarning("Transaction failed verification")
				}
			}
		}
	}
}
