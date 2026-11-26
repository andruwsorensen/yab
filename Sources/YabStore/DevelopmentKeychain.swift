/// Legacy service names must not let a development app reach released credentials.
public enum DevelopmentKeychain {
    /// Keep production identities stable; give each development profile its own service.
    public static func service(_ legacy: String, development: Bool = Store.development,
                               profile: String = Store.name) -> String {
        development ? "\(legacy) · \(profile)" : legacy
    }
}
