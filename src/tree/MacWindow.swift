final class MacWindow: Window, CustomStringConvertible {
    let axWindow: AXUIElement
    private let macApp: MacApp
    // todo take into account monitor proportions
    private var prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect: CGPoint?
    fileprivate var previousSize: CGSize?
    private var axObservers: [AxObserverWrapper] = [] // keep observers in memory

    private init(_ id: CGWindowID, _ app: MacApp, _ axWindow: AXUIElement, parent: NonLeafTreeNode, adaptiveWeight: CGFloat, index: Int) {
        self.axWindow = axWindow
        self.macApp = app
        super.init(id: id, app, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    private static var allWindowsMap: [CGWindowID: MacWindow] = [:]
    static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    static func get(app: MacApp, axWindow: AXUIElement) -> MacWindow? {
        guard let id = axWindow.windowId() else { return nil }
        if let existing = allWindowsMap[id] {
            return existing
        } else {
            let data = getBindingDataForNewWindow(axWindow, Workspace.focused)
            let window = MacWindow(id, app, axWindow, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)

            if window.observe(destroyedObs, kAXUIElementDestroyedNotification) &&
                       window.observe(refreshObs, kAXWindowDeminiaturizedNotification) &&
                       window.observe(refreshObs, kAXWindowMiniaturizedNotification) &&
                       window.observe(movedObs, kAXMovedNotification) &&
                       window.observe(resizedObs, kAXResizedNotification) {
                debug("New window detected: \(window)")
                allWindowsMap[id] = window
                return window
            } else {
                window.garbageCollect()
                return nil
            }
        }
    }

    var description: String {
        let description = [
            ("title", title),
            ("role", axWindow.get(Ax.roleAttr)),
            ("subrole", axWindow.get(Ax.subroleAttr)),
            ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
            ("windowId", String(windowId))
        ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
        return "Window(\(description))"
    }

    func garbageCollect() {
        debug("garbageCollectWindow of \(app.title ?? "NO TITLE")")
        MacWindow.allWindowsMap.removeValue(forKey: windowId)
        unbindFromParent()
        for obs in axObservers {
            AXObserverRemoveNotification(obs.obs, obs.ax, obs.notif)
        }
        axObservers = []
    }

    private func observe(_ handler: AXObserverCallback, _ notifKey: String) -> Bool {
        guard let observer = AXObserver.observe(app.id, notifKey, axWindow, handler, data: self) else { return false }
        axObservers.append(AxObserverWrapper(obs: observer, ax: axWindow, notif: notifKey as CFString))
        return true
    }

    override var title: String? {
        axWindow.get(Ax.titleAttr)
    }

    @discardableResult
    override func focus() -> Bool { // todo make focus reliable: make async + active waiting
        // Raise firstly to make sure that by that time we activate the app, particular window would be already on top
        if axWindow.raise() && macApp.nsApp.activate(options: .activateIgnoringOtherApps) {
            markAsMostRecentChild()
            markAsMostRecentChildForAccordion()
            return true
        } else {
            return false
        }
    }

    override func close() -> Bool {
        guard let closeButton = axWindow.get(Ax.closeButtonAttr) else { return false }
        return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == AXError.success
    }

    func hideViaEmulation() {
        //guard let monitorApproximation else { return }
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent
        // `hideEmulation` calls
        if !isHiddenViaEmulation {
            debug("hideViaEmulation: Hide \(self)")
            guard let topLeftCorner = getTopLeftCorner() else { return }
            prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect =
                    topLeftCorner - workspace.monitor.rect.topLeftCorner
        }
        setTopLeftCorner(allMonitorsRectsUnion.bottomRightCorner)
    }

    func unhideViaEmulation() {
        guard let prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect else { return }

        setTopLeftCorner(workspace.monitor.rect.topLeftCorner + prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect)

        self.prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect = nil
    }

    override var isHiddenViaEmulation: Bool {
        prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect != nil
    }

    override func setSize(_ size: CGSize) {
        previousSize = getSize()
        axWindow.set(Ax.sizeAttr, size)
    }

    func getSize() -> CGSize? {
        axWindow.get(Ax.sizeAttr)
    }

    override func setTopLeftCorner(_ point: CGPoint) {
        axWindow.set(Ax.topLeftCornerAttr, point)
    }

    private func getTopLeftCorner() -> CGPoint? {
        axWindow.get(Ax.topLeftCornerAttr)
    }

    override func getRect() -> Rect? {
        guard let topLeftCorner = getTopLeftCorner() else { return nil }
        guard let size = getSize() else { return nil }
        return Rect(topLeftX: topLeftCorner.x, topLeftY: topLeftCorner.y, width: size.width, height: size.height)
    }
}

func shouldFloat(_ axWindow: AXUIElement) -> Bool {
    // Don't tile:
    // - Chrome cmd+f window ("AXUnknown" value)
    // - login screen (Yes fuck, it's also a window from Apple's API perspective) ("AXUnknown" value)
    // - XCode "Build succeeded" popup
    // - IntelliJ tooltips, context menus, drop downs
    // - macOS native file picker ("Open..." menu)
    //
    // Minimized windows or windows of a hidden app have subrole "AXDialog"
    axWindow.get(Ax.subroleAttr) != kAXStandardWindowSubrole
}

func getBindingDataForNewWindow(_ axWindow: AXUIElement, _ workspace: Workspace) -> BindingData {
    let parent: NonLeafTreeNode
    let index: Int
    if shouldFloat(axWindow) {
        parent = workspace
        index = INDEX_BIND_LAST
    } else {
        let mruWindow = workspace.mostRecentWindow
        if let mruWindow, let tilingParent = mruWindow.parent as? TilingContainer {
            parent = tilingParent
            index = mruWindow.ownIndex + 1
        } else {
            parent = workspace.rootTilingContainer
            index = INDEX_BIND_LAST
        }
    }
    return BindingData(parent: parent, adaptiveWeight: WEIGHT_AUTO, index: index)
}

extension UnsafeMutableRawPointer {
    var window: MacWindow? { Unmanaged.fromOpaque(self).takeUnretainedValue() }
}

private func destroyedObs(_ obs: AXObserver, ax: AXUIElement, notif: CFString, data: UnsafeMutableRawPointer?) {
    data?.window?.garbageCollect()
    refresh()
}
