// NettopOutputTests.swift — the parse that stands between a command's stdout and a table of numbers
// the user will believe.
//
// This is the only defence this feature has. macOS publishes no API for per-process network bytes, so
// the figures come from `nettop`'s CSV, and the failure worth guarding is not a crash — it is nettop
// changing shape and the parse quietly producing plausible wrong numbers. Hence the two cases below
// that reorder and extend the header: they fail if anything ever goes back to reading fields by
// position, which is the change that would look harmless in review.
//
// `real` is captured verbatim from the command this app runs, on the machine it was written on.

import Testing
@testable import StatsBarCore

@Suite("nettop output")
struct NettopOutputTests {

    /// Real output, trimmed to a handful of rows. Note the trailing comma on every line — the split
    /// produces an empty final field — and the empty first header field, because nettop does not
    /// label the process column.
    static let real = """
    ,bytes_in,bytes_out,
    launchd.1,0,0,
    configd.14062,0,0,
    remoted.14069,3522,2594,
    syslogd.14087,0,14772,
    apsd.14093,159563,1383721,
    """

    @Test("parses the real command output")
    func parsesRealOutput() {
        let samples = NettopOutput.parse(Self.real)
        #expect(samples?.count == 5)
        #expect(samples?.first == ProcessNetworkSample(pid: 1, command: "launchd", bytesIn: 0, bytesOut: 0))
        #expect(samples?.last == ProcessNetworkSample(pid: 14093, command: "apsd",
                                                      bytesIn: 159563, bytesOut: 1383721))
    }

    // MARK: The columns are found by name, not by position

    @Test("a reordered header moves the values with it")
    func reorderedHeaderKeepsValuesWithTheirColumns() {
        // If this ever fails, someone has gone back to reading fields[1] and fields[2]. That change
        // passes every other test in this file and swaps download for upload on screen.
        let swapped = """
        ,bytes_out,bytes_in,
        curl.4242,700,300,
        """
        let s = NettopOutput.parse(swapped)?.first
        #expect(s?.bytesOut == 700)
        #expect(s?.bytesIn == 300)
    }

    @Test("an added column does not shift the ones we asked for")
    func extraColumnDoesNotShiftTheOthers() {
        let extended = """
        ,rx_dupe_bytes,bytes_in,interface,bytes_out,
        curl.4242,99,300,en0,700,
        """
        let s = NettopOutput.parse(extended)?.first
        #expect(s?.bytesIn == 300)
        #expect(s?.bytesOut == 700)
    }

    // MARK: A header we cannot read fails the whole read, and says so with nil

    @Test("a header missing a column returns nil rather than an empty table", arguments: [
        ",bytes_in,\ncurl.4242,300,",                      // bytes_out gone
        ",bytes_out,\ncurl.4242,700,",                     // bytes_in gone
        "nettop: illegal option -- J\nusage: nettop ...",  // an older nettop's usage text
        "",
    ])
    func unreadableHeaderIsNil(text: String) {
        // nil and [] mean different things downstream and the difference is the point: [] is a quiet
        // network, nil is "this build cannot read the output". Collapsing them would put a table of
        // zeroes on screen and let a broken read pass for an idle machine.
        #expect(NettopOutput.parse(text) == nil)
    }

    // MARK: Rows

    @Test("a reverse-DNS process name splits at its last dot")
    func reverseDNSNameSplitsAtTheLastDot() {
        // Splitting at the FIRST dot reads the name as "com" and looks for a pid in
        // "apple.WebKit.Networking.4821". These names are ordinary on macOS.
        let text = ",bytes_in,bytes_out,\ncom.apple.WebKit.Networking.4821,10,20,"
        let s = NettopOutput.parse(text)?.first
        #expect(s?.command == "com.apple.WebKit.Networking")
        #expect(s?.pid == 4821)
    }

    @Test("an unparseable row is skipped without taking the table with it", arguments: [
        "no-dot-at-all,10,20,",
        ".4242,10,20,",             // nothing before the dot
        "curl.notapid,10,20,",
        "curl.,10,20,",             // nothing after it
        "curl.-5,10,20,",
        "kernel_task.0,10,20,",     // pid 0 is the kernel; the ps-based tables skip it too
        "curl.4242,notanumber,20,",
    ])
    func badRowIsSkippedButGoodRowsSurvive(bad: String) {
        let text = ",bytes_in,bytes_out,\n\(bad)\ngood.99,1,2,"
        let samples = NettopOutput.parse(text)
        #expect(samples?.count == 1)
        #expect(samples?.first?.pid == 99)
    }

    @Test("a repeated pid is summed, not overwritten")
    func repeatedPidIsSummed() {
        // -P gives one row per process today, so this is defence rather than a live fix. It is here
        // because the failure mode of the obvious alternative — last row wins — is under-reporting
        // exactly the heavy processes the table exists to find.
        let text = ",bytes_in,bytes_out,\ncurl.4242,100,10,\ncurl.4242,50,5,"
        let samples = NettopOutput.parse(text)
        #expect(samples?.count == 1)
        #expect(samples?.first?.bytesIn == 150)
        #expect(samples?.first?.bytesOut == 15)
    }

    @Test("row order is preserved, so a parse never reorders what it did not rank")
    func rowOrderIsPreserved() {
        // The dictionary used for summing would otherwise hand back an arbitrary order, and ranking
        // is ProcessNetworkRates' job — a parse that quietly shuffles makes that harder to reason about.
        let text = ",bytes_in,bytes_out,\nc.3,0,0,\na.1,0,0,\nb.2,0,0,"
        #expect(NettopOutput.parse(text)?.map(\.pid) == [3, 1, 2])
    }
}
