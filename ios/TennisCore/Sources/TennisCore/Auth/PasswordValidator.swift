/// PasswordValidator — client-side instant feedback mirroring the backend Gate-1 OQ-2 rules.
///
/// Rules (both are LOAD-BEARING — different units):
///   - Minimum 8 **characters** (Swift `String.count`, i.e. Unicode grapheme clusters / runes)
///   - Maximum 72 **UTF-8 bytes** (bcrypt's hard truncation boundary)
///
/// This is pre-submission UX only. It does NOT replace the backend `400` whose
/// `{"error"}` payload surfaces via `APIError.validation` in `APIClient`.

/// The result of a password validation check.
public enum PasswordValidation: Equatable {
    /// Password satisfies all rules.
    case valid
    /// Fewer than 8 characters (grapheme count).
    case tooShort
    /// More than 72 UTF-8 bytes (bcrypt limit).
    case tooLong
}

public enum PasswordValidator {
    /// Validates `password` against the Gate-1 OQ-2 policy.
    ///
    /// Byte limit is checked before character count so that a pathological
    /// input that is simultaneously short in graphemes AND long in bytes
    /// (e.g. a few wide emoji) is correctly surfaced as `.tooLong`.
    public static func validate(_ password: String) -> PasswordValidation {
        if password.utf8.count > 72 {
            return .tooLong
        }
        if password.count < 8 {
            return .tooShort
        }
        return .valid
    }
}
