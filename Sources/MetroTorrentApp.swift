import SwiftUI
import UniformTypeIdentifiers

enum Metro {
    static let background = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let tile = Color(red: 0.00, green: 0.54, blue: 0.80)
    static let tilePaused = Color(red: 0.35, green: 0.35, blue: 0.38)
    static let tileDone = Color(red: 0.20, green: 0.60, blue: 0.30)
    static let accent = Color(red: 0.90, green: 0.35, blue: 0.10)
}

enum TorrentState { case downloading, paused, finished }

struct TorrentItem: Identifiable {
    let id = UUID()
    var name: String
    var progress: Double = 0
    var speed: Int64 = 0
    var state: TorrentState = .downloading
}

protocol TorrentEngine: AnyObject {
    var onUpdate: ((UUID, Double, Int64, TorrentState) -> Void)? { get set }
    func add(torrentFile: URL, saveTo: URL, id: UUID)
    func pause(id: UUID)
    func resume(id: UUID)
    func remove(id: UUID)
}

// Fake engine: only simulates progress. Replace with libtorrent for real downloads.
final class SimulatedEngine: TorrentEngine {
    var onUpdate: ((UUID, Double, Int64, TorrentState) -> Void)?
    private var timers: [UUID: Timer] = [:]
    private var progress: [UUID: Double] = [:]

    func add(torrentFile: URL, saveTo: URL, id: UUID) {
        progress[id] = 0
        start(id)
    }
    private func start(_ id: UUID) {
        timers[id]?.invalidate()
        timers[id] = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { return }
            let p = min(1, (self.progress[id] ?? 0) + 0.01)
            self.progress[id] = p
            if p >= 1 { t.invalidate(); self.onUpdate?(id, 1, 0, .finished) }
            else { self.onUpdate?(id, p, 1_500_000, .downloading) }
        }
    }
    func pause(id: UUID) { timers[id]?.invalidate(); onUpdate?(id, progress[id] ?? 0, 0, .paused) }
    func resume(id: UUID) { start(id) }
    func remove(id: UUID) { timers[id]?.invalidate(); progress[id] = nil }
}

final class TorrentStore: ObservableObject {
    @Published var items: [TorrentItem] = []
    let engine: TorrentEngine = SimulatedEngine()
    let saveDir: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() {
        engine.onUpdate = { [weak self] id, p, speed, state in
            DispatchQueue.main.async {
                guard let self, let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[i].progress = p
                self.items[i].speed = speed
                self.items[i].state = state
            }
        }
    }

    func addTorrent(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = saveDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        let item = TorrentItem(name: url.deletingPathExtension().lastPathComponent)
        items.append(item)
        engine.add(torrentFile: dest, saveTo: saveDir, id: item.id)
    }

    func toggle(_ item: TorrentItem) {
        switch item.state {
        case .downloading: engine.pause(id: item.id)
        case .paused: engine.resume(id: item.id)
        case .finished: break
        }
    }

    func remove(_ item: TorrentItem) {
        engine.remove(id: item.id)
        items.removeAll { $0.id == item.id }
    }
}

@main
struct MetroTorrentApp: App {
    @StateObject private var store = TorrentStore()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onOpenURL { store.addTorrent(from: $0) }
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: TorrentStore
    @State private var showPicker = false
    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 8)]

    var body: some View {
        ZStack {
            Metro.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("downloads")
                        .font(.system(size: 56, weight: .ultraLight))
                        .foregroundColor(.white)
                        .padding(.top, 40)
                    LazyVGrid(columns: columns, spacing: 8) {
                        AddTile { showPicker = true }
                        ForEach(store.items) { item in
                            TorrentTile(item: item)
                                .onTapGesture { store.toggle(item) }
                                .contextMenu {
                                    Button("Remove", role: .destructive) { store.remove(item) }
                                }
                        }
                    }
                    if store.items.isEmpty {
                        Text("tap + to open a .torrent file")
                            .font(.system(size: 18, weight: .light))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 48)
            }
        }
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { urls.forEach(store.addTorrent) }
        }
    }
}

struct AddTile: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack {
                Image(systemName: "plus").font(.system(size: 48, weight: .thin))
                Text("add torrent").font(.system(size: 18, weight: .light))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(Metro.accent)
        }
        .buttonStyle(.plain)
    }
}

struct TorrentTile: View {
    let item: TorrentItem
    private var color: Color {
        switch item.state {
        case .downloading: return Metro.tile
        case .paused: return Metro.tilePaused
        case .finished: return Metro.tileDone
        }
    }
    private var status: String {
        switch item.state {
        case .downloading: return String(format: "%.0f%%  ·  %@/s", item.progress * 100,
                                         ByteCountFormatter.string(fromByteCount: item.speed, countStyle: .file))
        case .paused: return String(format: "paused  ·  %.0f%%", item.progress * 100)
        case .finished: return "finished"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name).font(.system(size: 20, weight: .regular)).lineLimit(2)
            Spacer()
            Text(status).font(.system(size: 15, weight: .light))
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.3)).frame(height: 4)
                GeometryReader { g in
                    Rectangle().fill(Color.white)
                        .frame(width: g.size.width * item.progress, height: 4)
                }.frame(height: 4)
            }
        }
        .foregroundColor(.white)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(color)
    }
}
