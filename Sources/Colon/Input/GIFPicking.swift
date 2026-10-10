import ColonCore

/// The GIF search panel as seen by the coordinator. Declared here so the input and GIF branches
/// both compile; the GIF controller conforms and `AppCoordinator.gifPicker` holds it.
@MainActor
protocol GIFPicking: AnyObject {
    /// Opens GIF search for the app being typed in. `pendingText` holds what the user typed after
    /// `:gif ` before the panel had the keyboard; it seeds the search field.
    func show(context: PredictionContext, pendingText: String)
    func dismiss()
}
