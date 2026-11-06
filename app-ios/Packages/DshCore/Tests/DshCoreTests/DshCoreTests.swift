import Testing
@testable import DshCore

@Test("the package builds and reports its version")
func versionIsSet() {
    #expect(!DshCore.version.isEmpty)
}
