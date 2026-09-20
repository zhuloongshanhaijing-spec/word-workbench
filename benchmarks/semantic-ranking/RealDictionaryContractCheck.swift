import Foundation

// Real-input contract check. It is intentionally separate from the synthetic
// fixture test because release entries can contain many rare senses without
// examples. The invariant here is identity and fact preservation, not a fixed
// sense count.
@main
struct RealDictionaryContractCheck {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            fatalError("usage: RealDictionaryContractCheck <distribution.sqlite>")
        }
        do {
            let source = try OpenDictionarySource(databaseURL: URL(fileURLWithPath: CommandLine.arguments[1]))
            let entry = try await source.lookup(word: "strain")
            let ids = entry.senses.map(\.sourceSenseID)
            guard entry.senses.count >= 20 else {
                fatalError("真实 strain 义项数量异常：\(entry.senses.count)")
            }
            guard Set(ids).count == ids.count else {
                fatalError("真实 strain 仍含重复 sourceSenseID：\(ids)")
            }
            guard let biology = entry.senses.first(where: { $0.gloss.contains("菌株") }),
                  biology.sourceSenseID == "od:noun|et1|s2",
                  biology.examples.first?.english == "Scientists identified a new strain of the virus." else {
                fatalError("真实 biology 义项身份或事实不一致")
            }
            let resolved = SenseResolver.resolve(entry, for: UnitProfile(name: "Microbiology", subject: "生物", topics: ["microbiology"], context: "病毒株与遗传变异"))
            let resolvedSenses = resolved.groups.flatMap(\.senses)
            guard resolvedSenses.count == entry.senses.count,
                  Set(resolvedSenses.compactMap(\.sourceSenseID)) == Set(ids) else {
                fatalError("进入审核模型时义项或身份丢失")
            }
            print("PASS RealDictionaryContract: strain=\(entry.senses.count), unique IDs, facts and review mapping preserved")
        } catch {
            fatalError("FAIL RealDictionaryContract: \(error.localizedDescription)")
        }
    }
}
