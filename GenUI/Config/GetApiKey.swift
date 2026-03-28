// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import Foundation

/// Resolves the Gemini API key using a priority chain, mirroring
/// Flutter's `io_get_api_key.dart`:
///
/// 1. Environment variable `GEMINI_API_KEY`
/// 2. User-entered key stored in UserDefaults (`@AppStorage`)
/// 3. Hardcoded fallback key
enum GetApiKey {
    private static let environmentKey = "GEMINI_API_KEY"
    private static let userDefaultsKey = "geminiAPIKey"
    private static let hardcodedKey = "AIzaSyAiGDbBcxBnqz0yPUnMLuVRoLSCak2mQ3Y"

    /// Returns the best available API key.
    ///
    /// Checks the process environment first (set via Xcode scheme or CLI),
    /// then the locally persisted key the user entered in Settings,
    /// and finally falls back to the built-in demo key.
    static func resolve() -> String {
        if let envKey = ProcessInfo.processInfo.environment[environmentKey],
           !envKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envKey
        }

        let stored = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        if !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return hardcodedKey
    }

    /// Whether the user has explicitly configured a key (env or UserDefaults).
    static var hasUserProvidedKey: Bool {
        if let envKey = ProcessInfo.processInfo.environment[environmentKey],
           !envKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        let stored = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        return !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
