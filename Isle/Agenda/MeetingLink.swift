//
//  MeetingLink.swift
//
//  Finds the video-call link in a calendar event, for the agenda's Join
//  button. Pure: it reads three strings and returns a URL or nothing, so it
//  can be tested without a calendar.
//
//  Conservative by design. A Join button opens whatever it points at, from a
//  field anyone who can send an invitation can write, so a link only counts
//  when its host is exactly one of the call services below — or a subdomain
//  of one, for the per-company hosts Zoom and Webex hand out — and its path
//  has the shape of a meeting rather than a home page. `zoom.us.evil.com`,
//  `evilzoom.us` and `https://zoom.us@evil.com` are all somewhere else.
//
//  The event's own URL field is read first, then its location, then its
//  notes: that's the order of how deliberately each was filled in. The first
//  field with a call link in it decides. If that field holds two different
//  meetings — a Zoom and a Teams, or two Zoom rooms — there's no telling
//  which one this is, and no button is better than the wrong room; a later
//  field isn't consulted either, since it can't settle the question.
//

import Foundation

enum MeetingLink {
    /// The call link to join this event by, or nil when there's none — or
    /// more than one and no way to tell which.
    static func find(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, let link = meeting(url) { return link }
        for text in [location, notes] {
            switch scan(text) {
            case .none: continue
            case .one(let link): return link
            case .ambiguous: return nil
            }
        }
        return nil
    }

    // MARK: - Services

    /// A call service: the host it lives on, whether per-company subdomains
    /// of it count too, and what a meeting's path looks like there.
    private struct Service {
        let host: String
        let subdomains: Bool
        let path: (String) -> Bool
    }

    private static let services: [Service] = [
        // https://zoom.us/j/123…, https://us02web.zoom.us/j/123…?pwd=…,
        // https://acme.zoom.us/my/room, /s/ (host start), /w/ (webinar),
        // /wc/join/ (web client).
        Service(host: "zoom.us", subdomains: true, path: zoomPath),
        Service(host: "zoomgov.com", subdomains: true, path: zoomPath),
        // https://meet.google.com/abc-defg-hij, and /lookup/ for a named one.
        Service(host: "meet.google.com", subdomains: false) { path in
            path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}/?$"#, options: .regularExpression) != nil
                || path.hasPrefix("/lookup/")
        },
        // https://teams.microsoft.com/l/meetup-join/19%3ameeting_…, and the
        // newer short form https://teams.microsoft.com/meet/123…?p=….
        Service(host: "teams.microsoft.com", subdomains: false) { path in
            path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/")
        },
        Service(host: "teams.live.com", subdomains: false) { $0.hasPrefix("/meet/") },
        // https://facetime.apple.com/join#v=1&p=…
        Service(host: "facetime.apple.com", subdomains: false) { $0 == "/join" || $0.hasPrefix("/join/") },
        // https://acme.webex.com/acme/j.php?MTID=…, https://acme.webex.com/meet/name,
        // https://acme.webex.com/wbxmjs/joinservice/…; never the bare home page.
        Service(host: "webex.com", subdomains: true) { path in
            path.hasSuffix("/j.php") || path.contains("/meet/") || path.contains("/join/")
                || path.hasPrefix("/wbxmjs/joinservice/")
        },
        // https://meet.goto.com/123456789, https://global.gotomeeting.com/join/123456789
        Service(host: "meet.goto.com", subdomains: false) { $0.count > 1 },
        Service(host: "gotomeeting.com", subdomains: true) { $0.hasPrefix("/join/") },
        // https://whereby.com/room-name
        Service(host: "whereby.com", subdomains: false) { $0.count > 1 },
        // https://meet.jit.si/RoomName
        Service(host: "meet.jit.si", subdomains: false) { $0.count > 1 },
        // https://chime.aws/1234567890
        Service(host: "chime.aws", subdomains: false) { $0.count > 1 },
    ]

    private static func zoomPath(_ path: String) -> Bool {
        ["/j/", "/my/", "/s/", "/w/", "/wc/join/"].contains { path.hasPrefix($0) }
    }

    /// The link itself, when it is a meeting on one of the services: web
    /// URL, no user name or password in front of the host, no unusual port,
    /// and an exact host match.
    static func meeting(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 || components.port == 80,
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let path = components.path.isEmpty ? "/" : components.path
        let matches = services.contains { service in
            let onHost = host == service.host || (service.subdomains && host.hasSuffix("." + service.host))
            return onHost && service.path(path)
        }
        return matches ? url : nil
    }

    // MARK: - Free text

    private enum Scan {
        case none
        case one(URL)
        case ambiguous
    }

    /// Hosts worth running the link detector for. Notes can run to kilobytes
    /// (a Teams invitation's boilerplate) and are read for every event in
    /// range on every reload, so text that names none of the services is
    /// passed over without detecting anything.
    private static let hints = ["zoom", "meet.google", "teams.", "facetime", "webex", "goto", "whereby", "jit.si", "chime.aws"]

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Every meeting link in a field, reduced to one if they are all the same
    /// meeting. Invitations repeat their link — once in the body, once under
    /// "Join" — sometimes with the passcode on one copy only, so links are
    /// the same meeting when host and path agree, and the copy carrying a
    /// query (the passcode) is the one kept.
    private static func scan(_ text: String?) -> Scan {
        guard let text, !text.isEmpty else { return .none }
        let lowered = text.lowercased()
        guard hints.contains(where: lowered.contains), let detector else { return .none }

        var found: [URL] = []
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let link = meeting(url) else { continue }
            found.append(link)
        }
        guard let first = found.first else { return .none }

        let key = { (url: URL) -> String in
            let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            return (c?.host?.lowercased() ?? "") + (c?.path ?? "")
        }
        guard found.allSatisfy({ key($0) == key(first) }) else { return .ambiguous }
        return .one(found.first { $0.query != nil || $0.fragment != nil } ?? first)
    }
}
