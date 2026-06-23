import SwiftUI
import AppKit

// MARK: - Model

/// A node in the scanned file tree. Reference type so we can mutate sizes
/// bottom-up during scanning and walk back up to a parent when deleting.
final class FileNode: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    var size: Int64 = 0
    var fileCount: Int = 0        // total files contained (recursive)
    var children: [FileNode] = []
    weak var parent: FileNode?

    init(url: URL, name: String, isDirectory: Bool, parent: FileNode?) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.parent = parent
    }
}

/// Counter used to report scan progress. Touched only by the single
/// scanning thread, so no locking is needed.
final class ScanProgress {
    var items: Int = 0
}

/// Thread-safe cancellation flag. The UI sets it from the main thread;
/// the background scanner reads it. Sendable so it can cross threads.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

// MARK: - Scan engine

enum Scanner {
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey,
                                         .fileSizeKey, .totalFileAllocatedSizeKey]

    /// Scan the immediate contents of an already-created directory node,
    /// recursing into subfolders. Runs off the main thread. Nodes are
    /// attached to the tree *as they are discovered* (under `lock`) and their
    /// sizes propagate up to ancestors live, so the UI can render progress
    /// while the scan is still running. `lock` guards every structural change
    /// so the main thread can safely read a snapshot at any moment.
    static func scanChildren(of node: FileNode,
                             lock: NSLock,
                             progress: ScanProgress,
                             onProgress: @escaping (Int) -> Void,
                             isCancelled: @escaping () -> Bool) {
        if isCancelled() { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: node.url,
            includingPropertiesForKeys: keys,
            options: []   // include hidden files — caches/dot-dirs hide the bulk
        ) else { return }

        for childURL in contents {
            if isCancelled() { return }
            scan(url: childURL, parent: node, lock: lock, progress: progress,
                 onProgress: onProgress, isCancelled: isCancelled)
        }
    }

    private static func scan(url: URL,
                             parent: FileNode,
                             lock: NSLock,
                             progress: ScanProgress,
                             onProgress: @escaping (Int) -> Void,
                             isCancelled: @escaping () -> Bool) {
        let values = try? url.resourceValues(forKeys: Set(keys))
        let isSymlink = values?.isSymbolicLink ?? false
        let isDir = values?.isDirectory ?? false

        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let node = FileNode(url: url, name: name, isDirectory: isDir, parent: parent)

        // Attach immediately so the folder shows up in the list right away.
        lock.lock(); parent.children.append(node); lock.unlock()

        progress.items += 1
        if progress.items % 1500 == 0 { onProgress(progress.items) }

        // Never follow symlinks — avoids loops and double counting.
        if isSymlink || !isDir {
            let bytes = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            addSize(bytes, to: node, lock: lock)
            return
        }

        // Directory: recurse. Its size grows as descendants are counted.
        scanChildren(of: node, lock: lock, progress: progress,
                     onProgress: onProgress, isCancelled: isCancelled)
    }

    /// Record a file's size on its node and add it to every ancestor's running
    /// total, so directory sizes climb live as their contents are discovered.
    private static func addSize(_ bytes: Int64, to node: FileNode, lock: NSLock) {
        lock.lock()
        node.size += bytes
        node.fileCount += 1
        var p = node.parent
        while let cur = p {
            cur.size += bytes
            cur.fileCount += 1
            p = cur.parent
        }
        lock.unlock()
    }
}

// MARK: - View model

@MainActor
final class AppModel: ObservableObject {
    @Published var root: FileNode?
    @Published var current: FileNode?
    @Published var isScanning = false
    @Published var scannedCount = 0
    @Published var scanRootURL: URL
    @Published var selection: Set<FileNode.ID> = []

    // Live disk status for the volume holding the scanned folder.
    @Published var freeBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var volumeName: String = "Disk"

    private var cancelToken = CancelToken()
    /// Guards every read/write of the shared tree across the scan thread and
    /// the main thread.
    let treeLock = NSLock()
    private var refreshTask: Task<Void, Never>?
    private var diskMonitor: Task<Void, Never>?

    init() {
        scanRootURL = FileManager.default.homeDirectoryForCurrentUser
    }

    /// Poll the volume's free space continuously so the gauge reflects changes
    /// (downloads, builds, emptying the Trash, …) live.
    func startDiskMonitor() {
        guard diskMonitor == nil else { return }
        refreshDiskSpace()
        diskMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.refreshDiskSpace()
            }
        }
    }

    func refreshDiskSpace() {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
            .volumeLocalizedNameKey,
        ]
        guard let v = try? scanRootURL.resourceValues(forKeys: keys) else { return }
        if let free = v.volumeAvailableCapacityForImportantUsage { freeBytes = free }
        if let total = v.volumeTotalCapacity { totalBytes = Int64(total) }
        if let name = v.volumeLocalizedName, !name.isEmpty { volumeName = name }
    }

    /// A stable, sorted snapshot of a node's children, copied under the lock so
    /// the main thread never iterates the array while the scanner mutates it.
    func displayRows(of node: FileNode) -> [FileNode] {
        treeLock.lock()
        let copy = node.children
        treeLock.unlock()
        return copy.sorted { $0.size > $1.size }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = scanRootURL
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            scanRootURL = url
            startScan()
        }
    }

    func startScan() {
        guard !isScanning else { return }
        let token = CancelToken()
        cancelToken = token
        isScanning = true
        scannedCount = 0
        selection = []

        // Create the root node up front and show it immediately, so the list
        // is live from the first frame and fills in as the scan proceeds.
        let url = scanRootURL
        let rootName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let rootNode = FileNode(url: url, name: rootName, isDirectory: true, parent: nil)
        root = rootNode
        current = rootNode
        let lock = treeLock

        // Refresh the view ~5×/sec while scanning so bars grow and reorder live.
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while self?.isScanning == true {
                self?.objectWillChange.send()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            self?.objectWillChange.send()
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let progress = ScanProgress()
            Scanner.scanChildren(
                of: rootNode,
                lock: lock,
                progress: progress,
                onProgress: { count in
                    Task { @MainActor in self?.scannedCount = count }
                },
                isCancelled: { token.isCancelled }
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scannedCount = progress.items
                self.isScanning = false
            }
        }
    }

    func cancelScan() {
        cancelToken.cancel()
    }

    func navigate(into node: FileNode) {
        guard node.isDirectory else { return }
        current = node
        selection = []
    }

    func goUp() {
        if let parent = current?.parent {
            current = parent
            selection = []
        }
    }

    func navigate(to node: FileNode) {
        current = node
        selection = []
    }

    /// Breadcrumb chain from root to current.
    var breadcrumb: [FileNode] {
        var chain: [FileNode] = []
        var n = current
        while let node = n {
            chain.append(node)
            n = node.parent
        }
        return chain.reversed()
    }

    /// Move the selected nodes (or the given node) to the Trash, then update
    /// the in-memory tree sizes so the UI reflects the change without rescan.
    func trash(nodes: [FileNode]) {
        let fm = FileManager.default
        var trashed: [FileNode] = []
        for node in nodes {
            do {
                try fm.trashItem(at: node.url, resultingItemURL: nil)
                trashed.append(node)
            } catch {
                NSLog("Failed to trash \(node.url.path): \(error)")
            }
        }
        guard !trashed.isEmpty else { return }

        treeLock.lock()
        for node in trashed {
            guard let parent = node.parent else { continue }
            parent.children.removeAll { $0.id == node.id }
            // Propagate the freed size/count up the chain.
            var p: FileNode? = parent
            while let cur = p {
                cur.size -= node.size
                cur.fileCount -= node.fileCount
                p = cur.parent
            }
        }
        treeLock.unlock()
        selection = []
        refreshDiskSpace()
        objectWillChange.send()
    }
}

// MARK: - Views

@main
struct DiskSpaceManagerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Disk Space Manager") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    model.startDiskMonitor()
                    if model.root == nil { model.startScan() }
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView()
            Divider()
            DiskStatusView()
            Divider()
            BreadcrumbView()
            Divider()
            if let current = model.current {
                FileListView(node: current)
            } else {
                Spacer()
                Text(model.isScanning ? "Scanning…" : "No folder scanned")
                    .foregroundColor(.secondary)
                Spacer()
            }
            Divider()
            StatusBarView()
        }
    }
}

/// Live disk gauge — updates ~every 1.5s and immediately after a trash.
struct DiskStatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let total = model.totalBytes
        let free = model.freeBytes
        let used = max(0, total - free)
        let frac = total > 0 ? min(1.0, Double(used) / Double(total)) : 0

        HStack(spacing: 10) {
            Image(systemName: "internaldrive.fill")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.volumeName).fontWeight(.semibold)
                    Spacer()
                    Text("\(format(free)) free")
                        .foregroundColor(barColor(frac))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    Text("of \(format(total))")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule().fill(barColor(frac))
                            .frame(width: max(3, geo.size.width * frac))
                            .animation(.easeInOut(duration: 0.4), value: frac)
                    }
                }
                .frame(height: 7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func barColor(_ frac: Double) -> Color {
        switch frac {
        case 0.9...: return .red
        case 0.75...: return .orange
        default: return .accentColor
        }
    }
}

struct ToolbarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.goUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(model.current?.parent == nil)
            .help("Go up one level")

            Button {
                model.chooseFolder()
            } label: {
                Label("Choose Folder", systemImage: "folder")
            }

            if model.isScanning {
                Button(role: .destructive) {
                    model.cancelScan()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 18, height: 18)
            } else {
                Button {
                    model.startScan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
            }

            Spacer()

            let selected = selectedNodes()
            Button(role: .destructive) {
                confirmAndTrash(selected)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .disabled(selected.isEmpty)
            .keyboardShortcut(.delete, modifiers: [.command])
            .help("Move selected items to Trash")
        }
        .padding(8)
    }

    private func selectedNodes() -> [FileNode] {
        guard let current = model.current else { return [] }
        return model.displayRows(of: current).filter { model.selection.contains($0.id) }
    }

    private func confirmAndTrash(_ nodes: [FileNode]) {
        guard !nodes.isEmpty else { return }
        let alert = NSAlert()
        let totalSize = nodes.reduce(Int64(0)) { $0 + $1.size }
        alert.messageText = nodes.count == 1
            ? "Move “\(nodes[0].name)” to Trash?"
            : "Move \(nodes.count) items to Trash?"
        alert.informativeText = "This frees \(format(totalSize)). Items go to the Trash and can be restored from there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.trash(nodes: nodes)
        }
    }
}

struct BreadcrumbView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.breadcrumb.enumerated()), id: \.element.id) { idx, node in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Button {
                        model.navigate(to: node)
                    } label: {
                        Text(node.name)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(idx == model.breadcrumb.count - 1 ? .primary : .accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

struct FileListView: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode

    var body: some View {
        let children = model.displayRows(of: node)
        let maxSize = max(children.first?.size ?? 1, 1)

        if children.isEmpty {
            VStack {
                Spacer()
                Text(model.isScanning ? "Scanning…" : "Empty folder")
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else {
            // A LazyVStack (not List) so we can refresh many times per second
            // during a live scan without tripping NSTableView's reentrancy
            // guard. Selection is handled manually below.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.element.id) { idx, child in
                        FileRow(node: child, maxSize: maxSize) {
                            trashSingle(child)
                        }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .background(rowBackground(idx: idx, selected: model.selection.contains(child.id)))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Single click: open folders, select files.
                                // ⌘-click always (de)selects for batch actions.
                                if NSEvent.modifierFlags.contains(.command) {
                                    select(child.id)
                                } else if child.isDirectory {
                                    model.navigate(into: child)
                                } else {
                                    model.selection = [child.id]
                                }
                            }
                            .contextMenu {
                                if child.isDirectory {
                                    Button("Open in Browser") { model.navigate(into: child) }
                                }
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([child.url])
                                }
                                Divider()
                                Button("Move to Trash", role: .destructive) {
                                    trashSingle(child)
                                }
                            }
                    }
                }
            }
        }
    }

    private func rowBackground(idx: Int, selected: Bool) -> Color {
        if selected { return Color.accentColor.opacity(0.30) }
        return idx % 2 == 1 ? Color.secondary.opacity(0.06) : Color.clear
    }

    /// Toggle a row's membership in the multi-selection (⌘-click).
    private func select(_ id: FileNode.ID) {
        if model.selection.contains(id) { model.selection.remove(id) }
        else { model.selection.insert(id) }
    }

    private func trashSingle(_ child: FileNode) {
        let alert = NSAlert()
        alert.messageText = "Move “\(child.name)” to Trash?"
        alert.informativeText = "This frees \(format(child.size))."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.trash(nodes: [child])
        }
    }
}

struct FileRow: View {
    let node: FileNode
    let maxSize: Int64
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.isDirectory ? "folder.fill" : iconName(for: node.url))
                .foregroundColor(node.isDirectory ? .accentColor : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 5)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor)
                            .frame(width: max(2, geo.size.width * fraction), height: 5)
                    }
                }
                .frame(height: 5)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(format(node.size))
                    .monospacedDigit()
                    .font(.system(.body, design: .rounded))
                Text(node.isDirectory ? "\(node.fileCount) items" : "")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(width: 110, alignment: .trailing)

            Button(action: onTrash) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("Move to Trash")

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(node.isDirectory ? .secondary : .clear)
        }
        .padding(.vertical, 2)
    }

    private var fraction: Double {
        maxSize > 0 ? min(1.0, Double(node.size) / Double(maxSize)) : 0
    }

    private var barColor: Color {
        // Warmer color for the heavier hitters.
        switch fraction {
        case 0.66...: return .red
        case 0.33...: return .orange
        default: return .accentColor
        }
    }

    private func iconName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "tiff", "bmp": return "photo"
        case "mp4", "mov", "avi", "mkv", "m4v": return "film"
        case "mp3", "wav", "aac", "flac", "m4a": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "dmg", "pkg", "7z", "rar": return "doc.zipper"
        case "app": return "app.badge"
        default: return "doc"
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            if model.isScanning {
                Text("Scanning… \(model.scannedCount) items")
            } else if let root = model.root {
                Text("Total: \(format(root.size))  •  \(root.fileCount) files")
                if let current = model.current, current.id != root.id {
                    Text("•  This folder: \(format(current.size))")
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Ready")
            }
            Spacer()
            if !model.selection.isEmpty {
                Text("\(model.selection.count) selected")
                    .foregroundColor(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

// MARK: - Helpers

func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
