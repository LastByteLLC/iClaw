import Foundation

/// Writes an Encodable value as pretty-printed JSON to a file in the given directory.
func writeJSONFile<T: Encodable>(_ value: T, to filename: String, in directory: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else { return }
    try? data.write(to: URL(fileURLWithPath: "\(directory)/\(filename)"))
}
