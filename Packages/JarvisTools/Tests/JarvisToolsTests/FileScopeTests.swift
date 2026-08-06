import Testing
import Foundation
@testable import JarvisTools

/// The file tools are only as safe as this check. A path that escapes the
/// allowed roots would let the model read or overwrite anything the user can.
@Suite struct FileScopeTests {
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    @Test func allowsTheDeclaredRoots() {
        #expect(FileScope.isAllowed(home.appending(path: "Documents/notes.txt")))
        #expect(FileScope.isAllowed(home.appending(path: "Desktop/a/b/c.md")))
        #expect(FileScope.isAllowed(home.appending(path: "Downloads/x.pdf")))
        #expect(FileScope.isAllowed(home.appending(path: "Developer/Jarvis/README.md")))
    }

    @Test func rejectsOutsideTheRoots() {
        #expect(!FileScope.isAllowed(URL(filePath: "/etc/passwd")))
        #expect(!FileScope.isAllowed(home.appending(path: ".ssh/id_rsa")))
        #expect(!FileScope.isAllowed(home.appending(path: "Library/Keychains/login.keychain-db")))
        #expect(!FileScope.isAllowed(URL(filePath: "/System/Library/CoreServices")))
    }

    /// The important one: `..` must not walk out of an allowed root.
    @Test func rejectsTraversalOutOfAnAllowedRoot() {
        #expect(!FileScope.isAllowed(home.appending(path: "Documents/../.ssh/id_rsa")))
        #expect(!FileScope.isAllowed(home.appending(path: "Desktop/../../../etc/passwd")))
        #expect(!FileScope.isAllowed(home.appending(path: "Downloads/../Library/Mail")))
    }

    @Test func traversalThatStaysInsideIsFine() {
        #expect(FileScope.isAllowed(home.appending(path: "Documents/sub/../notes.txt")))
    }

    /// A sibling whose name merely starts with an allowed root must not pass.
    @Test func prefixCollisionIsNotEnough() {
        #expect(!FileScope.isAllowed(home.appending(path: "DocumentsSecret/x.txt")))
        #expect(!FileScope.isAllowed(home.appending(path: "Desktop-old/x.txt")))
    }

    @Test func expandsTilde() {
        let resolved = FileScope.resolve("~/Documents/notes.txt")
        #expect(!resolved.path.contains("~"))
        #expect(FileScope.isAllowed(resolved))
    }
}

@Suite struct WeatherCodeTests {
    @Test func mapsKnownCodesToSpeakableWords() {
        #expect(GetWeatherTool.describe(0) == "clear")
        #expect(GetWeatherTool.describe(3) == "overcast")
        #expect(GetWeatherTool.describe(65) == "heavy rain")
        #expect(GetWeatherTool.describe(95) == "thunderstorms")
    }

    @Test func unknownCodesStillSaySomething() {
        #expect(!GetWeatherTool.describe(1234).isEmpty)
    }
}
