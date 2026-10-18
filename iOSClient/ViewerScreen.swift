import SwiftUI

// co.wisniewski: a VNC-viewer-like stream screen for the iPhone. The picture takes the whole
// screen and zooms (pinch) and pans (the pointer pushing the edges, or the fingers of a pinch); the
// whole screen is the trackpad (TrackpadSurface: drag moves the pointer, tap clicks, two fingers
// scroll, press and hold drags, three fingers are the Mac's gestures). Everything else (windows,
// apps, menus, keys, settings) waits behind a slim top bar that can be hidden.

/// Where the picture sits: how far it is zoomed beyond fitting the screen, and which point of the
/// frame (a fraction) is at the screen's centre.
final class ViewerCamera: ObservableObject {
    @Published var zoom: CGFloat = 1
    @Published var center = CGPoint(x: 0.5, y: 0.5)
    var screen: CGSize = .zero
    var video: CGSize = .zero

    static let maxZoom: CGFloat = 8
    /// How close to the screen's edge the pointer may come before the picture moves under it.
    static let edge: CGFloat = 44

    /// The frame aspect-fitted into the screen, at zoom 1.
    private var fitted: CGSize {
        guard screen.width > 0, screen.height > 0, video.width > 0, video.height > 0 else { return screen }
        let s = min(screen.width / video.width, screen.height / video.height)
        return CGSize(width: video.width * s, height: video.height * s)
    }

    /// The zoom at which the picture fills the screen (no bars) — the "Fill" button.
    var fillZoom: CGFloat {
        let f = fitted
        guard f.width > 0, f.height > 0 else { return 1 }
        return min(Self.maxZoom, max(screen.width / f.width, screen.height / f.height))
    }

    /// The picture's rect on screen. Along an axis where it is smaller than the screen it is centred;
    /// where it is larger it never leaves a gap at either end.
    var rect: CGRect {
        let f = fitted
        let size = CGSize(width: f.width * zoom, height: f.height * zoom)
        func origin(_ screen: CGFloat, _ size: CGFloat, _ center: CGFloat) -> CGFloat {
            if size <= screen { return (screen - size) / 2 }
            return min(0, max(screen - size, screen / 2 - center * size))
        }
        return CGRect(x: origin(screen.width, size.width, center.x),
                      y: origin(screen.height, size.height, center.y),
                      width: size.width, height: size.height)
    }

    /// Writes `center` back from a rect, so it never holds a value the clamp would undo.
    private func settle(_ r: CGRect) {
        guard r.width > 0, r.height > 0 else { return }
        center = CGPoint(x: (screen.width / 2 - r.minX) / r.width, y: (screen.height / 2 - r.minY) / r.height)
    }

    /// The pointer moved to `p` (a fraction of the frame): past the edge band, the picture follows it.
    func follow(_ p: CGPoint) {
        var r = rect
        guard r.width > screen.width || r.height > screen.height else { return }
        let x = r.minX + p.x * r.width, y = r.minY + p.y * r.height
        let edgeX = min(Self.edge, screen.width / 4), edgeY = min(Self.edge, screen.height / 4)
        var moved = false
        if r.width > screen.width {
            if x < edgeX { r.origin.x += edgeX - x; moved = true }
            else if x > screen.width - edgeX { r.origin.x -= x - (screen.width - edgeX); moved = true }
        }
        if r.height > screen.height {
            if y < edgeY { r.origin.y += edgeY - y; moved = true }
            else if y > screen.height - edgeY { r.origin.y -= y - (screen.height - edgeY); moved = true }
        }
        guard moved else { return }
        settle(r)
        settle(rect)
    }

    /// One step of a pinch: the frame point that was under `from` ends under `to`, at `zoom × scale`.
    func pinch(scale: CGFloat, from: CGPoint, to: CGPoint) {
        let before = rect
        guard before.width > 0, before.height > 0 else { return }
        let fx = (from.x - before.minX) / before.width, fy = (from.y - before.minY) / before.height
        zoom = min(Self.maxZoom, max(1, zoom * scale))
        let f = fitted
        let size = CGSize(width: f.width * zoom, height: f.height * zoom)
        settle(CGRect(x: to.x - fx * size.width, y: to.y - fy * size.height, width: size.width, height: size.height))
        settle(rect)
    }

    /// Fit ↔ fill, keeping `focus` (a fraction of the frame, the pointer) in view.
    func toggleFill(focus: CGPoint?) {
        let fill = fillZoom
        if zoom > 1.01 { zoom = 1 } else { zoom = fill }
        if let focus { center = focus }
        settle(rect)
    }
}

/// Which of the bar's pull-downs is open.
enum ViewerPanel: Equatable { case windows, keys }

struct ViewerScreen: View {
    @ObservedObject var client: StreamClient
    @Binding var drawerOpen: Bool
    @Binding var keyboardShown: Bool
    @Binding var windowMenu: UInt32?
    @Binding var latched: KeyModifiers
    let overlay: InputOverlayProxy
    let settingsOpen: Bool
    let setSettings: (Bool, Bool) -> Void
    let menusOpened: () -> Void
    let menusClosed: () -> Void
    let onPanelSize: (CGSize) -> Void
    let pairThisDevice: () -> Void
    let takeTour: () -> Void
    let linkLine: String?

    @StateObject private var camera = ViewerCamera()
    @AppStorage("viewerBarShown") private var barShown = true
    @State private var panel: ViewerPanel? = nil
    @State private var pinchAt: CGPoint? = nil
    /// The pointer as this screen last put it, for Fill's focus.
    @State private var lastPointer: CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .top) {
                Color.black

                picture
                    .frame(width: camera.rect.width, height: camera.rect.height)
                    .position(x: camera.rect.midX, y: camera.rect.midY)

                // The whole screen is the trackpad. It sits over the picture, so the picture's
                // direct-touch overlay (kept for the keyboard's first responder) never sees a touch.
                TrackpadView(send: { client.sendInput($0) },
                             setPointer: { p in
                                 client.setOwnPointer(p, from: .trackpad)
                                 lastPointer = p
                                 camera.follow(p)
                             },
                             feed: { let f = client.pointerFeedState; return (f.anchor, f.reseeds) },
                             onFingers: { client.trackpadFingers($0) },
                             latched: latched,
                             onModifiersConsumed: { latched = [] },
                             sendGesture: { client.sendGesture($0, fingers: $1) },
                             travelScale: camera.zoom,
                             onPinch: pinch)

                LinkLineView(text: linkLine)
                    .padding(.top, barShown ? 64 : 12)
                    .allowsHitTesting(false)

                topBar
                    .padding(.horizontal, 8)
                    .padding(.top, 4)

                if drawerOpen {
                    dim { drawerOpen = false }
                    AppDrawer(client: client, drawerOpen: $drawerOpen)
                        .frame(maxWidth: 420)
                        .padding(.horizontal, 10)
                        .padding(.top, 60)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
                if settingsOpen {
                    dim { setSettings(false, true) }
                    HostSettingsPanel(client: client, close: { setSettings(false, true) },
                                      pairThisDevice: pairThisDevice, takeTour: takeTour)
                        .frame(maxWidth: 420)
                        .padding(.horizontal, 10)
                        .padding(.top, 60)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
            .onAppear { layout(size) }
            .onChange(of: size) { _, now in layout(now) }
            .onChange(of: client.videoSize) { _, _ in layout(size) }
        }
        .background(Color.black)
        .animation(.easeOut(duration: 0.18), value: barShown)
        .animation(.easeOut(duration: 0.18), value: panel)
        .animation(.easeOut(duration: 0.18), value: drawerOpen)
        .animation(.easeOut(duration: 0.18), value: settingsOpen)
    }

    private func layout(_ size: CGSize) {
        camera.screen = size
        camera.video = client.videoSize
        camera.objectWillChange.send()
        onPanelSize(size)
    }

    private func pinch(_ state: UIGestureRecognizer.State, _ scale: CGFloat, _ at: CGPoint) {
        switch state {
        case .began, .changed:
            camera.pinch(scale: scale, from: pinchAt ?? at, to: at)
            pinchAt = at
        default:
            pinchAt = nil
        }
    }

    private var picture: some View {
        ZStack {
            StreamView(client: client)
            InputOverlay(videoSize: client.videoSize,
                         send: { client.sendInput($0) },
                         setOwnPointer: { client.setOwnPointer($0, from: $1) },
                         proxy: overlay,
                         isKeyboardShown: $keyboardShown,
                         latchedModifiers: latched,
                         onModifiersConsumed: { latched = [] },
                         sendGesture: { client.sendGesture($0, fingers: $1) })
        }
    }

    private func dim(_ close: @escaping () -> Void) -> some View {
        Color.black.opacity(0.5)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { close() } }
            .accessibilityHidden(true)
            .transition(.opacity)
    }

    // MARK: The bar

    @ViewBuilder private var topBar: some View {
        if barShown {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    barButton("rectangle.on.rectangle", "Windows", open: panel == .windows) { toggle(.windows) }
                    barButton("square.grid.2x2", "Apps", open: drawerOpen) {
                        panel = nil
                        if settingsOpen { setSettings(false, true) }
                        drawerOpen.toggle()
                    }
                    if client.menus.hasMenus {
                        MacMenuButton(client: client, width: 44, height: 40, radius: 12, iconSize: 18, spacing: 0,
                                      onOpen: menusOpened, onClose: menusClosed)
                    }
                    barButton("keyboard", "Keyboard", open: keyboardShown) { overlay.toggleKeyboard() }
                    barButton("command", "Keys", open: panel == .keys || !latched.isEmpty) { toggle(.keys) }
                    barButton(camera.zoom > 1.01 ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              camera.zoom > 1.01 ? "Fit" : "Fill", open: false) {
                        withAnimation(.easeOut(duration: 0.2)) { camera.toggleFill(focus: lastPointer) }
                    }
                    barButton("gearshape", "Settings", open: settingsOpen) {
                        panel = nil
                        drawerOpen = false
                        setSettings(!settingsOpen, true)
                    }
                    barButton("chevron.up", "Hide the bar", open: false) {
                        panel = nil
                        barShown = false
                    }
                }
                .padding(6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .environment(\.colorScheme, .dark)

                switch panel {
                case .windows: windowsPanel
                case .keys: keysPanel
                case nil: EmptyView()
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        } else {
            // A tab at the top centre brings the bar back.
            Button(action: { barShown = true }) {
                Capsule().fill(Color.white.opacity(0.55))
                    .frame(width: 54, height: 5)
                    .frame(width: 120, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show the bar")
            .transition(.opacity)
        }
    }

    private func toggle(_ p: ViewerPanel) {
        drawerOpen = false
        if settingsOpen { setSettings(false, true) }
        panel = panel == p ? nil : p
    }

    private func barButton(_ symbol: String, _ label: String, open: Bool, action: @escaping () -> Void) -> some View {
        BarButton(open: open, width: 44, height: 40, radius: 12, accessibilityLabel: label, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(open ? Palette.accent : Color.white)
        }
    }

    private var windowsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { client.select(.desktop); panel = nil }) {
                Label("Desktop", systemImage: "desktopcomputer")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(client.active == .desktop ? Palette.accent : Color.white)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(client.active == .desktop ? Palette.controlOpen : Palette.control))
            }
            .buttonStyle(.plain)
            WindowStrip(client: client, width: 104, height: 66, menuFor: $windowMenu)
                .frame(height: 86)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
        .transition(.opacity)
    }

    private var keysPanel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            KeyRow(metrics: .phone, keys: .full, latched: $latched, keyboardShown: keyboardShown,
                   send: { client.sendFromKeyRow($0) },
                   toggleKeyboard: { overlay.toggleKeyboard() },
                   showSpotlight: client.active == .desktop)
        }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .environment(\.colorScheme, .dark)
            .transition(.opacity)
    }
}
