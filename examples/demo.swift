import Foundation

/// A tiny bank account, to show off highlighting.
struct Account: Identifiable {
    let id = UUID()
    var owner: String
    private(set) var balance: Decimal = 0

    mutating func deposit(_ amount: Decimal) throws {
        guard amount > 0 else { throw BankError.invalidAmount }
        balance += amount
        print("Deposited \(amount) for \(owner) 🎉")
    }
}

enum BankError: Error {
	case invalidAmount   // indented with a tab
	case insufficientFunds(needed: Decimal)
}

let names = ["Ana", "Bruno", "Chloé", "日本語"]
for (index, name) in names.enumerated() where index % 2 == 0 {
    var account = Account(owner: name)
    try? account.deposit(42.5)
}
