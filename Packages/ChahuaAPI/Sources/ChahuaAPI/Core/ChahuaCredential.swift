public enum ChahuaCredential: Sendable, Equatable {
    case session(token: String)
    case uid(Int32)
}
