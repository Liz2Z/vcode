import Foundation

// Read only the files needed by visible result rows, off the UI thread. The
// bounded cache is owned by one query and released when its results close.
final class ReferencePreviewStore {
    private let queue = DispatchQueue(label: "vcode.references.previews", qos: .userInitiated)
    private var cache: [URL: [String]] = [:]
    private var order: [URL] = []

    func line(at location: CodeLocation, completion: @escaping (String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let url = location.url.standardizedFileURL
            var lines = self.cache[url]
            if lines == nil {
                let resolved = url.resolvingSymlinksInPath()
                if let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
                   attributes[.type] as? FileAttributeType == .typeRegular,
                   let size = attributes[.size] as? NSNumber, size.intValue <= 4 * 1024 * 1024,
                   let data = try? Data(contentsOf: resolved), !data.contains(0), let text = String(data: data, encoding: .utf8) {
                    lines = text.components(separatedBy: "\n")
                    if self.order.count >= 4 { self.cache.removeValue(forKey: self.order.removeFirst()) }
                    self.order.append(url)
                    self.cache[url] = lines
                }
            }
            let line = lines.flatMap { $0.indices.contains(location.line) ? $0[location.line] : nil }
            DispatchQueue.main.async { completion(line) }
        }
    }
}
