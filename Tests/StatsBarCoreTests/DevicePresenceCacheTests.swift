// DevicePresenceCacheTests.swift — which attached device gets shown, and which read it came from.
//
// Every case here drives a SEQUENCE with an explicit clock, because that is the only way any of this
// misbehaves. The failure modes are a device that never times out, a device that vanishes on a one-tick
// enumeration blip, cached health evicted by a sibling, and health grafted onto the wrong row — none of
// them visible in a single frame, and the repo has already shipped one of them (239a191, where the grace
// window was effectively measured from the last time ANY device succeeded).

import Testing
import Foundation
@testable import StatsBarCore

@Suite("Device presence cache")
struct DevicePresenceCacheTests {

    /// Stands in for IOSDeviceInfo / AndroidDeviceInfo. A local type on purpose: the cache is generic so
    /// it never needs the model layer, and a stub is what proves that.
    struct Dev: Equatable {
        enum Read { case good, partial, failed }
        var id: String
        var read: Read = .good
        var capturedAt: Date?
        /// Unique per read, so an assertion can say WHICH read a row came from rather than just which
        /// device. Without it, showing the cached row and showing the fresh one look the same.
        var mark: Int = 0
    }

    typealias Cache = DevicePresenceCache<Dev, String>

    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    static func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }

    /// One tick, with each resolved row flattened to "id=source:mark" so the assertions read as the
    /// situation rather than as a struct dump.
    static func tick(_ cache: inout Cache, _ fresh: [Dev], at seconds: Double) -> [String] {
        cache.resolve(
            fresh, now: at(seconds), id: \.id,
            kind: { d in
                switch d.read {
                case .good:    return .good
                case .partial: return .partial
                case .failed:  return .failed
                }
            },
            capturedAt: \.capturedAt
        ).map { row in
            switch row {
            case .fresh(let d):              return "\(d.id)=fresh:\(d.mark)"
            case .grafted(let d, let base):  return "\(d.id)=grafted:\(d.mark)+\(base.mark)"
            case .cachedStale(let d):        return "\(d.id)=stale:\(d.mark)"
            }
        }
    }

    static func good(_ id: String, _ mark: Int, at seconds: Double) -> Dev {
        Dev(id: id, read: .good, capturedAt: at(seconds), mark: mark)
    }
    static func partial(_ id: String, _ mark: Int) -> Dev { Dev(id: id, read: .partial, mark: mark) }
    static func failed(_ id: String, _ mark: Int) -> Dev { Dev(id: id, read: .failed, mark: mark) }

    // MARK: A good read

    @Test("a good read is shown as read and becomes the baseline")
    func goodReadBecomesTheBaseline() {
        var c = Cache(graceGone: 3)
        #expect(Self.tick(&c, [Self.good("a", 1, at: 0)], at: 0) == ["a=fresh:1"])
        #expect(c.baseline.map { $0.mark } == [1])
        // And the next good read replaces it rather than accumulating.
        #expect(Self.tick(&c, [Self.good("a", 2, at: 1)], at: 1) == ["a=fresh:2"])
        #expect(c.baseline.map { $0.mark } == [2])
    }

    // MARK: A partial read — the invariant that keeps health from being lost

    @Test("a partial read is grafted from the baseline and never becomes one")
    func partialReadIsGraftedAndNeverBaselines() {
        // The load-bearing case. A locked iPhone or a glyph-only light read has live charge but no health
        // figures; letting it into the baseline would overwrite the real health with nothing, and the
        // device would then show blank health for as long as it stayed locked — with no error to explain
        // it, because nothing failed.
        var c = Cache(graceGone: 3)
        _ = Self.tick(&c, [Self.good("a", 1, at: 0)], at: 0)
        #expect(Self.tick(&c, [Self.partial("a", 2)], at: 1) == ["a=grafted:2+1"])
        #expect(c.baseline.map { $0.mark } == [1])   // still read 1, NOT read 2
        // Many partial reads later, the graft still comes from the same good read.
        #expect(Self.tick(&c, [Self.partial("a", 3)], at: 2) == ["a=grafted:3+1"])
        #expect(Self.tick(&c, [Self.partial("a", 4)], at: 3) == ["a=grafted:4+1"])
        #expect(c.baseline.map { $0.mark } == [1])
    }

    @Test("a partial read with nothing cached stands on its own")
    func partialReadWithNoBaseline() {
        // A device whose very first read arrives locked has no health to graft. It must still be shown —
        // live charge is worth having — rather than waiting for figures it has never had.
        var c = Cache(graceGone: 3)
        #expect(Self.tick(&c, [Self.partial("a", 1)], at: 0) == ["a=fresh:1"])
        #expect(c.baseline.isEmpty)
    }

    @Test("a graft takes its figures from the same device, not from a sibling")
    func graftIsPerDevice() {
        var c = Cache(graceGone: 3)
        _ = Self.tick(&c, [Self.good("a", 1, at: 0), Self.good("b", 2, at: 0)], at: 0)
        #expect(Self.tick(&c, [Self.partial("a", 3), Self.partial("b", 4)], at: 1)
                == ["a=grafted:3+1", "b=grafted:4+2"])
    }

    // MARK: A failed read — the 239a191 shape

    @Test("a failed read rides out on that device's own last good read")
    func failedReadRidesOut() {
        var c = Cache(graceGone: 3)
        _ = Self.tick(&c, [Self.good("a", 1, at: 0)], at: 0)
        // Inside the 30 s window the cached row stands in, so a momentary untrusted/handshake failure
        // doesn't blank a working phone.
        #expect(Self.tick(&c, [Self.failed("a", 2)], at: 29) == ["a=stale:1"])
    }

    @Test("a failed read surfaces its error once that device's own grace expires")
    func failedReadEventuallySurfaces() {
        var c = Cache(graceGone: 3)
        _ = Self.tick(&c, [Self.good("a", 1, at: 0)], at: 0)
        _ = Self.tick(&c, [Self.failed("a", 2)], at: 29)
        // 30 s after the last GOOD read, not 30 s after the failures started: the window has a fixed
        // origin, so a device that keeps failing does eventually tell the user.
        #expect(Self.tick(&c, [Self.failed("a", 3)], at: 31) == ["a=fresh:3"])
    }

    @Test("a healthy sibling refreshing cannot keep resetting another device's grace")
    func siblingCannotResetAnotherDevicesGrace() {
        // This is 239a191. When the window is measured from "the last time anything succeeded", a healthy
        // phone polling at 1 Hz resets it on every tick and the broken phone's error never reaches the
        // user — it rides out on cached data forever, looking merely stale.
        var c = Cache(graceGone: 3)
        _ = Self.tick(&c, [Self.good("a", 1, at: 0), Self.good("b", 2, at: 0)], at: 0)

        // a succeeds on every tick from here; b fails on every tick.
        #expect(Self.tick(&c, [Self.good("a", 3, at: 29), Self.failed("b", 4)], at: 29)
                == ["a=fresh:3", "b=stale:2"])
        #expect(Self.tick(&c, [Self.good("a", 5, at: 31), Self.failed("b", 6)], at: 31)
                == ["a=fresh:5", "b=fresh:6"])   // b's own 30 s is up regardless of a
    }

    @Test("a failed read with no cached good read at all is shown as it came back")
    func failedReadWithNoBaseline() {
        var c = Cache(graceGone: 3)
        #expect(Self.tick(&c, [Self.failed("a", 1)], at: 0) == ["a=fresh:1"])
    }

    // MARK: The cache is per device

    @Test("one device reading well does not evict a sibling's cached health")
    func goodReadDoesNotEvictSiblings() {
        // Replacing the cache with this tick's good reads — rather than merging into it — is the mistake
        // this guards: one healthy phone would wipe every other device's baseline, and the locked phone
        // beside it would lose the health it was grafting from.
        var c = Cache(graceGone: 3)
        _ = Self.tick(&c, [Self.good("a", 1, at: 0), Self.good("b", 2, at: 0)], at: 0)
        // a reads well, b is locked. b keeps its own baseline.
        _ = Self.tick(&c, [Self.good("a", 3, at: 1), Self.partial("b", 4)], at: 1)
        #expect(c.baseline.map { $0.mark } == [3, 2])
        #expect(Self.tick(&c, [Self.partial("b", 5)], at: 2) == ["b=grafted:5+2"])
    }

    // MARK: An empty enumeration

    @Test("an empty enumeration rides out a blip and then lets the device go")
    func emptyEnumerationRidesOutThenClears() {
        // A one-tick USB enumeration blip must not make a phone vanish and reappear, but a deliberate
        // unplug has to clear in a few seconds rather than lingering — hence a window rather than either
        // extreme. Nothing to show is how the reader knows to print its "nothing connected" text.
        var c = Cache(graceGone: 3)
        _ = Self.tick(&c, [Self.good("a", 1, at: 0)], at: 0)
        #expect(Self.tick(&c, [], at: 1) == ["a=stale:1"])    // within the window: ride it out
        #expect(Self.tick(&c, [], at: 2) == ["a=stale:1"])
        #expect(Self.tick(&c, [], at: 4) == [])               // 4 s > 3 s: gone
    }

    @Test("an empty enumeration leaves the baseline alone")
    func emptyEnumerationDoesNotPrune() {
        // Deliberate asymmetry, and the reason it is spelled out here: the baseline is pruned only on a
        // tick that enumerated something. A device that drops off the bus keeps its cached health for as
        // long as the bus stays empty, and loses it on the first tick that sees anything — which is what
        // stops it lingering and then briefly resurrecting later.
        var c = Cache(graceGone: 3)
        _ = Self.tick(&c, [Self.good("a", 1, at: 0)], at: 0)
        _ = Self.tick(&c, [], at: 100)
        #expect(c.baseline.map { $0.mark } == [1])   // not shown any more, but still cached
        _ = Self.tick(&c, [Self.good("b", 2, at: 101)], at: 101)
        #expect(c.baseline.map { $0.mark } == [2])   // the first non-empty tick clears it
    }

    @Test("a device gone longer than the window is dropped on the next non-empty tick")
    func departedDeviceIsPruned() {
        var c = Cache(graceGone: 3)
        _ = Self.tick(&c, [Self.good("a", 1, at: 0), Self.good("b", 2, at: 0)], at: 0)
        // b stops enumerating. a keeps reading, so the prune runs every tick.
        _ = Self.tick(&c, [Self.good("a", 3, at: 1)], at: 1)
        #expect(c.baseline.map { $0.mark } == [3, 2])   // b within its window, still cached
        _ = Self.tick(&c, [Self.good("a", 4, at: 5)], at: 5)
        #expect(c.baseline.map { $0.mark } == [4])      // b gone longer than 3 s
    }

    @Test("the grace window is a parameter, so the two readers can differ")
    func graceGoneIsConfigurable() {
        // IOSDeviceReader uses 3 s and AndroidDeviceReader 5 s, so this cannot be a constant.
        var android = Cache(graceGone: 5)
        _ = Self.tick(&android, [Self.good("a", 1, at: 0)], at: 0)
        #expect(Self.tick(&android, [], at: 4) == ["a=stale:1"])   // still riding out at 4 s
        #expect(Self.tick(&android, [], at: 6) == [])
    }

    // MARK: Bookkeeping that has to stay bounded

    @Test("lastSeenAt does not grow with every device ever attached")
    func lastSeenAtIsBounded() {
        // One entry per id seen this session would be unbounded in principle. An id last seen longer ago
        // than the window answers `seenWithin` the same as one that was never seen at all, so dropping it
        // cannot change a decision — which is what makes pruning it safe rather than merely tidy.
        var c = Cache(graceGone: 3)
        _ = Self.tick(&c, [Self.good("a", 1, at: 0)], at: 0)
        _ = Self.tick(&c, [Self.good("b", 2, at: 10)], at: 10)
        _ = Self.tick(&c, [Self.good("c", 3, at: 20)], at: 20)
        #expect(c.lastSeenAt.keys.sorted() == ["c"])
        // And the answers are unchanged by that pruning: a is not "recently seen" either way.
        #expect(c.seenWithin(3, "a", Self.at(20)) == false)
        #expect(c.seenWithin(3, "c", Self.at(20)) == true)
    }

    @Test("a device that enumerates but cannot be read still counts as present")
    func failedReadStillCountsAsSeen() {
        // Presence and readability are different questions. A device that is on the bus but failing must
        // not be pruned for absence — that is what lets it ride out on cached data, and then surface its
        // own error, instead of silently disappearing.
        var c = Cache(graceGone: 3)
        _ = Self.tick(&c, [Self.good("a", 1, at: 0)], at: 0)
        _ = Self.tick(&c, [Self.failed("a", 2)], at: 10)
        #expect(c.seenWithin(3, "a", Self.at(10)) == true)
        #expect(c.baseline.map { $0.mark } == [1])   // survived the prune, so it can still ride out
    }
}
