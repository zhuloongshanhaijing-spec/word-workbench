import Foundation

@main
struct OpenDictionaryAdapterCheck {
    static func main() async {
        do {
            let path = URL(fileURLWithPath: CommandLine.arguments[1])
            let source: OpenDictionarySource
            if path.pathExtension == "sqlite" {
                source = try OpenDictionarySource(databaseURL: path)
            } else {
                source = try OpenDictionarySource(fixtureData: Data(contentsOf: path))
            }
            let entry = try await source.lookup(word: "strain")
            guard entry.senses.count == 2,
                  entry.senses.contains(where: { $0.gloss.contains("菌株") }),
                  entry.senses.allSatisfy({ !$0.examples.isEmpty }) else {
                fatalError("fixture did not preserve expected senses/examples")
            }
            let biology = UnitProfile(name: "Biology", subject: "biology", topics: ["microbiology"])
            let resolved = SenseResolver.resolve(entry, for: biology)
            guard resolved.groups.first?.senses.first?.gloss.contains("菌株") == true else {
                fatalError("unit topic did not prioritize biology sense")
            }
            print("PASS OpenDictionaryAdapter: \(entry.headword), \(entry.senses.count) senses, unit priority")
        } catch {
            fatalError("FAIL OpenDictionaryAdapter: \(error.localizedDescription)")
        }
    }
}
