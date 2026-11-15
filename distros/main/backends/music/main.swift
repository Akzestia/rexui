// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import Foundation

let rexui = RexuiBackend()

let home = FileManager.default.homeDirectoryForCurrentUser.path
let folders = CommandLine.arguments.dropFirst().map { ($0 as NSString).expandingTildeInPath }
let roots = folders.isEmpty ? [home + "/Music"] : Array(folders)
let audio: Set<String> = ["mp3", "m4a", "m4b", "aac", "alac", "flac", "wav", "aif", "aiff", "caf"]

let cacheDir = URL(fileURLWithPath: home + "/Library/Caches/rexui/music", isDirectory: true)
try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func scan() -> [URL] {
    var found: [URL] = []
    for root in roots {
        let e = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let u = e?.nextObject() as? URL {
            if audio.contains(u.pathExtension.lowercased()) { found.append(u) }
        }
    }
    return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
}

struct Tags {
    var title = "", artist = "", album = "", artwork = ""
}
var tagCache: [URL: Tags] = [:]

func tags(_ url: URL) -> Tags {
    if let t = tagCache[url] { return t }
    var t = Tags()
    let asset = AVURLAsset(url: url)
    let items = asset.commonMetadata + asset.metadata
    func value(_ key: AVMetadataKey) -> AVMetadataItem? {
        items.first { $0.commonKey == key }
    }
    t.title = value(.commonKeyTitle)?.stringValue ?? ""
    t.artist = value(.commonKeyArtist)?.stringValue ?? ""
    t.album = value(.commonKeyAlbumName)?.stringValue ?? ""
    if let data = value(.commonKeyArtwork)?.dataValue, !data.isEmpty {
        let ext = data.starts(with: [0x89, 0x50, 0x4e, 0x47]) ? "png" : "jpg"
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in url.path.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        let name = String(h, radix: 16)
        let file = cacheDir.appendingPathComponent("\(name).\(ext)")
        if (try? data.write(to: file)) != nil { t.artwork = file.path }
    }
    if t.title.isEmpty { t.title = url.deletingPathExtension().lastPathComponent }
    tagCache[url] = t
    return t
}

var names: [URL: (String, String)] = [:]
var tracksState: [[String: Any]] = []
let namesQueue = DispatchQueue(label: "rexui-music.names", qos: .utility)

func titleArtist(_ url: URL) -> (String, String) {
    let items = AVURLAsset(url: url).commonMetadata
    let t = items.first { $0.commonKey == .commonKeyTitle }?.stringValue ?? ""
    let a = items.first { $0.commonKey == .commonKeyArtist }?.stringValue ?? ""
    return (t.isEmpty ? url.deletingPathExtension().lastPathComponent : t, a)
}

func rebuildTracks() {
    tracksState = music.tracks.map { u in
        let n = names[u]
        return ["title": n?.0 ?? u.deletingPathExtension().lastPathComponent, "artist": n?.1 ?? ""]
    }
}

func loadNames() {
    let todo = music.tracks.filter { names[$0] == nil }
    if todo.isEmpty { return }
    namesQueue.async {
        var batch: [URL: (String, String)] = [:]
        for (i, u) in todo.enumerated() {
            batch[u] = titleArtist(u)
            if batch.count >= 25 || i == todo.count - 1 {
                let b = batch
                batch = [:]
                DispatchQueue.main.async {
                    for (k, v) in b { names[k] = v }
                    rebuildTracks()
                    emit()
                }
            }
        }
    }
}

final class Player: NSObject, AVAudioPlayerDelegate {
    var tracks = scan()
    var order: [Int] = []
    var at = 0
    var player: AVAudioPlayer?
    var shuffle = false
    var volume: Float = 1

    override init() {
        super.init()
        order = Array(tracks.indices)
    }

    var current: URL? { order.isEmpty ? nil : tracks[order[at]] }

    func rescan() {
        let now = scan()
        if now == tracks { return }
        let playing = current
        tracks = now
        order = Array(tracks.indices)
        if shuffle { order.shuffle() }
        at = playing.flatMap { p in order.firstIndex { tracks[$0] == p } } ?? 0
        if let p = playing, !tracks.contains(p) { stop() }
        rebuildTracks()
        loadNames()
    }

    func stop() {
        player?.stop()
        player = nil
    }

    func load(play: Bool) {
        stop()
        guard let url = current else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.volume = volume
            p.prepareToPlay()
            player = p
            if play { p.play() }
        } catch {
            log("cannot play \(url.path): \(error.localizedDescription)")
        }
    }

    func step(_ by: Int, play: Bool) {
        guard !order.isEmpty else { return }
        at = (at + by + order.count) % order.count
        load(play: play)
    }

    func toggle() {
        if player == nil { load(play: false) }
        guard let p = player else { return }
        if p.isPlaying { p.pause() } else { p.play() }
    }

    func command(_ cmd: String) {
        switch cmd {
        case "toggle": toggle()
        case "play": if player?.isPlaying != true { toggle() }
        case "pause": player?.pause()
        case "next": step(1, play: player?.isPlaying ?? true)
        case "previous":
            if let p = player, p.currentTime > 3 {
                p.currentTime = 0
            } else {
                step(-1, play: player?.isPlaying ?? true)
            }
        case "shuffle":
            shuffle.toggle()
            let playing = order.isEmpty ? nil : order[at]
            order = Array(tracks.indices)
            if shuffle { order.shuffle() }
            if let i = playing, let j = order.firstIndex(of: i) {
                if shuffle {
                    order.swapAt(0, j)
                    at = 0
                } else {
                    at = j
                }
            }
        default: log("unknown cmd \(cmd)")
        }
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) { step(1, play: true) }

    func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        log("decode error: \(error?.localizedDescription ?? "?")")
        step(1, play: true)
    }

    func state() -> [String: Any] {
        let t = current.map(tags) ?? Tags()
        let folder = roots.count == 1 ? roots[0].replacingOccurrences(of: home, with: "~") : "\(roots.count) folders"
        return [
            "playing": player?.isPlaying ?? false,
            "title": current == nil ? "" : t.title, "artist": t.artist, "album": t.album, "artwork": t.artwork,
            "position": ((player?.currentTime ?? 0) * 10).rounded() / 10,
            "duration": ((player?.duration ?? current.map { CMTimeGetSeconds(AVURLAsset(url: $0).duration) } ?? 0) * 10)
                .rounded() / 10,
            "index": order.isEmpty ? 0 : order[at], "count": tracks.count, "shuffle": shuffle, "folder": folder,
            "volume": Double(volume), "tracks": tracksState,
        ]
    }
}

let music = Player()
rebuildTracks()
loadNames()

func emit() {
    rexui.emit(["state": music.state()])
}

Thread {
    while let line = rexui.readLine() {
        guard let data = line.data(using: .utf8),
            let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        DispatchQueue.main.async {
            if let cmd = msg["cmd"] as? String { music.command(cmd) }
            if let s = msg["seek"] as? Double {
                if music.player == nil { music.load(play: false) }
                music.player?.currentTime = max(0, s)
            }
            if let i = msg["play"] as? Int, let at = music.order.firstIndex(of: i) {
                music.at = at
                music.load(play: true)
            }
            if let v = msg["volume"] as? Double {
                music.volume = Float(min(1, max(0, v)))
                music.player?.volume = music.volume
            }
            emit()
        }
    }
    exit(0)
}.start()

emit()
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in emit() }
Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
    music.rescan()
    emit()
}
RunLoop.main.run()
