import Foundation

@main
struct OllamaSemanticLiveCheck {
    static func main() async {
        do {
            let unit = UnitProfile(name: "Cell membranes", subject: "生物", topics: ["细胞膜", "代谢"], context: "细胞膜的组成和跨膜运输")
            let source = SourceEntry(
                headword: "membrane",
                senses: [
                    SourceSense(sourceSenseID: "biology", partOfSpeech: "noun", gloss: "细胞膜；包围细胞的薄层", examples: [], explicitPhrases: [], domainHints: ["biology"], sourceRank: 10),
                    SourceSense(sourceSenseID: "music", partOfSpeech: "noun", gloss: "唱片的薄膜；音响振膜", examples: [], explicitPhrases: [], domainHints: ["music"], sourceRank: 10)
                ],
                provenance: SourceProvenance(provider: "fixture", sourceID: "membrane", retrievalDate: .now)
            )
            let recommender = OllamaSemanticRecommender()
            let scores = try await recommender.semanticScores(query: TopicNormalizer.queryText(for: unit), candidates: recommender.candidateTexts(source: source), model: OllamaSemanticRecommender.defaultModel)
            guard scores.count == 2, scores[0] > scores[1] else {
                fatalError("semantic ranking did not prefer the biology candidate: \(scores)")
            }
            print("PASS OllamaSemanticLive: biology=\(scores[0]), music=\(scores[1])")
        } catch {
            fatalError("FAIL OllamaSemanticLive: \(error.localizedDescription)")
        }
    }
}
