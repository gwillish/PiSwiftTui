import Foundation

@MainActor
final class ToolTimerState {
    var startedAt: Date?
    var endedAt: Date?
    var timer: Task<Void, Never>?
    let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    deinit { timer?.cancel() }
}

@MainActor
func toolTimerState(_ context: ToolRenderContext) -> ToolTimerState {
    if let state = context.state.values["timer"] as? ToolTimerState { return state }
    let state = ToolTimerState()
    context.state.values["timer"] = state
    return state
}

/// Start the row clock once tool execution starts.
@MainActor
func startToolTimer(_ context: ToolRenderContext) {
    let state = toolTimerState(context)
    if context.executionStarted && state.startedAt == nil {
        state.startedAt = state.now()
        state.endedAt = nil
    }
}

@MainActor
func toolTimerText(_ context: ToolRenderContext, isPartial: Bool) -> String? {
    let state = toolTimerState(context)
    if state.startedAt != nil && isPartial && state.timer == nil {
        let invalidate = context.invalidate
        state.timer = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                guard !Task.isCancelled else { break }
                invalidate()
            }
        }
    }
    if !isPartial || context.isError {
        if state.endedAt == nil { state.endedAt = state.now() }
        state.timer?.cancel()
        state.timer = nil
    }
    if !isPartial, let durationMs = context.durationMs {
        return "Took " + formatToolDuration(Double(durationMs) / 1000)
    }
    guard let startedAt = state.startedAt else { return nil }
    let duration = formatToolDuration((state.endedAt ?? state.now()).timeIntervalSince(startedAt))
    return "\(isPartial ? "Elapsed" : "Took") \(duration)"
}

func formatToolDuration(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let whole = Int(seconds)
    let minutes = whole / 60
    let remainingSeconds = whole % 60
    if minutes < 60 { return "\(minutes)m \(remainingSeconds)s" }
    return "\(minutes / 60)h \(minutes % 60)m \(remainingSeconds)s"
}
