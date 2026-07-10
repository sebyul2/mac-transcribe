import Foundation

/// Thin wrapper around the DeepL REST API (v2/translate). Stateless — each
/// call is one HTTP POST. Source language is optional: omit it and DeepL
/// auto-detects, which handles mixed-language meetings naturally.
enum DeepLTranslator {

    struct Translation {
        let text: String
        let detectedSourceLang: String?
    }

    struct DeepLError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// DeepL language codes for the target dropdown.
    static let targetLanguages: [(code: String, display: String)] = [
        ("EN-US", "English (US)"),
        ("EN-GB", "English (UK)"),
        ("KO", "한국어"),
        ("JA", "日本語"),
        ("ZH-HANS", "简体中文"),
        ("ZH-HANT", "繁體中文"),
        ("DE", "Deutsch"),
        ("FR", "Français"),
        ("ES", "Español"),
        ("PT-BR", "Português (BR)"),
        ("RU", "Русский"),
    ]

    /// DeepL source language codes (a subset — auto-detect covers the rest).
    static let sourceLanguages: [(code: String, display: String)] = [
        ("", "Auto-detect"),
        ("EN", "English"),
        ("KO", "한국어"),
        ("JA", "日本語"),
        ("ZH", "中文"),
        ("DE", "Deutsch"),
        ("FR", "Français"),
        ("ES", "Español"),
        ("PT", "Português"),
        ("RU", "Русский"),
    ]

    /// Translates `text` via the DeepL API. `sourceLang` may be nil or empty
    /// for auto-detection. Calls `completion` on an unspecified queue.
    static func translate(
        _ text: String,
        targetLang: String,
        sourceLang: String? = nil,
        apiKey: String,
        completion: @escaping (Result<Translation, Error>) -> Void
    ) {
        guard !apiKey.isEmpty else {
            completion(.failure(DeepLError(message: "DeepL API key is not set")))
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.success(Translation(text: "", detectedSourceLang: nil)))
            return
        }

        let baseURL = apiKey.hasSuffix(":fx")
            ? "https://api-free.deepl.com/v2/translate"
            : "https://api.deepl.com/v2/translate"

        var params = "text=\(urlEncode(text))&target_lang=\(targetLang)"
        if let src = sourceLang, !src.isEmpty {
            params += "&source_lang=\(src)"
        }

        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let http = response as? HTTPURLResponse else {
                completion(.failure(DeepLError(message: "No response")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                completion(.failure(DeepLError(message: "HTTP \(http.statusCode): \(body)")))
                return
            }
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let translations = json["translations"] as? [[String: Any]],
                      let first = translations.first,
                      let translated = first["text"] as? String else {
                    completion(.failure(DeepLError(message: "Unexpected response format")))
                    return
                }
                let detected = first["detected_source_language"] as? String
                completion(.success(Translation(text: translated, detectedSourceLang: detected)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: "=", with: "%3D") ?? s
    }
}
