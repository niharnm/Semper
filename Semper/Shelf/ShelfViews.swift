import AppKit
import QuickLookUI
import SwiftUI

struct ShelfCompactView: View {
    let service: ShelfService
    let openDetail: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("File Shelf", systemImage: "tray")
                    .font(.headline)
                Spacer()
                Text("\(service.items.count)").foregroundStyle(.secondary)
                Button("Choose Files…") { service.chooseFiles() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(!service.canChooseFiles)
                Button("Open", action: openDetail)
            }
            if !service.isRunning {
                Text("File Shelf is paused.").foregroundStyle(.secondary)
                Button("Start File Shelf") { service.start() }
            } else if service.items.isEmpty {
                Text("Choose files and folders, or drop files, links, images, or text here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54)
            } else {
                ForEach(service.items.prefix(3)) { item in
                    HStack(spacing: 8) {
                        ShelfDragHandle(service: service, item: item).frame(width: 22, height: 24)
                        Text(item.name).lineLimit(1)
                        Spacer()
                        Button {
                            Task { await service.remove(item.id) }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(item.name) from shelf")
                    }
                }
                if service.items.count > 3 { Button("View all \(service.items.count) items", action: openDetail) }
            }
            ShelfImageCleanupView(session: service.imageCopy)
            if service.importCount > 0 {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Adding \(service.importCount) items")
                    Button("Cancel") { Task { await service.cancelImports() } }
                }
            }
            if let message = service.message {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(targeted ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .onDrop(of: ShelfDropImporter.types, isTargeted: $targeted, perform: service.importDrops)
    }
}

struct ShelfDetailView: View {
    let service: ShelfService
    @State private var targeted = false
    @State private var preview: ShelfItem?
    @State private var resizeRequest: ShelfImageCopyRequest?
    @State private var confirmClear = false
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("File Shelf").font(.title2.weight(.semibold))
                    Text("A temporary place for items you add. Original files stay in place.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Files…", systemImage: "folder.badge.plus") { service.chooseFiles() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(!service.canChooseFiles)
                Button("Refresh", systemImage: "arrow.clockwise") { service.refresh() }.disabled(!service.isRunning)
                Button("Clear Shelf", systemImage: "tray") { confirmClear = true }.disabled(!service.canClear)
            }
            HStack {
                Picker(
                    "New items expire",
                    selection: Binding(
                        get: { service.defaultExpiry }, set: { value in service.setDefaultExpiry(value) })
                ) {
                    ForEach(ShelfExpiry.allCases) { Text($0.title).tag($0) }
                }.frame(maxWidth: 310)
                Spacer()
                if service.isRunning {
                    Button("Pause") { Task { await service.pause() } }
                } else {
                    Button("Start File Shelf") { service.start() }.disabled(service.isStopping)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    "Keep shelf between launches",
                    isOn: Binding(get: { service.persistenceEnabled }, set: { value in service.setPersistence(value) })
                )
                .disabled(service.storeNeedsReset || !service.isRunning || service.isClearing)
                Text(
                    "Off by default. Saved text, image copies, and file bookmarks stay on this Mac. Items set to ‘When Semper quits’ still clear at quit."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if service.storeNeedsReset {
                HStack {
                    Text("Saved shelf data needs attention. Imports are paused to preserve it.").font(.callout)
                    Button("Reset Saved Shelf") { confirmReset = true }
                }
            }
            if let message = service.message {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle")
                    Text(message).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { service.dismissMessage() }
                }.font(.callout).foregroundStyle(.orange)
            }
            ShelfImageCleanupView(session: service.imageCopy)
            if service.importCount > 0 {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Adding \(service.importCount) items")
                    Button("Cancel Import") { Task { await service.cancelImports() } }
                }
            }
            Group {
                if service.items.isEmpty {
                    ContentUnavailableView(
                        "Add items to your shelf", systemImage: "tray.and.arrow.down",
                        description: Text(
                            "Choose files and folders or drop items here. Files stay in place. Dropped text and images use a temporary local copy."
                        ))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(service.items) { item in
                                row(item).padding(.vertical, 12)
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                targeted ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10)
            )
            .onDrop(of: ShelfDropImporter.types, isTargeted: $targeted, perform: service.importDrops)
            Text(
                "Up to 100 items. Text: 64 KB. Dropped image copies: 32 MB each, 256 MB total. File references have no copy size limit."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 420)
        .confirmationDialog("Clear every shelf item?", isPresented: $confirmClear) {
            Button("Clear Shelf", role: .destructive) { Task { await service.clear() } }
        } message: {
            Text("Original files stay in place. Temporary image copies and shelf text are removed.")
        }
        .confirmationDialog("Reset saved shelf data?", isPresented: $confirmReset) {
            Button("Reset Saved Shelf", role: .destructive) { Task { await service.resetSavedData() } }
        } message: {
            Text("This removes saved shelf references, text, and temporary copies. Original files stay in place.")
        }
        .sheet(item: $preview) { item in
            VStack(alignment: .trailing) {
                Button("Done") { preview = nil }.keyboardShortcut(.cancelAction)
                if let url = service.fileURL(for: item) {
                    ShelfQuickLookView(url: url)
                } else if case .text(let text) = item.payload {
                    ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.padding().frame(minWidth: 540, minHeight: 380)
        }
        .sheet(item: $resizeRequest) { request in
            ShelfImageCopyView(session: service.imageCopy, request: request)
                .onDisappear { Task { await service.imageCopy.cancel(requestID: request.id) } }
        }
        .onChange(of: service.imageCopy.request?.id) { _, id in
            if resizeRequest?.id != id { resizeRequest = nil }
        }
        .onChange(of: service.isRunning) { _, running in if !running { preview = nil } }
        .onChange(of: service.items) { _, items in
            if let preview, !items.contains(where: { $0.id == preview.id }) { self.preview = nil }
        }
    }

    @ViewBuilder
    private func row(_ item: ShelfItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ShelfDragHandle(service: service, item: item).frame(width: 26, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.body.weight(.medium)).lineLimit(2).textSelection(.enabled)
                    if let state = service.fileStates[item.id] {
                        Text(state.message).font(.caption).foregroundStyle(
                            state.isAvailable ? Color.secondary : Color.orange)
                    } else if case .link(let url) = item.payload {
                        Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        Text("Plain text").font(.caption).foregroundStyle(.secondary)
                    }
                    if let expiresAt = item.expiresAt {
                        Text("Expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Clears when Semper quits").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    ForEach(ShelfExpiry.allCases) { expiry in
                        Button(expiry.title) { service.setExpiry(expiry, for: item.id) }
                    }
                } label: {
                    Label("Expiry", systemImage: "clock")
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button {
                    Task { await service.remove(item.id) }
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless).accessibilityLabel("Remove \(item.name) from shelf")
            }
            HStack(spacing: 12) {
                if service.fileURL(for: item) != nil {
                    Button("Quick Look") { if service.prepareFileAction(item) != nil { preview = item } }.disabled(
                        service.fileStates[item.id]?.isAvailable != true || service.imageCopy.isActive)
                    Button("Reveal in Finder") { service.reveal(item) }
                    Button("Copy Path") { service.copyPath(item) }
                    if service.fileStates[item.id] == .available(isDirectory: false) {
                        Button("SHA-256") { service.checksum(item.id) }.disabled(
                            service.checksums[item.id] == .calculating)
                    }
                } else if case .text = item.payload {
                    Button("Preview") { preview = item }
                    Button("Copy Text") { service.copyContents(item) }
                } else if case .link = item.payload {
                    Button("Copy Link") { service.copyContents(item) }
                }
            }.font(.callout).disabled(!service.isRunning)
            if service.fileStates[item.id] == .available(isDirectory: false) {
                Button("Resize a Copy…", systemImage: "arrow.up.left.and.arrow.down.right") {
                    resizeRequest = service.prepareImageCopy(item)
                }
                .font(.callout)
                .disabled(!service.canResizeImage(item))
                .help("Save a smaller JPEG or PNG without changing the original.")
            }
            if let checksum = service.checksums[item.id] {
                switch checksum {
                case .calculating:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Calculating SHA-256")
                        Button("Cancel") { service.cancelChecksum(item.id) }
                    }
                case .value(let value): Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                case .failed(let failure): Text(failure).font(.caption).foregroundStyle(.orange)
                case .cancelled: Text("Checksum cancelled").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ShelfQuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            return NSTextField(labelWithString: "Quick Look is unavailable for this item.")
        }
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { (view as? QLPreviewView)?.previewItem = url as NSURL }
    static func dismantleNSView(_ view: NSView, coordinator: ()) { (view as? QLPreviewView)?.close() }
}

private struct ShelfDragHandle: NSViewRepresentable {
    let service: ShelfService
    let item: ShelfItem
    func makeNSView(context: Context) -> ShelfDragSourceView { ShelfDragSourceView() }
    func updateNSView(_ view: ShelfDragSourceView, context: Context) {
        view.item = item
        view.service = service
        view.toolTip = "Drag a copy to another app"
        view.setAccessibilityLabel("Drag \(item.name) to another app")
    }
}

private final class ShelfDragSourceView: NSImageView, NSDraggingSource {
    var item: ShelfItem?
    weak var service: ShelfService?
    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "arrow.up.document", accessibilityDescription: "Drag item")
        imageScaling = .scaleProportionallyDown
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard let service, service.isRunning, let item else { return }
        guard let writer = service.dragWriter(for: item) else { return }
        let draggingItem = NSDraggingItem(pasteboardWriter: writer)
        draggingItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    { .copy }
}
