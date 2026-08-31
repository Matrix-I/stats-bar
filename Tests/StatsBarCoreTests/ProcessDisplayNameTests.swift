// ProcessDisplayNameTests.swift — the name a TOP PROCESSES row shows.
//
// The fixtures are read off live processes rather than invented, because the case that motivated this
// file is one nobody would think to invent: an unbundled process whose localizedName is 209 characters
// of command line, and whose accounting name — the obvious fallback — is the last path component of
// that command line, so it reads as a file rather than a process.

import Testing
@testable import StatsBarCore

@Suite("Process display name")
struct ProcessDisplayNameTests {

    /// Captured verbatim from a live `npm exec` process (pid 99158) with the probe in this commit's
    /// working notes: localizedName 209 characters, no bundle, executable "node", p_comm "source.json".
    static let nodeCommandLine = """
    npm exec @redocly/cli@2.44.2 bundle /Users/linh.nguyen/Desktop/mesoneer-projects/mideal/\
    ubiid-openapi-spec/signeer-signing-workflow-integration.internal.yaml -o \
    /tmp/claude-501/swi-publish.GQhhleDQ/source.json
    """

    // MARK: The case this exists for

    @Test("an unbundled process shows its executable, not its command line")
    func unbundledProcessShowsItsExecutable() {
        #expect(Self.nodeCommandLine.count == 209)   // the fixture is the real string, not a sketch
        let name = ProcessDisplayName.resolve(localizedName: Self.nodeCommandLine,
                                              isBundled: false,
                                              executableName: "node",
                                              accountingName: "source.json")
        #expect(name == "node")
    }

    @Test("the accounting name is not the answer, even though it is short")
    func accountingNameIsNotTheFallbackHere() {
        // The repair that suggests itself — prefer the accounting name once localizedName looks
        // unreasonable — produces "source.json" for this process. macOS derives p_comm from the last
        // path component of the process title, so for exactly the processes with a runaway title the
        // accounting name is a filename. Shorter, and worse: a row reading "source.json" looks like
        // a file that is using the network.
        let name = ProcessDisplayName.resolve(localizedName: Self.nodeCommandLine,
                                              isBundled: false,
                                              executableName: "node",
                                              accountingName: "source.json")
        #expect(name != "source.json")
    }

    // MARK: Bundled applications keep the name the user knows

    @Test("a bundled app keeps its localized name", arguments: [
        ("Google Chrome", "Google Chrome"),
        ("IntelliJ IDEA", "idea"),
        // 64 characters, and legitimate — the longest bundled name on the machine this was written
        // on. Any length threshold low enough to catch a 209-character command line would throw this
        // away too, which is why the rule keys off bundling rather than length.
        ("QuickLookUIService (Open and Save Panel Service (Google Chrome))", "QuickLookUIService"),
    ])
    func bundledAppKeepsItsLocalizedName(localized: String, executable: String) {
        let name = ProcessDisplayName.resolve(localizedName: localized, isBundled: true,
                                              executableName: executable, accountingName: executable)
        #expect(name == localized)
    }

    @Test("an unbundled daemon reads the same either way")
    func unbundledDaemonIsUnchanged() {
        // The five unbundled processes on this machine all have localizedName == executable name
        // (universalaccessd, GamePolicyAgent, adminbyrequest, familycircled, open), so the new rule
        // must not move them. If it did, the change would be visible on every table on every machine
        // rather than only on the rare runaway title.
        for daemon in ["universalaccessd", "GamePolicyAgent", "adminbyrequest", "familycircled", "open"] {
            #expect(ProcessDisplayName.resolve(localizedName: daemon, isBundled: false,
                                               executableName: daemon, accountingName: daemon) == daemon)
        }
    }

    // MARK: Missing and empty candidates

    @Test("an unbundled process with no executable path falls back to the accounting name")
    func noExecutablePathFallsBackToAccounting() {
        #expect(ProcessDisplayName.resolve(localizedName: "whatever the title says", isBundled: false,
                                           executableName: nil, accountingName: "sshd") == "sshd")
    }

    @Test("a bundled app with no usable localized name falls through to the executable")
    func bundledWithoutLocalizedNameUsesExecutable() {
        #expect(ProcessDisplayName.resolve(localizedName: nil, isBundled: true,
                                           executableName: "Helper", accountingName: "h") == "Helper")
    }

    @Test("empty and whitespace-only candidates are skipped, not shown", arguments: ["", "   ", "\n\t"])
    func emptyCandidatesAreSkipped(blank: String) {
        // AppKit returns an empty localizedName for some short-lived processes. Checking for nil alone
        // would put a number on screen beside nothing at all — the previous code checked isEmpty for
        // this reason, and dropping that check while rearranging the rest is an easy mistake to make.
        #expect(ProcessDisplayName.resolve(localizedName: blank, isBundled: true,
                                           executableName: blank, accountingName: "curl") == "curl")
    }

    @Test("with nothing usable at all, the row is marked rather than blank")
    func nothingUsableGivesAPlaceholder() {
        #expect(ProcessDisplayName.resolve(localizedName: nil, isBundled: false,
                                           executableName: nil, accountingName: "") == "—")
    }

    @Test("a title is still better than a placeholder when it is all that exists")
    func titleIsTheLastResort() {
        // Reached only when macOS gave us no executable path and the caller no accounting name. The
        // command line is what this file exists to avoid showing, and it still beats an empty row.
        #expect(ProcessDisplayName.resolve(localizedName: "some title", isBundled: false,
                                           executableName: nil, accountingName: "") == "some title")
    }
}
