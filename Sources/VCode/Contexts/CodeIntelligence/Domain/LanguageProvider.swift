import Foundation

struct LanguageProvider {
    let name: String
    let extensions: Set<String>

    static let typescript = LanguageProvider(name: "TypeScript", extensions: ["ts", "tsx", "mts", "cts"])

    func languageID(for url: URL) -> String { url.pathExtension == "tsx" ? "typescriptreact" : "typescript" }
}
