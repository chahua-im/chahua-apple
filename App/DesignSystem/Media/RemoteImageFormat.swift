enum RemoteImageFormat {
    static func isAnimated(contentType: String) -> Bool {
        switch contentType.lowercased().split(separator: ";", maxSplits: 1).first {
        case "image/gif", "image/apng", "image/webp":
            true
        default:
            false
        }
    }
}
