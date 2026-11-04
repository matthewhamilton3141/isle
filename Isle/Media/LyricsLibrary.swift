//
//  LyricsLibrary.swift
//
//  Finds a track's synced lyrics on LRCLIB (https://lrclib.net), a free,
//  open lyrics database. Neither Spotify nor Music exposes lyrics to other
//  apps, so this is the only source there is — and it's only asked at all
//  when the user has switched lyrics on in Settings.
//
//  What gets sent is the track's title, artist, album and length, in one
//  lookup per track change, from `NotchViewModel.syncLyrics`: a signature
//  request, and a search only if that finds nothing usable. Nothing else —
//  no account, no identifier beyond the User-Agent that LRCLIB asks every
//  client to send.
//
//  The rule the matching follows is the one the rest of Isle does — say
//  nothing that can't be backed up. A record is only used when it is timed
//  (`syncedLyrics`, never `plainLyrics`), and when it is the same recording:
//  same title once the version dressing is set aside, an artist in common,
//  the same version markers (a live take is not the studio cut), and a length
//  within two seconds — the tolerance LRCLIB's own signature match uses.
//  Anything less is no lyrics, not the nearest lyrics.
//
//  Answers are cached per track, in memory and in a small folder under
//  Caches, so a track that comes round again on a playlist isn't asked about
//  twice. A miss is cached too, but only for a few days: LRCLIB fills in
//  missing tracks in the background, so a miss today can be a hit next week.
//  A failed request — offline, rate-limited, a skip that cancelled it — is
//  not an answer, and is never cached.
//
//  No AppKit, so the matching can be run against the live API from a
//  harness without building the app.
//

import Foundation
import CryptoKit

/// The track as its player names it — what a lookup is asked for.
struct LyricsQuery: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
    /// Seconds. A lookup with no usable length finds nothing: the length is
    /// what tells one version of a song from another.
    let duration: TimeInterval
}

actor LyricsLibrary {
    /// LRCLIB asks every client to name itself, its version and a homepage.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Isle \(version.map { "v\($0) " } ?? "")(https://github.com/matthewhamilton3141/isle)"
    }()

    private static let base = URL(string: "https://lrclib.net/api/")!

    /// How long a miss is believed before the track is asked about again.
    private static let missLifetime: TimeInterval = 3 * 24 * 3600

    /// Disk entries kept. A few KB each; the oldest go first.
    private static let diskLimit = 500

    private let session: URLSession
    private let directory: URL?

    private enum Answer {
        case found(String)
        case none
    }

    private struct Entry: Codable {
        /// LRC text, or nil for a miss.
        let lrc: String?
        let savedAt: Date
    }

    private var memory: [String: Entry] = [:]

    /// LRCLIB's `Retry-After`, honoured: nothing is sent before this.
    private var quietUntil: Date = .distantPast

    /// Disk is pruned once a launch, on the first write.
    private var pruned = false

    init(directory: URL? = LyricsLibrary.defaultDirectory) {
        // Ephemeral: no cookies, and no URL cache on top of the one here.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: config)
        self.directory = directory
    }

    static var defaultDirectory: URL? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let folder = Bundle.main.bundleIdentifier ?? "Isle"
        return caches?.appendingPathComponent(folder).appendingPathComponent("Lyrics")
    }

    /// The track's synced lyrics, or nil when there are none to be had — no
    /// match, only plain lyrics, an instrumental, or a request that failed.
    func lyrics(for query: LyricsQuery) async -> SyncedLyrics? {
        let key = Self.cacheKey(query)
        if let entry = cached(key) {
            return entry.lrc.flatMap(SyncedLyrics.init(lrc:))
        }

        guard let answer = await lookUp(query) else { return nil }
        let entry: Entry
        switch answer {
        case .found(let lrc): entry = Entry(lrc: lrc, savedAt: Date())
        case .none: entry = Entry(lrc: nil, savedAt: Date())
        }
        store(entry, for: key)
        return entry.lrc.flatMap(SyncedLyrics.init(lrc:))
    }

    // MARK: - LRCLIB

    /// One signature lookup, then — only if that turns up nothing usable — one
    /// search. Nil when a request failed and the answer is still unknown.
    private func lookUp(_ query: LyricsQuery) async -> Answer? {
        // LRCLIB rejects lengths outside this, and without one there's no
        // telling the versions apart.
        guard (1...3600).contains(query.duration) else { return Answer.none }
        guard Date() >= quietUntil else { return nil }

        var signature = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
            URLQueryItem(name: "duration", value: String(Int(query.duration.rounded())))
        ]
        if !query.album.isEmpty {
            signature.append(URLQueryItem(name: "album_name", value: query.album))
        }

        switch await fetch("get", signature, as: LyricsRecord.self) {
        case .failed:
            return nil
        case .missing:
            break
        case .ok(let record):
            if let lrc = LyricsMatch.best([record], for: query) {
                return .found(lrc)
            }
            // This very recording, marked as having no words: settled.
            if record.instrumental == true, LyricsMatch.isSameRecording(record, as: query) {
                return Answer.none
            }
        }

        // The signature lookup is strict about album and title spelling, and
        // misses a track filed under another album or written with a
        // "- Remastered" tail. A search on the bare title and lead artist
        // finds those; `best` then holds every candidate to the same rule.
        let search = [
            URLQueryItem(name: "track_name", value: LyricsMatch.searchTitle(query.title)),
            URLQueryItem(name: "artist_name", value: LyricsMatch.leadArtist(query.artist))
        ]
        switch await fetch("search", search, as: [LyricsRecord].self) {
        case .failed:
            return nil
        case .missing:
            return Answer.none
        case .ok(let records):
            return LyricsMatch.best(records, for: query).map(Answer.found) ?? Answer.none
        }
    }

    private enum Response<T> {
        case ok(T)
        /// A definite "no such record": 404, or a request LRCLIB refused as
        /// invalid (400), which no retry would change.
        case missing
        case failed
    }

    private func fetch<T: Decodable>(
        _ endpoint: String, _ items: [URLQueryItem], as: T.Type
    ) async -> Response<T> {
        guard var components = URLComponents(
            url: Self.base.appendingPathComponent(endpoint),
            resolvingAgainstBaseURL: false
        ) else { return .failed }
        components.queryItems = items
        guard let url = components.url else { return .failed }

        // One retry, and only for a busy server that names a short wait.
        // LRCLIB sheds load with a 503 and `Retry-After: 1` often enough that
        // giving up there would lose real lyrics for the whole track; anything
        // longer is a throttle, and waits for the next track change.
        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else { return .failed }
                switch http.statusCode {
                case 200:
                    guard let value = try? JSONDecoder().decode(T.self, from: data) else { return .failed }
                    return .ok(value)
                case 400, 404:
                    return .missing
                case 429, 503:
                    let wait = http.value(forHTTPHeaderField: "Retry-After")
                        .flatMap(TimeInterval.init) ?? 60
                    // Jittered, as LRCLIB asks, so throttled clients don't
                    // all come back in the same second.
                    let jittered = wait * Double.random(in: 1.0...1.3)
                    quietUntil = Date().addingTimeInterval(jittered)
                    guard attempt == 0, wait <= 5 else {
                        NSLog("Isle: LRCLIB \(endpoint) answered \(http.statusCode); quiet for \(Int(wait))s")
                        return .failed
                    }
                    try await Task.sleep(nanoseconds: UInt64(jittered * 1_000_000_000))
                default:
                    NSLog("Isle: LRCLIB \(endpoint) answered \(http.statusCode)")
                    return .failed
                }
            } catch {
                // A skip cancels the lookup in flight; that's not worth a line.
                if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                    NSLog("Isle: LRCLIB \(endpoint) failed: \(error.localizedDescription)")
                }
                return .failed
            }
        }
        return .failed
    }

    // MARK: - Cache

    /// Normalised so the adapter's and the poll's spelling of one track — and
    /// their slightly different lengths — land on the same entry.
    static func cacheKey(_ query: LyricsQuery) -> String {
        [
            LyricsMatch.fold(query.title),
            LyricsMatch.fold(query.artist),
            LyricsMatch.fold(query.album),
            String(Int(query.duration.rounded()))
        ].joined(separator: "\n")
    }

    private func cached(_ key: String) -> Entry? {
        if let entry = memory[key] {
            if isFresh(entry) { return entry }
            memory[key] = nil
            return nil
        }
        guard let file = file(for: key),
              let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              isFresh(entry) else { return nil }
        memory[key] = entry
        return entry
    }

    private func isFresh(_ entry: Entry) -> Bool {
        entry.lrc != nil || Date().timeIntervalSince(entry.savedAt) < Self.missLifetime
    }

    private func store(_ entry: Entry, for key: String) {
        memory[key] = entry
        guard let directory, let file = file(for: key),
              let data = try? JSONEncoder().encode(entry) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        if !pruned {
            pruned = true
            prune(directory)
        }
    }

    /// Down to the newest `diskLimit` entries.
    private func prune(_ directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ), files.count > Self.diskLimit else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.diskLimit) {
            try? fm.removeItem(at: url)
        }
    }

    private func file(for key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(name).appendingPathExtension("json")
    }
}

/// One LRCLIB lyrics record — the fields Isle reads of it.
struct LyricsRecord: Decodable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let syncedLyrics: String?
}

/// The same-recording rule. See the file header for why it's this strict.
enum LyricsMatch {
    /// Seconds either way. LRCLIB's own signature match allows the same.
    static let durationTolerance: TimeInterval = 2

    /// The timed lyrics of the record that best matches, or nil if none does.
    /// Closest length wins; a matching album breaks a tie.
    static func best(_ records: [LyricsRecord], for query: LyricsQuery) -> String? {
        let album = fold(query.album)
        return records
            .compactMap { record -> (lrc: String, gap: TimeInterval, sameAlbum: Bool)? in
                guard isSameRecording(record, as: query),
                      record.instrumental != true,
                      let lrc = record.syncedLyrics,
                      SyncedLyrics(lrc: lrc) != nil,
                      let duration = record.duration else { return nil }
                return (lrc, abs(duration - query.duration), fold(record.albumName ?? "") == album)
            }
            .min { lhs, rhs in
                lhs.gap != rhs.gap ? lhs.gap < rhs.gap : (lhs.sameAlbum && !rhs.sameAlbum)
            }?
            .lrc
    }

    static func isSameRecording(_ record: LyricsRecord, as query: LyricsQuery) -> Bool {
        guard let duration = record.duration,
              abs(duration - query.duration) <= durationTolerance else { return false }
        return titleKey(record.trackName) == titleKey(query.title)
            && versionTags(record.trackName, album: record.albumName ?? "")
                == versionTags(query.title, album: query.album)
            && artistsOverlap(record.artistName, query.artist)
    }

    // MARK: - Titles

    /// What a player tacks onto a title to say which version it is, in a
    /// " - " tail or in brackets: "Song - Remastered 2011", "Song (feat. X)",
    /// "Song [Live]". Split off so the bare titles can be compared.
    private static func split(_ title: String) -> (bare: String, dressing: String) {
        var bare = title
        var dressing = ""
        if let dash = bare.range(of: " - ") {
            dressing += " " + bare[dash.upperBound...]
            bare = String(bare[..<dash.lowerBound])
        }
        let bracketed = #"[\(\[][^\)\]]*[\)\]]"#
        while let range = bare.range(of: bracketed, options: .regularExpression) {
            dressing += " " + bare[range]
            bare.removeSubrange(range)
        }
        return (bare.trimmingCharacters(in: .whitespaces), dressing)
    }

    /// The bare title, folded. Falls back to the whole title when it is
    /// nothing *but* dressing — "[Untitled]" — rather than comparing two
    /// empty strings.
    static func titleKey(_ title: String) -> String {
        let bare = fold(split(title).bare)
        return bare.isEmpty ? fold(title) : bare
    }

    /// Words in the dressing that mean a different recording rather than a
    /// different release of the same one. "Remastered" and "feat." are absent
    /// on purpose: a remaster is the same performance, and lyrics don't care
    /// who's credited.
    ///
    /// The album counts for the stage ones. A live album often leaves its
    /// track titles bare — Music files the Live Killers "Bohemian Rhapsody"
    /// as just that — and without this a concert take would match a studio
    /// record that happens to run within two seconds of it.
    static func versionTags(_ title: String, album: String = "") -> Set<String> {
        let markers: Set<String> = [
            "live", "acoustic", "instrumental", "karaoke", "remix", "demo",
            "unplugged", "sped", "slowed", "acapella", "cappella", "orchestral"
        ]
        let stage: Set<String> = ["live", "unplugged", "acoustic"]
        let titleWords = Set(fold(split(title).dressing).split(separator: " ").map(String.init))
        let albumWords = Set(fold(album).split(separator: " ").map(String.init))
        return titleWords.intersection(markers).union(albumWords.intersection(stage))
    }

    /// The title to search on: the bare title, which LRCLIB's keyword search
    /// matches more readily than one with a version tail.
    static func searchTitle(_ title: String) -> String {
        let bare = split(title).bare
        return bare.isEmpty ? title : bare
    }

    // MARK: - Artists

    private static let artistSeparator =
        #"\s*(?:,|&|;|/|\+|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b|\band\b|\bx\b|\bvs\.?)\s*"#

    private static func artistNames(_ artist: String) -> [String] {
        artist
            .replacingOccurrences(of: artistSeparator, with: "\u{1F}", options: [.regularExpression, .caseInsensitive])
            .split(separator: "\u{1F}")
            .map { fold(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// The first credited artist, for the search query.
    static func leadArtist(_ artist: String) -> String {
        let lead = artist
            .replacingOccurrences(of: artistSeparator, with: "\u{1F}", options: [.regularExpression, .caseInsensitive])
            .split(separator: "\u{1F}")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return lead.flatMap { $0.isEmpty ? nil : $0 } ?? artist
    }

    /// One credit contains the other, or they name someone in common — so
    /// "Queen" matches "Queen & David Bowie", and "Florence + the Machine"
    /// matches "Florence and the Machine".
    static func artistsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let a = fold(lhs)
        let b = fold(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        // Whole words only, so "Rain" isn't found inside "Rainbow".
        let paddedA = " \(a) ", paddedB = " \(b) "
        if paddedA.contains(paddedB) || paddedB.contains(paddedA) { return true }
        return !Set(artistNames(lhs)).isDisjoint(with: artistNames(rhs))
    }

    // MARK: - Folding

    /// Case, accents, width and punctuation set aside; "&" read as "and";
    /// runs of space collapsed. Letters of every script survive.
    static func fold(_ string: String) -> String {
        let folded = string
            .replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
