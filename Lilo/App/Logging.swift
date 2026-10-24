import OSLog

extension Logger {
    /// All Lilo logs share this subsystem; `make logs` and `make logs-stream` filter on it.
    static let subsystem = "fr.arouillard.lilo"

    init(liloCategory: String) {
        self.init(subsystem: Logger.subsystem, category: liloCategory)
    }
}
