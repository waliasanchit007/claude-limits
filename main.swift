import Cocoa
import ServiceManagement
import Security

// ClaudeLimits - menu bar meter for Claude session (5h) and weekly (7d) limits.
//
// Discovery is generic: every *.oauth under the token dir (plus its disabled/
// subdir), and every Claude credential in the login Keychain.
//
// Usage is fetched by the cheapest route available per account:
//   1. GET /api/oauth/usage            - FREE, needs the user:profile scope.
//                                        `claude auth login` tokens have it;
//                                        `claude setup-token` tokens do not.
//   2. POST /v1/messages (minimal)     - ~9 tokens (8 in + 1 out). Returns the
//                                        anthropic-ratelimit-unified-* headers.
// Route 2 is skipped entirely in "Never spend tokens" mode.

let TOKEN_DIR = NSString(string: "~/.config/claude-multi-account").expandingTildeInPath
let K_INTERVAL = "refreshMinutes"
let K_HIDDEN = "hiddenProfiles"
let K_SHOW_UNAVAIL = "showUnavailable"
let K_NEVER_SPEND = "neverSpendTokens"
let K_USE_KEYCHAIN = "includeKeychain"

// Measured 2026-10-17: 35,537 input tokens moved 5h utilization by exactly 0.01.
let MEASURED_5H_BUDGET = 3_553_699.0
let TOKENS_PER_PROBE = 9.0

enum Source {
    case tokenFile(String)      // profile name
    case disabledFile(String)
    case keychain(String)       // service name
    var label: String {
        switch self {
        case .tokenFile(let n), .disabledFile(let n): return n
        case .keychain(let s): return s.replacingOccurrences(of: "Claude Code-credentials", with: "login")
                                       .replacingOccurrences(of: "login-", with: "login/")
        }
    }
    var isDisabled: Bool { if case .disabledFile = self { return true }; return false }
    var kind: String {
        switch self {
        case .tokenFile: return "setup-token"
        case .disabledFile: return "disabled"
        case .keychain: return "login"
        }
    }
}

struct Account {
    var source: Source
    var token: String?
    var name: String { source.label }
}

struct Usage {
    var fiveH: Double?
    var sevenD: Double?
    var fiveHReset: Date?
    var sevenDReset: Date?
    var state: String?
    var error: String?
    var free: Bool = false       // fetched without spending tokens
    var checked: Date?
    var available: Bool { error == nil && (fiveH != nil || sevenD != nil) }
}

func meterBar(_ v: Double?, width: Int = 8) -> String {
    guard let v = v else { return String(repeating: "·", count: width) }
    let filled = max(0, min(width, Int((v * Double(width)).rounded())))
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}
func pct(_ v: Double?) -> String { v == nil ? "  ?%" : String(format: "%3.0f%%", v! * 100) }
func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
func relTime(_ d: Date?) -> String {
    guard let d = d else { return "" }
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return "now" }
    let h = s / 3600, m = (s % 3600) / 60
    if h >= 24 { return "\(h / 24)d \(h % 24)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

// Recursively hunt for utilization / reset values without assuming the exact
// schema of /api/oauth/usage (never observed returning 200 here).
func scrapeUsage(_ obj: Any, into u: inout Usage) {
    func assign(_ key: String, _ num: Double) {
        let k = key.lowercased()
        let isFive = k.contains("5h") || k.contains("five") || k.contains("session")
        let isSeven = k.contains("7d") || k.contains("seven") || k.contains("week")
        if k.contains("utiliz") || k.contains("percent") || k.contains("used") {
            let v = num > 1.5 ? num / 100.0 : num    // tolerate 0-100 or 0-1
            if isFive { u.fiveH = u.fiveH ?? v }
            if isSeven { u.sevenD = u.sevenD ?? v }
        }
        if k.contains("reset") || k.contains("expires") {
            let secs = num > 1e11 ? num / 1000.0 : num   // ms or s
            let d = Date(timeIntervalSince1970: secs)
            if isFive { u.fiveHReset = u.fiveHReset ?? d }
            if isSeven { u.sevenDReset = u.sevenDReset ?? d }
        }
    }
    if let dict = obj as? [String: Any] {
        for (k, v) in dict {
            if let n = v as? Double { assign(k, n) }
            else if let n = v as? Int { assign(k, Double(n)) }
            else if let s = v as? String, let n = Double(s) { assign(k, n) }
            else { scrapeUsage(v, into: &u) }
        }
    } else if let arr = obj as? [Any] {
        for v in arr { scrapeUsage(v, into: &u) }
    }
}

final class Controller: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var accounts: [Account] = []
    var results: [String: Usage] = [:]
    var timer: Timer?
    var refreshing = false
    var infoWindow: NSWindow?
    /// Rows are kept as stable references so they can be updated while the menu is
    /// open. Rebuilding the whole menu mid-display would collapse it.
    var accountItems: [String: NSMenuItem] = [:]
    var footerItem: NSMenuItem?
    var menuIsOpen = false
    var lastRefresh: Date?
    /// Set when the user picks "Refresh now": macOS dismisses the menu on any
    /// click, so re-present it once the data lands instead of dead-ending.
    var reopenAfterRefresh = false

    var refreshMinutes: Int {
        get { let v = UserDefaults.standard.object(forKey: K_INTERVAL) as? Int; return v ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: K_INTERVAL); scheduleTimer() }
    }
    var hidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: K_HIDDEN) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: K_HIDDEN) }
    }
    var showUnavailable: Bool {
        get { UserDefaults.standard.object(forKey: K_SHOW_UNAVAIL) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: K_SHOW_UNAVAIL) }
    }
    var forceFreeOnly = false
    /// Off by default: scanning the Keychain triggers a macOS access prompt, which
    /// blocks indefinitely on managed machines where the user cannot approve it.
    var includeKeychain: Bool {
        get { UserDefaults.standard.bool(forKey: K_USE_KEYCHAIN) }
        set { UserDefaults.standard.set(newValue, forKey: K_USE_KEYCHAIN) }
    }
    var neverSpend: Bool {
        get { forceFreeOnly || UserDefaults.standard.bool(forKey: K_NEVER_SPEND) }
        set { UserDefaults.standard.set(newValue, forKey: K_NEVER_SPEND) }
    }

    init(headless: Bool) { super.init(); discover() }

    override init() {
        super.init()
        statusItem.button?.title = "◔ …"
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu
        discover(); rebuildMenu(); refreshAll(); scheduleTimer()
    }

    // MARK: discovery

    func discover() {
        var found: [Account] = []
        let fm = FileManager.default
        for (dir, disabled) in [(TOKEN_DIR, false),
                                ((TOKEN_DIR as NSString).appendingPathComponent("disabled"), true)] {
            let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for f in files.filter({ $0.hasSuffix(".oauth") }).sorted() {
                let name = String(f.dropLast(".oauth".count))
                let path = (dir as NSString).appendingPathComponent(f)
                let tok = (try? String(contentsOfFile: path, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                found.append(Account(source: disabled ? .disabledFile(name) : .tokenFile(name),
                                     token: tok))
            }
        }
        if includeKeychain {
            for svc in keychainServices() {
                if let tok = keychainToken(service: svc), !tok.isEmpty {
                    found.append(Account(source: .keychain(svc), token: tok))
                }
            }
        }
        accounts = found
    }

    func keychainServices() -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecMatchLimit as String: kSecMatchLimitAll,
                                kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrService as String] as? String }
                    .filter { $0.hasPrefix("Claude Code-credentials") }
                    .sorted()
    }

    func keychainToken(service: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = j["claudeAiOauth"] as? [String: Any] else { return nil }
        return o["accessToken"] as? String
    }

    // MARK: fetching

    func scheduleTimer() {
        timer?.invalidate()
        guard refreshMinutes > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(refreshMinutes) * 60,
                                     repeats: true) { [weak self] _ in self?.refreshAll() }
    }

    func refreshAll() {
        guard !refreshing else { return }
        discover()
        let targets = accounts.filter { !hidden.contains($0.name) && !$0.source.isDisabled }
        guard !targets.isEmpty else { rebuildMenu(); return }
        refreshing = true
        if menuIsOpen { updateRows() } else { rebuildMenu() }
        let group = DispatchGroup()
        for a in targets {
            group.enter()
            fetch(a) { u in DispatchQueue.main.async { self.results[a.name] = u; group.leave() } }
        }
        group.notify(queue: .main) {
            self.refreshing = false
            self.lastRefresh = Date()
            self.updateTitle()
            if self.menuIsOpen { self.updateRows() } else { self.rebuildMenu() }
            if self.reopenAfterRefresh {
                self.reopenAfterRefresh = false
                self.statusItem.button?.performClick(nil)
            }
        }
    }

    /// Free route first; paid probe only if allowed.
    func fetch(_ a: Account, done: @escaping (Usage) -> Void) {
        var u = Usage(); u.checked = Date()
        guard let tok = a.token, !tok.isEmpty else {
            u.error = "no token"; done(u); return
        }
        freeUsage(tok) { free in
            if var f = free, f.fiveH != nil || f.sevenD != nil {
                f.free = true; f.checked = Date(); done(f); return
            }
            if self.neverSpend {
                u.error = "needs user:profile scope (free mode)"
                done(u); return
            }
            self.paidProbe(tok, into: u, done: done)
        }
    }

    func freeUsage(_ tok: String, done: @escaping (Usage?) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 25
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let j = try? JSONSerialization.jsonObject(with: data) else { done(nil); return }
            var u = Usage()
            scrapeUsage(j, into: &u)
            done(u)
        }.resume()
    }

    func paidProbe(_ tok: String, into base: Usage, done: @escaping (Usage) -> Void) {
        var u = base
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"; req.timeoutInterval = 30
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = #"{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}"#
            .data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { u.error = err.localizedDescription; done(u); return }
            guard let http = resp as? HTTPURLResponse else { u.error = "no response"; done(u); return }
            func h(_ n: String) -> String? { http.value(forHTTPHeaderField: n) }
            func d(_ n: String) -> Double? { h(n).flatMap(Double.init) }
            u.fiveH = d("anthropic-ratelimit-unified-5h-utilization")
            u.sevenD = d("anthropic-ratelimit-unified-7d-utilization")
            u.fiveHReset = d("anthropic-ratelimit-unified-5h-reset").map { Date(timeIntervalSince1970: $0) }
            u.sevenDReset = d("anthropic-ratelimit-unified-7d-reset").map { Date(timeIntervalSince1970: $0) }
            u.state = h("anthropic-ratelimit-unified-status")
            if http.statusCode != 200 && u.fiveH == nil {
                var msg = "HTTP \(http.statusCode)"
                if let data = data,
                   let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let e = j["error"] as? [String: Any], let m = e["message"] as? String { msg = m }
                u.error = msg
            }
            done(u)
        }.resume()
    }

    // MARK: UI

    func updateTitle() {
        let vals = accounts.filter { !hidden.contains($0.name) }
                           .compactMap { results[$0.name]?.sevenD }
        guard let worst = vals.max() else { statusItem.button?.title = "◔ —"; return }
        let g = worst >= 0.9 ? "●" : (worst >= 0.75 ? "◕" : (worst >= 0.5 ? "◑" : "◔"))
        statusItem.button?.title = "\(g) \(Int((worst * 100).rounded()))%"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Structure is rebuilt only before the menu is shown, never during.
        if !menuIsOpen { rebuildMenu() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        // Auto-refresh on open so "Refresh now" is rarely needed. Guarded by
        // staleness so repeatedly opening the menu cannot run up a token bill.
        let stale = lastRefresh.map { Date().timeIntervalSince($0) > 60 } ?? true
        if stale { refreshAll() }
    }

    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    /// Renders one account row. Used both when building the menu and when
    /// updating it live, so the two can never drift apart.
    func applyRow(_ item: NSMenuItem, _ a: Account) {
        var attrs: [NSAttributedString.Key: Any] =
            [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
        let u = results[a.name]
        let line: String
        if a.source.isDisabled {
            line = pad(a.name, 11) + "  — disabled"
            attrs[.foregroundColor] = NSColor.tertiaryLabelColor
        } else if let e = u?.error {
            line = pad(a.name, 11) + "  ⚠ " + e
            attrs[.foregroundColor] = NSColor.systemRed
        } else if let u = u {
            line = pad(a.name, 11) + "  "
                 + meterBar(u.fiveH) + " " + pct(u.fiveH) + " " + pad(relTime(u.fiveHReset), 6)
                 + "  " + meterBar(u.sevenD) + " " + pct(u.sevenD) + " " + pad(relTime(u.sevenDReset), 6)
                 + (u.free ? "  free" : "")
            if u.state == "rejected" || (u.sevenD ?? 0) >= 0.9 { attrs[.foregroundColor] = NSColor.systemRed }
            else if u.state == "allowed_warning" || (u.sevenD ?? 0) >= 0.75 { attrs[.foregroundColor] = NSColor.systemOrange }
        } else {
            line = pad(a.name, 11) + "  checking…"
            attrs[.foregroundColor] = NSColor.secondaryLabelColor
        }
        item.attributedTitle = NSAttributedString(string: line, attributes: attrs)
    }

    func applyFooter(_ item: NSMenuItem) {
        let mono: [NSAttributedString.Key: Any] =
            [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
             .foregroundColor: NSColor.secondaryLabelColor]
        let text: String
        if refreshing { text = "refreshing…" }
        else if let l = results.values.compactMap({ $0.checked }).max() {
            let s = max(0, Int(-l.timeIntervalSinceNow))
            text = s < 60 ? "updated just now" : "updated \(s / 60)m ago"
        } else { text = "not yet updated" }
        item.attributedTitle = NSAttributedString(string: text, attributes: mono)
    }

    /// Safe to call while the menu is open - mutates existing items only.
    func updateRows() {
        for a in accounts {
            if let item = accountItems[a.name] { applyRow(item, a) }
        }
        if let f = footerItem { applyFooter(f) }
    }

    func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        let mono: [NSAttributedString.Key: Any] =
            [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
        let monoBold: [NSAttributedString.Key: Any] =
            [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)]

        func row(_ s: String, _ attrs: [NSAttributedString.Key: Any]) {
            let i = NSMenuItem(); i.attributedTitle = NSAttributedString(string: s, attributes: attrs)
            i.isEnabled = false; menu.addItem(i)
        }

        row("account      session(5h)         weekly(7d)", monoBold)
        menu.addItem(.separator())

        accountItems.removeAll()
        var shownAny = false, hiddenCount = 0
        for a in accounts {
            let u = results[a.name]
            let unavailable = a.source.isDisabled || (u != nil && !u!.available)
            if unavailable && !showUnavailable { hiddenCount += 1; continue }
            if hidden.contains(a.name) { hiddenCount += 1; continue }
            shownAny = true
            let item = NSMenuItem()
            item.isEnabled = false
            applyRow(item, a)
            menu.addItem(item)
            accountItems[a.name] = item
        }
        if !shownAny { row("  no accounts to show", mono) }
        if hiddenCount > 0 { row("  (\(hiddenCount) hidden)", mono) }

        menu.addItem(.separator())
        let foot = NSMenuItem()
        foot.isEnabled = false
        applyFooter(foot)
        menu.addItem(foot)
        footerItem = foot

        add(menu, "Refresh now", #selector(doRefresh), key: "r")

        // Everything configurable lives under one Settings submenu so the main
        // menu stays just: data, refresh, settings, about, quit.
        let settings = NSMenu()

        let iv = NSMenu()
        for m in [0, 15, 30, 60, 180] {
            let mi = NSMenuItem(title: m == 0 ? "Manual only" : "Every \(m) min",
                                action: #selector(setInterval(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = m; mi.state = (m == refreshMinutes) ? .on : .off
            iv.addItem(mi)
        }
        let ivItem = NSMenuItem(title: "Refresh rate", action: nil, keyEquivalent: "")
        settings.setSubmenu(iv, for: ivItem); settings.addItem(ivItem)

        let pm = NSMenu()
        for a in accounts {
            let mi = NSMenuItem(title: "\(a.name)  (\(a.source.kind))",
                                action: #selector(toggleProfile(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = a.name
            mi.state = hidden.contains(a.name) ? .off : .on
            pm.addItem(mi)
        }
        let pmItem = NSMenuItem(title: "Accounts", action: nil, keyEquivalent: "")
        settings.setSubmenu(pm, for: pmItem); settings.addItem(pmItem)

        settings.addItem(.separator())

        let su = NSMenuItem(title: "Show unavailable accounts",
                            action: #selector(toggleUnavailable), keyEquivalent: "")
        su.target = self; su.state = showUnavailable ? .on : .off
        settings.addItem(su)

        let ns = NSMenuItem(title: "Never spend tokens",
                            action: #selector(toggleNeverSpend), keyEquivalent: "")
        ns.target = self; ns.state = neverSpend ? .on : .off
        settings.addItem(ns)

        let kc = NSMenuItem(title: "Include Keychain logins",
                            action: #selector(toggleKeychain), keyEquivalent: "")
        kc.target = self; kc.state = includeKeychain ? .on : .off
        settings.addItem(kc)

        settings.addItem(.separator())

        let li = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        li.target = self
        li.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        settings.addItem(li)

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        menu.setSubmenu(settings, for: settingsItem)
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        add(menu, "About usage & cost…", #selector(showInfo), key: "i")
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String) {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.target = self; menu.addItem(i)
    }

    // MARK: actions

    @objc func doRefresh() {
        reopenAfterRefresh = true
        lastRefresh = nil           // force, ignoring the staleness guard
        refreshAll()
    }
    @objc func setInterval(_ s: NSMenuItem) { refreshMinutes = s.tag; rebuildMenu() }
    @objc func toggleUnavailable() { showUnavailable.toggle(); rebuildMenu() }
    @objc func toggleKeychain() {
        includeKeychain.toggle()
        if includeKeychain {
            let a = NSAlert()
            a.messageText = "macOS will ask for Keychain access"
            a.informativeText = "Scanning for login credentials prompts for access to the "
                + "'Claude Code-credentials' items. On a managed machine you may not be able "
                + "to approve this. If no prompt appears or you cannot approve it, turn this "
                + "back off - nothing else is affected."
            a.runModal()
        }
        discover(); rebuildMenu(); refreshAll()
    }

    @objc func toggleNeverSpend() { neverSpend.toggle(); rebuildMenu(); refreshAll() }
    @objc func toggleProfile(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String else { return }
        var h = hidden; if h.contains(n) { h.remove(n) } else { h.insert(n) }
        hidden = h; updateTitle(); rebuildMenu()
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(); a.messageText = "Could not change login item"
            a.informativeText = error.localizedDescription; a.runModal()
        }
        rebuildMenu()
    }

    @objc func showInfo() {
        let active = accounts.filter { !hidden.contains($0.name) && !$0.source.isDisabled }.count
        let perRefresh = Double(active) * TOKENS_PER_PROBE
        let perDay = refreshMinutes == 0 ? 0 : (1440.0 / Double(refreshMinutes)) * perRefresh
        let dailyBudget = MEASURED_5H_BUDGET * (24.0 / 5.0)
        let anyFree = results.values.contains { $0.free }

        let text = """
        HOW USAGE IS READ

        The app tries the cheapest route available for each account:

        1. GET /api/oauth/usage  —  FREE, no tokens.
           Requires the 'user:profile' OAuth scope. Credentials from
           `claude auth login` carry it; credentials from
           `claude setup-token` do NOT, and return 403.
           Currently in use: \(anyFree ? "yes, for at least one account" : "no account qualifies")

        2. POST /v1/messages  —  ~9 tokens (8 input + 1 output).
           The anthropic-ratelimit-unified-* headers come back only on a
           real inference call. count_tokens, a malformed 400 and a bad
           model 404 all return no such headers — this is the floor.
           Turn on "Never spend tokens" to disable this route entirely;
           accounts without the free scope then show as unavailable.

        WHAT IT COSTS NOW

           keychain scan     \(includeKeychain ? "on" : "off (no prompt)")
           accounts polled   \(active)
           per refresh       \(Int(perRefresh)) tokens
           refresh rate      \(refreshMinutes == 0 ? "manual only" : "every \(refreshMinutes) min")
           per day           \(refreshMinutes == 0 ? "0 while idle" : "\(Int(perDay)) tokens")
           share of capacity \(refreshMinutes == 0 ? "0%" : String(format: "%.4f%%", perDay / dailyBudget * 100))

        HOW THE BUDGET WAS MEASURED

        The API reports utilization only as a fraction, never an absolute
        budget. Measured 2026-10-17: 35,537 input tokens moved the 5h
        utilization by exactly 0.01, giving a session budget of ~3.55M
        tokens (~17M/day equivalent). Reporting resolution is 0.01, so the
        true figure lies in roughly 2.4M–7.1M; the percentages above could
        be off by ~2x and remain negligible.

        WHAT THE COLUMNS MEAN

        session(5h)  rolling 5-hour window, with time until it resets
        weekly(7d)   rolling 7-day window, with time until it resets
        orange       >=75% used, or the API returned allowed_warning
        red          >=90% used, rejected, or the account errored
        free         fetched with no token cost
        """
        if infoWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Claude Limits — usage & cost"
            w.isReleasedWhenClosed = false
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 640))
            tv.isEditable = false
            tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.textContainerInset = NSSize(width: 16, height: 16)
            let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 640))
            sv.documentView = tv; sv.hasVerticalScroller = true
            sv.autoresizingMask = [.width, .height]
            w.contentView = sv
            infoWindow = w
        }
        if let sv = infoWindow?.contentView as? NSScrollView,
           let tv = sv.documentView as? NSTextView { tv.string = text }
        infoWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        infoWindow?.makeKeyAndOrderFront(nil)
    }
}

// --enable-login / --disable-login: manage the login item, then exit.
if CommandLine.arguments.contains("--enable-login") || CommandLine.arguments.contains("--disable-login") {
    let on = CommandLine.arguments.contains("--enable-login")
    do {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        print("login item \(on ? "enabled" : "disabled"); status=\(SMAppService.mainApp.status.rawValue)")
        exit(0)
    } catch {
        print("SMAppService failed: \(error.localizedDescription)")
        exit(3)
    }
}

// --once: print the table and exit. Same routes, same costs.
if CommandLine.arguments.contains("--once") {
    let c = Controller(headless: true)
    c.forceFreeOnly = CommandLine.arguments.contains("--free-only")
    let group = DispatchGroup()
    var out: [(String, Usage)] = []
    let lock = NSLock()
    for a in c.accounts where !a.source.isDisabled {
        group.enter()
        c.fetch(a) { u in lock.lock(); out.append((a.name, u)); lock.unlock(); group.leave() }
    }
    group.wait()
    print("account      session(5h)             weekly(7d)")
    for (n, u) in out.sorted(by: { $0.0 < $1.0 }) {
        if let e = u.error { print(pad(n, 11) + "  ! " + e) }
        else {
            print(pad(n, 11) + "  "
                + meterBar(u.fiveH) + " " + pct(u.fiveH) + " " + pad(relTime(u.fiveHReset), 7)
                + "  " + meterBar(u.sevenD) + " " + pct(u.sevenD) + " " + pad(relTime(u.sevenDReset), 7)
                + "  " + (u.free ? "free" : (u.state ?? "")))
        }
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.run()
