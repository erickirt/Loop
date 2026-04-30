//
//  WindowActionEngine.swift
//  Loop
//
//  Created by Kai Azim on 2023-06-16.
//

import Defaults
import Scribe
import SwiftUI

/// Unified entry point for executing all window actions.
///
/// `WindowActionEngine` consolidates action execution logic previously scattered across
/// `WindowEngine`, `LoopManager`, and other files. It routes actions to appropriate handlers
/// and returns a result indicating success and any state changes.
///
/// **Note:** Screen change actions (`nextScreen`, `previousScreen`, etc.) are NOT handled here.
/// They are resolved by `LoopManager` which updates `resizeContext.screen` before calling `apply()`.
@Loggable
final class WindowActionEngine {
    static let shared = WindowActionEngine()

    @MainActor
    private var actionTasks: [CGWindowID: Task<Result, any Error>] = [:]

    /// Result of applying a window action
    struct Result {
        /// Whether the action was successfully applied
        let success: Bool
        /// For focus actions that change the target window
        let newTargetWindow: Window?

        static let noOp = Result(success: true, newTargetWindow: nil)
        static let failed = Result(success: false, newTargetWindow: nil)
        static let resized = Result(success: true, newTargetWindow: nil)

        static func focused(_ window: Window?) -> Result {
            Result(success: window != nil, newTargetWindow: window)
        }
    }

    /// Simplified apply for callers that don't need resize context tracking (URL commands, drag snap, etc.)
    ///
    /// - Parameters:
    ///   - action: The action to apply
    ///   - window: The target window
    ///   - screen: The screen to perform the action on
    /// - Returns: Result indicating success and any state changes
    func apply(
        _ action: WindowAction,
        window: Window?,
        screen: NSScreen
    ) async throws -> Result {
        let context = ResizeContext(window: window, screen: screen)
        context.setAction(to: action, parent: nil)
        await context.refreshResolvedState()
        return try await apply(context: context)
    }

    /// Apply a window action with explicit resize context tracking.
    /// The context should be updated by the caller before calling this function.
    ///
    /// - Parameters:
    ///   - action: The action to apply
    ///   - window: The target window (can be nil for some actions like focus navigation from screen center)
    ///   - resizeContext: Context containing tracking state for grow/shrink actions (passed by value, caller updates)
    /// - Returns: Result indicating success and any state changes
    /// - Throws: `CancellationError` if a new action is applied to the same window
    @concurrent
    func apply(context: ResizeContext) async throws -> Result {
        guard let windowID = context.window?.cgWindowID else {
            return try await performApply(context: context)
        }

        // Cancel any existing action on this window
        await actionTasks[windowID]?.cancel()

        // Create a task for this action
        let task = Task {
            let result = try await performApply(context: context)
            try Task.checkCancellation()
            return result
        }
        await MainActor.run {
            actionTasks[windowID] = task
        }

        // Await the task and clean up
        let result = try await task.value

        await MainActor.run {
            _ = actionTasks.removeValue(forKey: windowID)
        }

        return result
    }

    private func performApply(context: ResizeContext) async throws -> Result {
        log.info("Applying context: \(context)")

        let direction = context.action.direction

        // No-op actions: return early
        if direction.isNoOp || direction == .cycle {
            return .noOp
        }

        // Focus actions: find and focus the target window
        if direction.willFocusWindow {
            return handleFocusAction(context.action, currentWindow: context.window)
        }

        // Cross-space throws
        if let window = context.window, let destination = direction.spaceDestination {
            await throwWindow(window, to: destination)
            return .noOp
        }

        // Quick actions that don't require resize logic
        if let result = handleQuickAction(context.action, window: context.window) {
            return result
        }

        try await WindowEngine.performResize(context: context)
        return .resized
    }

    // MARK: - Focus Actions

    private func handleFocusAction(_ action: WindowAction, currentWindow: Window?) -> Result {
        let direction = action.direction
        var newTargetWindow: Window?

        if direction == .focusNextInStack {
            newTargetWindow = WindowUtility.focusNextWindowInStack(from: currentWindow)
        } else if let focusDirection = direction.focusDirection {
            newTargetWindow = WindowUtility.focusWindow(from: currentWindow, direction: focusDirection)
        }

        return .focused(newTargetWindow)
    }

    // MARK: - Quick Actions

    /// Handles quick actions that don't require the full resize flow.
    /// Returns nil if the action is not a quick action.
    private func handleQuickAction(_ action: WindowAction, window: Window?) -> Result? {
        guard let window else {
            // Quick actions require a window
            if [.hide, .minimize, .fullscreen, .minimizeOthers].contains(action.direction) {
                log.info("Cannot apply quick action without a target window")
                return .failed
            }
            return nil
        }

        switch action.direction {
        case .hide:
            window.toggleHidden()
            return .noOp
        case .minimize:
            window.toggleMinimized()
            return .noOp
        case .fullscreen:
            window.toggleFullscreen()
            return .noOp
        case .minimizeOthers:
            minimizeOtherWindows(exceptWindow: window)
            return .noOp
        default:
            return nil
        }
    }

    // MARK: - Helpers

    private func minimizeOtherWindows(exceptWindow: Window) {
        let allWindows = WindowUtility.windowList()
        let windowsToMinimize = allWindows.filter {
            $0.cgWindowID != exceptWindow.cgWindowID && !$0.minimized && !$0.isWindowHidden
        }

        log.info("Minimizing \(windowsToMinimize.count) other windows")

        for window in windowsToMinimize {
            window.minimized = true
        }
    }

    // MARK: - Cross-Space Window Throw

    enum SpaceDestination {
        case previousSpace
        case nextSpace
        case desktop(UInt)

        var hotKey: SLSSymbolicHotKey? {
            switch self {
            case .previousSpace: 79
            case .nextSpace: 81
            case let .desktop(n) where (1 ... 16).contains(n): SLSSymbolicHotKey(118 + n - 1)
            case .desktop: nil
            }
        }

        var description: String {
            switch self {
            case .previousSpace: "previous space"
            case .nextSpace: "next space"
            case let .desktop(n): "desktop \(n)"
            }
        }
    }

    private func throwWindow(_ window: Window, to space: SpaceDestination) async {
        guard let hotKey = space.hotKey else {
            log.error("invalid destination \(space.description)")
            return
        }

        // Capture the cursor position so we can restore it after the throw.
        let originalCursor = CGEvent(source: nil)?.location ?? .zero

        // Resolve the symbolic hotkey (also auto-enables it if disabled).
        guard let (keyCode, flags) = SkyLightToolBelt.resolveSymbolicHotKey(hotKey) else {
            return
        }

        // Compute the drag anchor: midX of minimize button, midY between window top and minimize button center.
        guard let minimizeButton: AXUIElement = try? window.axWindow.getValue(.minimizeButton),
              let minPos: CGPoint = try? minimizeButton.getValue(.position),
              let minSize: CGSize = try? minimizeButton.getValue(.size)
        else {
            log.error("could not resolve minimize button on focused window")
            return
        }
        let winFrame = window.frame
        let minRect = CGRect(origin: minPos, size: minSize)
        let anchor = CGPoint(
            x: minRect.midX,
            y: winFrame.origin.y + abs(winFrame.origin.y - minRect.minY) / 2.0
        )

        // Synthesize move + mouseDown + drag + mouseUp at anchor
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,    mouseCursorPosition: anchor, mouseButton: .left)
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: anchor, mouseButton: .left)
        let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: anchor, mouseButton: .left)
        let up   = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,   mouseCursorPosition: anchor, mouseButton: .left)
        move?.flags = []
        down?.flags = []
        drag?.flags = []
        up?.flags = []

        move?.post(tap: .cghidEventTap)
        down?.post(tap: .cghidEventTap)
        drag?.post(tap: .cghidEventTap)

        // Wait 50 ms before sending the space-switch hotkey
        try? await Task.sleep(for: .milliseconds(50))
        let kDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let kUp   = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        kDown?.flags = flags
        kUp?.flags = []
        kDown?.post(tap: .cghidEventTap)
        kUp?.post(tap: .cghidEventTap)

        // Wait 400 ms for the space transition animation, then release the mouse
        try? await Task.sleep(for: .milliseconds(400))
        up?.post(tap: .cghidEventTap)

        // Restore the cursor to its pre-throw position.
        CGWarpMouseCursorPosition(originalCursor)
    }
}
