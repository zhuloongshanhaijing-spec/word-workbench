import Foundation

@main
struct SemanticRecommendationCheck {
    static func main() {
        let unit = UnitProfile(name: "Cell membranes", subject: "生物", topics: ["细胞膜", "代谢"], context: "细胞膜的组成和跨膜运输")
        let biology = SourceSense(sourceSenseID: "bio", partOfSpeech: "noun", gloss: "膜；薄膜", examples: [], explicitPhrases: [], domainHints: ["biology"], sourceRank: 10)
        let music = SourceSense(sourceSenseID: "music", partOfSpeech: "noun", gloss: "膜；唱片", examples: [], explicitPhrases: [], domainHints: ["music"], sourceRank: 10)
        let source = SourceEntry(headword: "membrane", senses: [music, biology], provenance: SourceProvenance(provider: "fixture", sourceID: "membrane", retrievalDate: .now))

        var entry = SenseResolver.resolve(source, for: unit)
        let initial = entry.groups.flatMap(\.senses)
        guard initial.first?.sourceSenseID == "bio", initial.first?.selected == true else { fatalError("Chinese subject alias did not prioritize biology rule") }

        RecommendationPolicy.applyEmbeddingScores(["bio": 0.86, "music": -0.18], to: &entry)
        let scored = entry.groups.flatMap(\.senses)
        guard scored.first?.sourceSenseID == "bio", scored.first?.selected == true,
              scored.last?.selected == false,
              scored.first?.recommendation?.engine == .ollamaEmbedding else {
            fatalError("embedding score fusion or conservative default selection failed")
        }
        print("PASS SemanticRecommendation: bilingual fallback, score fusion, conservative selection")
    }
}
