import ColonCore

/// The GIF search panel as the coordinator sees it (implemented in Colon/GIF).
protocol GIFPicking: AnyObject {
    func show(context: PredictionContext, pendingText: String)
    func dismiss()
}
