#if DEBUG
extension WindowRenderer {
    /// Lane B's pages, each drawn as the page under the field: Today
    /// (`nav-today-*`), History (`nav-history-*`), Library's lenses over
    /// History (`library-*`), About You (`nav-about-you*`) and Privacy
    /// (`nav-privacy*`). Drawn with every other scene by `--render-window`.
    static var libraryScenes: [Scene] {
        todayScenes + historyScenes
    }
}
#endif
