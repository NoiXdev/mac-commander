import MacCommanderCore
import Testing

/// Runs a test, or every test of a suite, with `L10n` pinned to English. The tests run on Macs set to any
/// language, so a test that compares English text needs this trait.
struct EnglishTrait: TestTrait, SuiteTrait, TestScoping {
    /// On a suite, scope each test rather than the suite as a whole, so the override reaches every test case.
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await L10n.$localeOverride.withValue("en") { try await function() }
    }
}

extension Trait where Self == EnglishTrait {
    /// See `EnglishTrait`.
    static var english: Self { Self() }
}
