// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
import CryptoKit
import Foundation
import SQLite3

let rexui = RexuiBackend()

let args = CommandLine.arguments
let browser = args.count > 1 && !args[1].isEmpty ? args[1] : "zen"
let every = max(2.0, Double(args.count > 2 ? args[2] : "") ?? 5) * 60

func log(_ s: String) { FileHandle.standardError.write(("endfield-skport: " + s + "\n").data(using: .utf8)!) }
func emit(_ obj: [String: Any]) {
    rexui.emit(obj)
}

func profileFolders() -> [String] {
    let roots = [
        "zen": "~/Library/Application Support/zen/Profiles",
        "firefox": "~/Library/Application Support/Firefox/Profiles",
    ]
    let dir = ((roots[browser.lowercased()] ?? browser) as NSString).expandingTildeInPath
    let fm = FileManager.default
    if fm.fileExists(atPath: dir + "/cookies.sqlite") { return [dir] }
    let all = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).map { dir + "/" + $0 }.filter {
        fm.fileExists(atPath: $0 + "/cookies.sqlite")
    }
    func mtime(_ p: String) -> Date {
        ((try? fm.attributesOfItem(atPath: p + "/cookies.sqlite"))?[.modificationDate] as? Date) ?? .distantPast
    }
    return all.sorted { mtime($0) > mtime($1) }
}

func readCred() -> String? {
    let fm = FileManager.default
    for p in profileFolders() {
        let tmp = NSTemporaryDirectory() + "endfield-skport-" + UUID().uuidString
        guard
            (try? fm.createDirectory(
                atPath: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil
        else { continue }
        defer { try? fm.removeItem(atPath: tmp) }
        for ext in ["", "-wal"] where fm.fileExists(atPath: p + "/cookies.sqlite" + ext) {
            try? fm.copyItem(atPath: p + "/cookies.sqlite" + ext, toPath: tmp + "/c.sqlite" + ext)
        }
        var db: OpaquePointer?
        guard sqlite3_open(tmp + "/c.sqlite", &db) == SQLITE_OK else {
            sqlite3_close(db)
            continue
        }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        let q =
            "SELECT value FROM moz_cookies WHERE name = 'SK_OAUTH_CRED_KEY' AND host LIKE '%skport.com' ORDER BY lastAccessed DESC LIMIT 1"
        guard sqlite3_prepare_v2(db, q, -1, &st, nil) == SQLITE_OK else { continue }
        defer { sqlite3_finalize(st) }
        if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
            let v = String(cString: c)
            if !v.isEmpty { return v }
        }
    }
    return nil
}

let host = "https://zonai.skport.com"
var cred: String?
var token = ""
var gameRole = ""

struct Reply {
    var code: Int
    var message: String
    var data: Any?
    var http: Int
}

let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 20
    c.httpCookieAcceptPolicy = .never
    c.httpShouldSetCookies = false
    return URLSession(configuration: c)
}()

func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }

func fetch(_ path: String, query: String = "", signed: Bool = true) -> Reply {
    guard let cred, let url = URL(string: host + path + (query.isEmpty ? "" : "?" + query)) else {
        return Reply(code: -1, message: "no login", data: nil, http: 0)
    }
    var r = URLRequest(url: url)
    let ts = String(Int(Date().timeIntervalSince1970))
    let h: [String: String] = [
        "Accept": "application/json", "Content-Type": "application/json",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:147.0) Gecko/20100101 Firefox/147.0",
        "Origin": "https://game.skport.com", "Referer": "https://game.skport.com/",
        "platform": "3", "vName": "1.0.0", "cred": cred, "sk-language": "en", "timestamp": ts,
    ]
    for (k, v) in h { r.setValue(v, forHTTPHeaderField: k) }
    if !gameRole.isEmpty { r.setValue(gameRole, forHTTPHeaderField: "sk-game-role") }
    if signed {
        let hj = "{\"platform\":\"3\",\"timestamp\":\"\(ts)\",\"dId\":\"\",\"vName\":\"1.0.0\"}"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data((path + query + ts + hj).utf8), using: SymmetricKey(data: Data(token.utf8)))
        r.setValue(hex(Insecure.MD5.hash(data: Data(hex(mac).utf8))), forHTTPHeaderField: "sign")
    }
    var out = Reply(code: -1, message: "no answer", data: nil, http: 0)
    let done = DispatchSemaphore(value: 0)
    session.dataTask(with: r) { body, resp, err in
        defer { done.signal() }
        out.http = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if let err {
            out.message = err.localizedDescription
            return
        }
        guard let body, let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            out.message = "HTTP \(out.http)"
            return
        }
        out.code = (j["code"] as? NSNumber)?.intValue ?? -1
        out.message = j["message"] as? String ?? ""
        out.data = j["data"]
    }.resume()
    done.wait()
    return out
}

func refreshToken() -> Bool {
    let r = fetch("/web/v1/auth/refresh", signed: false)
    token = ((r.data as? [String: Any])?["token"] as? String) ?? ""
    if token.isEmpty { log("refresh: \(r.code) \(r.message)") }
    return !token.isEmpty
}

func read(_ path: String, query: String = "") -> Reply {
    var r = fetch(path, query: query)
    if [10000, 10002, 10003].contains(r.code), refreshToken() { r = fetch(path, query: query) }
    return r
}

func dict(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }
func list(_ v: Any?) -> [[String: Any]] { v as? [[String: Any]] ?? [] }
func str(_ v: Any?) -> String { v as? String ?? (v as? NSNumber)?.stringValue ?? "" }
func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? Double(v as? String ?? "") ?? 0 }
func int(_ v: Any?) -> Int { Int(num(v)) }
func ms(_ v: Any?) -> Double {
    let s = num(v)
    return s > 1e11 ? s : s * 1000
}
var names: [String: String] = [:]
func named(_ v: Any?) -> String {
    let d = dict(v)
    if let k = d["key"] as? String, let n = names[k] { return n }
    return str(d["value"]).isEmpty ? str(v) : str(d["value"])
}
func rarity(_ v: Any?) -> Int {
    let s = (v as? [String: Any]).map { str($0["key"]) } ?? str(v)
    return Int(s.split(separator: "_").last ?? "") ?? int(dict(v)["value"])
}

let picDir: String? = args.count > 3 && !args[3].isEmpty ? (args[3] as NSString).expandingTildeInPath : nil
var pending: [String: String] = [:]
let picSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 30
    c.httpCookieAcceptPolicy = .never
    c.httpShouldSetCookies = false
    return URLSession(configuration: c)
}()

func local(_ url: String) -> String {
    guard let dir = picDir, url.hasPrefix("https://static.skport.com/"), !url.contains("..") else { return url }
    let name = url.split(separator: "?")[0].split(separator: "/").suffix(2).joined(separator: "-")
    let path = dir + "/" + name
    if FileManager.default.fileExists(atPath: path) { return path }
    pending[url] = path
    return url
}

func localized(_ v: Any) -> Any {
    if let s = v as? String { return local(s) }
    if let d = v as? [String: Any] { return d.mapValues(localized) }
    if let a = v as? [Any] { return a.map(localized) }
    return v
}

func fetchPictures() -> Bool {
    guard let dir = picDir, !pending.isEmpty else { return false }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let jobs = Array(pending)
    pending.removeAll()
    let lock = NSLock()
    var got = 0
    let group = DispatchGroup()
    let slots = DispatchSemaphore(value: 6)
    for (url, path) in jobs {
        guard let u = URL(string: url) else { continue }
        slots.wait()
        group.enter()
        picSession.dataTask(with: u) { body, resp, _ in
            defer {
                slots.signal()
                group.leave()
            }
            guard let body, (resp as? HTTPURLResponse)?.statusCode == 200, !body.isEmpty else { return }
            let part = path + ".part"
            if (try? body.write(to: URL(fileURLWithPath: part))) != nil, rename(part, path) == 0 {
                lock.lock()
                got += 1
                lock.unlock()
            }
        }.resume()
    }
    group.wait()
    if got < jobs.count { log("pictures: \(got) of \(jobs.count) came") }
    return got > 0
}

var state: [String: Any] = ["status": "loading"]
var lastSlow = Date.distantPast
var bannerNames: [String: String] = [:]

func readEnums() {
    let r = read("/web/v1/game/endfield/enums")
    for (_, v) in dict(r.data) { for e in list(v) { if let k = e["key"] as? String { names[k] = str(e["value"]) } } }
}

func readAccount() {
    let u = dict(dict(read("/web/v2/user").data)["user"])
    let b = dict(u["basicUser"])
    let p = dict(u["pendant"])
    state["account"] = ["name": str(b["nickname"]), "avatar": str(b["avatar"]), "frame": str(p["iconUrl"])]
}

func entryName(_ link: String) -> String {
    guard let id = URLComponents(string: link)?.queryItems?.first(where: { $0.name == "gameEntryId" })?.value else {
        return ""
    }
    if let n = bannerNames[id] { return n }
    let n = str(dict(dict(read("/web/v1/wiki/item/info", query: "id=" + id).data)["item"])["name"])
    if !n.isEmpty { bannerNames[id] = n }
    return n
}

func readBanners() {
    var out: [[String: Any]] = []
    for (kind, path, items) in [
        ("operator", "/web/v1/wiki/char-pool", "chars"), ("weapon", "/web/v1/wiki/weapon-pool", "weapons"),
    ] {
        for pool in list(dict(read(path).data)["list"]) {
            let featured: [[String: Any]] = list(pool[items]).map { c in
                let n = str(c["name"])
                return [
                    "name": n.isEmpty ? entryName(str(c["pcLink"])) : n, "rarity": rarity(c["rarity"]),
                    "pic": str(c["pic"]),
                    "up": str(c["dotType"]) == "label_type_up",
                ]
            }
            out.append([
                "kind": kind, "name": str(pool["name"]), "start": ms(pool["poolStartAtTs"] ?? pool["startAtTs"]),
                "end": ms(pool["poolEndAtTs"] ?? pool["endAtTs"]), "featured": featured,
            ])
        }
    }
    state["banners"] = out
}

func findRole() -> Bool {
    for app in list(dict(read("/api/v1/game/player/binding").data)["list"]) where str(app["appCode"]) == "endfield" {
        for b in list(app["bindingList"]) {
            let r = b["defaultRole"] as? [String: Any] ?? list(b["roles"]).first
            if let r, !str(r["roleId"]).isEmpty {
                gameRole = "3_\(str(r["roleId"]))_\(str(r["serverId"]))"
                return true
            }
        }
    }
    gameRole = ""
    return false
}

func gear(_ slot: String, _ v: Any?) -> [String: Any]? {
    let d = dict(v)
    guard !d.isEmpty else { return nil }
    let data = dict(d["equipData"] ?? d["itemData"] ?? d["data"])
    let src = data.isEmpty ? d : data
    let name = str(src["name"])
    guard !name.isEmpty else { return nil }
    return [
        "slot": slot, "name": name, "icon": str(src["iconUrl"] ?? src["icon"]),
        "level": int(src["level"] ?? d["level"]),
    ]
}

func readCard() -> Bool {
    let parts = gameRole.split(separator: "_")
    guard parts.count == 3 else { return false }
    let r = read("/api/v1/game/endfield/card/detail", query: "roleId=\(parts[1])&serverId=\(parts[2])")
    let detail = dict(dict(r.data)["detail"])
    guard r.code == 0, !detail.isEmpty else {
        log("card: \(r.code) \(r.message) (HTTP \(r.http))")
        return false
    }
    let now = Date().timeIntervalSince1970 * 1000
    let base = dict(detail["base"])
    state["role"] = [
        "name": str(base["name"]), "uid": str(base["roleId"]), "server": str(base["serverName"]),
        "level": int(base["level"]), "worldLevel": int(base["worldLevel"]), "exp": int(base["exp"]),
        "avatar": str(base["avatarUrl"]), "mission": str(dict(base["mainMission"])["description"]),
        "operators": int(base["charNum"]), "weapons": int(base["weaponNum"]), "documents": int(base["docNum"]),
        "created": ms(base["createTime"]), "lastLogin": ms(base["lastLoginTime"]), "saved": ms(base["saveTime"]),
    ]
    let dg = dict(detail["dungeon"])
    let cur = int(dg["curStamina"])
    let mx = int(dg["maxStamina"])
    let full = ms(dg["maxTs"])
    let left = full > now ? full : 0
    state["sanity"] = [
        "cur": cur, "max": mx, "fullAt": left, "perPoint": left > 0 && mx > cur ? (left - now) / Double(mx - cur) : 0,
    ]
    let dm = dict(detail["dailyMission"])
    let bp = dict(detail["bpSystem"])
    state["daily"] = ["cur": int(dm["dailyActivation"]), "max": int(dm["maxDailyActivation"])]
    state["pass"] = ["cur": int(bp["curLevel"]), "max": int(bp["maxLevel"])]
    state["achievements"] = int(dict(detail["achieve"])["count"])
    state["ship"] = list(dict(detail["spaceShip"])["rooms"]).map {
        ["type": str($0["type"]), "level": int($0["level"])]
    }
    state["regions"] = list(detail["domain"]).map { d -> [String: Any] in
        var c: [String: Int] = ["puzzles": 0, "chests": 0, "pieces": 0, "blackboxes": 0]
        for x in list(d["collections"]) {
            c["puzzles"]! += int(x["puzzleCount"])
            c["chests"]! += int(x["trchestCount"])
            c["pieces"]! += int(x["pieceCount"])
            c["blackboxes"]! += int(x["blackboxCount"])
        }
        var o: [String: Any] = [
            "name": str(d["name"]), "level": int(d["level"]),
            "settlements": list(d["settlements"]).map { ["name": str($0["name"]), "level": int($0["level"])] },
        ]
        for (k, v) in c { o[k] = v }
        return o
    }
    state["operators"] = list(detail["chars"]).map { ch -> [String: Any] in
        let cd = dict(ch["charData"])
        let us = dict(ch["userSkills"])
        let skills: [[String: Any]] = list(cd["skills"]).map { s in
            let u = dict(us[str(s["id"])])
            return [
                "name": str(s["name"]), "type": named(s["type"]), "level": int(u["level"]), "max": int(u["maxLevel"]),
                "icon": str(s["iconUrl"]),
                "element": named(s["property"]),
            ]
        }
        let w = dict(ch["weapon"])
        let wd = dict(w["weaponData"])
        let weapon: Any =
            wd.isEmpty
            ? NSNull()
            : [
                "name": str(wd["name"]), "icon": str(wd["iconUrl"]), "rarity": rarity(wd["rarity"]),
                "level": int(w["level"]),
                "refine": int(w["refineLevel"]), "breakthrough": int(w["breakthroughLevel"]),
                "essence": str(dict(w["gem"])["icon"]),
                "type": named(wd["type"]),
                "skills": list(w["skills"]).map {
                    ["name": str($0["name"]), "level": int($0["level"]), "max": int($0["currentMaxLevel"])]
                },
            ]
        let kit = [
            ("Armor", ch["bodyEquip"]), ("Gloves", ch["armEquip"]), ("Kit", ch["firstAccessory"]),
            ("Kit", ch["secondAccessory"]),
            ("Tactical", ch["tacticalItem"]),
        ].compactMap { gear($0.0, $0.1) }
        return [
            "id": str(cd["id"]), "name": str(cd["name"]), "rarity": rarity(cd["rarity"]),
            "class": named(cd["profession"]),
            "element": named(cd["property"]), "weaponType": named(cd["weaponType"]), "level": int(ch["level"]),
            "promotion": int(ch["evolvePhase"]), "potential": int(ch["potentialLevel"]),
            "avatar": str(cd["avatarSqUrl"]),
            "round": str(cd["avatarRtUrl"]), "art": str(cd["illustrationUrl"]),
            "limited": str(cd["labelType"]) == "label_type_up",
            "owned": ms(ch["ownTs"]), "skills": skills, "gear": kit, "weapon": weapon,
            "tags": (cd["tags"] as? [Any] ?? []).map { str($0) }.filter { !$0.isEmpty },
        ]
    }.sorted { (int($0["rarity"]), int($0["level"])) > (int($1["rarity"]), int($1["level"])) }
    return true
}

func readCheckin() {
    let r = read("/web/v1/game/endfield/attendance")
    let d = dict(r.data)
    guard r.code == 0, !d.isEmpty else {
        state["checkin"] = NSNull()
        return
    }
    let info = dict(d["resourceInfoMap"])
    let cal = list(d["calendar"])
    var days: [[String: Any]] = []
    var today = false
    for (i, e) in cal.enumerated() {
        let res = dict(info[str(e["awardId"])])
        let done = (e["done"] as? Bool) ?? false
        let avail = (e["available"] as? Bool) ?? false
        if avail { today = true }
        days.append([
            "day": i + 1, "done": done, "today": avail, "name": str(res["name"]), "icon": str(res["icon"]),
            "count": int(res["count"]),
        ])
    }
    let doneToday = (d["hasToday"] as? Bool) ?? !today
    state["checkin"] = ["today": doneToday, "done": days.filter { $0["done"] as? Bool == true }.count, "days": days]
}

func cycle(_ force: Bool) {
    if cred == nil || token.isEmpty {
        cred = readCred()
        guard cred != nil else {
            state = [
                "status": "nologin", "message": "Log in to SKPort in your browser",
                "asOf": Date().timeIntervalSince1970 * 1000,
            ]
            emit(["state": state])
            return
        }
        guard refreshToken() else {
            cred = nil
            state["status"] = "nologin"
            state["message"] = "SKPort's login has expired: log in again in your browser"
            emit(["state": state])
            return
        }
    }
    if force || Date().timeIntervalSince(lastSlow) > 3600 {
        lastSlow = Date()
        readEnums()
        readAccount()
        readBanners()
    }
    if gameRole.isEmpty && !findRole() {
        state["status"] = "unlinked"
        state["role"] = NSNull()
        state["message"] = "No Endfield character on SKPort yet: finish the tutorial, then link it on game.skport.com"
    } else if readCard() {
        readCheckin()
        state["status"] = "ok"
        state["message"] = ""
    } else {
        gameRole = ""
        state["status"] = "error"
        state["message"] = "SKPort didn't answer for your character"
    }
    state["asOf"] = Date().timeIntervalSince1970 * 1000
    state = localized(state) as? [String: Any] ?? state
    emit(["state": state])
    if fetchPictures() {
        state = localized(state) as? [String: Any] ?? state
        emit(["state": state])
    }
}

let demo = browser.lowercased() == "demo"
let demoStart = Date().timeIntervalSince1970 * 1000

func demoOperator(
    _ id: Int, _ name: String, _ rarity: Int, _ cls: String, _ element: String, _ weaponType: String,
    _ level: Int, _ promotion: Int, _ potential: Int, _ weapon: String, _ weaponRarity: Int, _ tags: [String],
    daysOwned: Double
) -> [String: Any] {
    let types = ["Basic Attack", "Battle Skill", "Combo Skill", "Ultimate"]
    let skillNames = ["Edge Pattern", "Cascade", "Relay Strike", "Final Directive"]
    let skills: [[String: Any]] = types.enumerated().map { i, t in
        [
            "name": skillNames[i], "type": t, "level": max(1, min(12, promotion * 3 + (level + i) % 4)), "max": 12,
            "icon": "", "element": element,
        ]
    }
    let gear: [[String: Any]] = [
        ("Armor", "Survey Plate Mk II"), ("Gloves", "Grip Weave Gloves"), ("Kit", "Field Relay Kit"),
        ("Kit", "Signal Beacon"), ("Tactical", "Stim Canister"),
    ].prefix(promotion + 1).map {
        ["slot": $0.0, "name": $0.1, "icon": "", "level": max(1, level / 10)]
    }
    return [
        "id": "demo-op-\(id)", "name": name, "rarity": rarity, "class": cls, "element": element,
        "weaponType": weaponType,
        "level": level, "promotion": promotion, "potential": potential, "avatar": "", "round": "", "art": "",
        "limited": rarity == 6 && id % 2 == 0, "owned": demoStart - daysOwned * 86_400_000, "tags": tags,
        "skills": skills, "gear": gear,
        "weapon": [
            "name": weapon, "icon": "", "rarity": weaponRarity, "level": max(1, level - 10), "refine": promotion,
            "breakthrough": promotion, "essence": "", "type": weaponType,
            "skills": [
                ["name": "Attack Boost", "level": promotion + 1, "max": 9],
                ["name": "Steady Hand", "level": max(1, promotion), "max": 9],
            ],
        ],
    ]
}

func demoState() -> [String: Any] {
    let now = Date().timeIntervalSince1970 * 1000
    let day = 86_400_000.0
    let perPoint = 360_000.0
    let maxSan = 240
    let start = 132
    let cur = min(maxSan, start + Int((now - demoStart) / perPoint))
    let fullAt = demoStart + Double(maxSan - start) * perPoint
    let operators = [
        demoOperator(
            1, "Corvina", 6, "Guard", "Heat", "Greatsword", 80, 4, 3, "Ember Verdict", 6, ["Burst", "Heat"],
            daysOwned: 58),
        demoOperator(
            2, "Isolde Vane", 6, "Caster", "Cryo", "Arts Unit", 70, 3, 1, "Frostline Codex", 6, ["Control", "Cryo"],
            daysOwned: 31),
        demoOperator(
            3, "Halde", 5, "Defender", "Physical", "Sword", 60, 3, 5, "Bulwark Edge", 5, ["Shield", "Protection"],
            daysOwned: 55),
        demoOperator(
            4, "Mireille", 5, "Supporter", "Nature", "Arts Unit", 60, 2, 2, "Verdant Index", 5, ["Healing", "Nature"],
            daysOwned: 49),
        demoOperator(
            5, "Oskar Renn", 5, "Striker", "Electric", "Handcannon", 50, 2, 0, "Arc Repeater", 5,
            ["Electric", "Combo"], daysOwned: 40),
        demoOperator(
            6, "Tamsin", 5, "Vanguard", "Heat", "Polearm", 50, 2, 1, "Signal Pike", 4, ["Energy", "Heat"], daysOwned: 37
        ),
        demoOperator(
            7, "Reyka", 4, "Guard", "Physical", "Sword", 40, 1, 4, "Cutter Blade", 4, ["Physical"], daysOwned: 52),
        demoOperator(
            8, "Juno Ashe", 4, "Caster", "Electric", "Arts Unit", 40, 1, 3, "Static Folio", 4, ["Electric"],
            daysOwned: 44),
        demoOperator(
            9, "Bram", 4, "Defender", "Cryo", "Greatsword", 30, 1, 2, "Icebreaker", 3, ["Shield", "Cryo"], daysOwned: 26
        ),
        demoOperator(
            10, "Pell", 3, "Supporter", "Nature", "Handcannon", 20, 0, 5, "Field Sprayer", 3, ["Healing"], daysOwned: 57
        ),
    ]
    let cal = Calendar.current
    let today = cal.component(.day, from: Date())
    let monthDays = cal.range(of: .day, in: .month, for: Date())?.count ?? 30
    let rewards = [
        ("Credits", 5000), ("Combat Record", 3), ("Weapon Ore", 20), ("Credits", 8000), ("Arms Ticket", 1),
        ("Combat Record", 5), ("Supply Crate", 1),
    ]
    let days: [[String: Any]] = (1...monthDays).map { d in
        let r = rewards[(d - 1) % rewards.count]
        return ["day": d, "done": d < today && d != 4, "today": d == today, "name": r.0, "icon": "", "count": r.1]
    }
    return [
        "status": "ok", "message": "", "demo": true, "asOf": now,
        "account": ["name": "Demo", "avatar": "", "frame": ""],
        "role": [
            "name": "Endministrator", "uid": "4000000001", "server": "Demo", "level": 42, "worldLevel": 4,
            "exp": 18_250,
            "avatar": "", "mission": "Chapter 3 · A signal under the ice", "operators": operators.count, "weapons": 18,
            "documents": 64, "created": demoStart - 60 * day, "lastLogin": now - 2 * 3_600_000,
            "saved": now - 3_600_000,
        ],
        "sanity": [
            "cur": cur, "max": maxSan, "fullAt": fullAt > now ? fullAt : 0, "perPoint": fullAt > now ? perPoint : 0,
        ],
        "daily": ["cur": 60, "max": 100], "pass": ["cur": 23, "max": 60], "achievements": 47,
        "ship": [
            ["type": "Control Nexus", "level": 3], ["type": "Manufacturing Cabin", "level": 2],
            ["type": "Growth Chamber", "level": 2],
        ],
        "regions": [
            [
                "name": "Valley IV", "level": 5,
                "settlements": [["name": "Aster Outpost", "level": 4], ["name": "Refinery Nine", "level": 3]],
                "puzzles": 38, "chests": 112, "pieces": 21, "blackboxes": 9,
            ],
            [
                "name": "Wuling", "level": 2, "settlements": [["name": "Lantern Quay", "level": 2]],
                "puzzles": 11, "chests": 34, "pieces": 6, "blackboxes": 2,
            ],
        ],
        "operators": operators,
        "checkin": ["today": false, "done": days.filter { $0["done"] as? Bool == true }.count, "days": days],
        "banners": [
            [
                "kind": "operator", "name": "Ember Line", "start": demoStart - 5 * day, "end": demoStart + 9 * day,
                "featured": [
                    ["name": "Corvina", "rarity": 6, "pic": "", "up": true],
                    ["name": "Tamsin", "rarity": 5, "pic": "", "up": true],
                ],
            ],
            [
                "kind": "weapon", "name": "Arsenal: Ember Verdict", "start": demoStart - 5 * day,
                "end": demoStart + 9 * day,
                "featured": [["name": "Ember Verdict", "rarity": 6, "pic": "", "up": true]],
            ],
        ],
    ]
}

let wake = DispatchSemaphore(value: 0)
var forced = false
Thread.detachNewThread {
    while let line = rexui.readLine() {
        if let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], d["refresh"] != nil {
            forced = true
            wake.signal()
        }
    }
    exit(0)
}
emit(["state": state])
while true {
    let f = forced
    forced = false
    if demo { emit(["state": demoState()]) } else { cycle(f || lastSlow == .distantPast) }
    _ = wake.wait(timeout: .now() + every)
}
