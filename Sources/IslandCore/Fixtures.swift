import Foundation

public enum Fixtures {
    public static let referenceNow = APIDateParser.parse("2026-10-02T12:00:00Z") ?? Date(timeIntervalSince1970: 1790942400)
    public static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else { return Data() }
        return data
    }
}
