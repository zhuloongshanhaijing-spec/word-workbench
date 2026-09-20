import Foundation

@main
struct OpenDictionaryLifecycleCheck {
    static func main() {
        do {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let release = try JSONDecoder().decode(OpenDictionaryRelease.self, from: Data(contentsOf: url))
            guard release.tagName == "v2.0",
                  release.sqliteAsset?.size == 216_962_932,
                  release.sqliteAsset?.digest?.hasPrefix("sha256:") == true else {
                fatalError("release fixture did not preserve update metadata")
            }
            print("PASS OpenDictionaryLifecycle: \(release.tagName), signed SQLite asset")
        } catch {
            fatalError("FAIL OpenDictionaryLifecycle: \(error.localizedDescription)")
        }
    }
}
