@testable import SecondBrainMCP

/// Builds focused resource ceilings without repeating the production policy.
func searchTestLimits(
    maximumDirectoryEntries: Int? = nil,
    maximumFiles: Int? = nil,
    maximumFileBytes: Int? = nil,
    maximumAggregateBytes: Int? = nil,
    maximumSectionsPerFile: Int? = nil,
    maximumMarkdownLines: Int? = nil,
    maximumFrontMatterLines: Int? = nil,
    maximumTags: Int? = nil,
    maximumAggregateTagBytes: Int? = nil,
    maximumMetadataCharacters: Int? = nil,
    maximumMetadataBytes: Int? = nil,
    maximumSnippetCharacters: Int? = nil,
    maximumSnippetBytes: Int? = nil,
    maximumResponseBytes: Int? = nil,
    maximumSourceTokensPerField: Int? = nil,
    maximumTokenComparisons: Int? = nil,
    maximumFuzzyComparisons: Int? = nil,
    maximumEditDistanceCells: Int? = nil,
    maximumQueuedRequests: Int? = nil,
    maximumStructuredValuesPerFile: Int? = nil
) -> SearchResourceLimits {
    let base = SearchResourceLimits.default
    return SearchResourceLimits(
        maximumQueryBytes: base.maximumQueryBytes,
        maximumQueryTokens: base.maximumQueryTokens,
        maximumTokenScalars: base.maximumTokenScalars,
        maximumResults: base.maximumResults,
        maximumDirectoryEntries: maximumDirectoryEntries
            ?? base.maximumDirectoryEntries,
        maximumFiles: maximumFiles ?? base.maximumFiles,
        maximumFileBytes: maximumFileBytes ?? base.maximumFileBytes,
        maximumAggregateBytes: maximumAggregateBytes
            ?? base.maximumAggregateBytes,
        maximumSectionsPerFile: maximumSectionsPerFile
            ?? base.maximumSectionsPerFile,
        maximumMarkdownLines: maximumMarkdownLines
            ?? base.maximumMarkdownLines,
        maximumFrontMatterLines: maximumFrontMatterLines
            ?? base.maximumFrontMatterLines,
        maximumTags: maximumTags ?? base.maximumTags,
        maximumAggregateTagBytes: maximumAggregateTagBytes
            ?? base.maximumAggregateTagBytes,
        maximumCandidates: base.maximumCandidates,
        maximumMetadataCharacters: maximumMetadataCharacters
            ?? base.maximumMetadataCharacters,
        maximumMetadataBytes: maximumMetadataBytes
            ?? base.maximumMetadataBytes,
        maximumSnippetCharacters: maximumSnippetCharacters
            ?? base.maximumSnippetCharacters,
        maximumSnippetBytes: maximumSnippetBytes ?? base.maximumSnippetBytes,
        maximumResponseBytes: maximumResponseBytes ?? base.maximumResponseBytes,
        maximumSourceTokensPerField: maximumSourceTokensPerField
            ?? base.maximumSourceTokensPerField,
        maximumTokenComparisons: maximumTokenComparisons
            ?? base.maximumTokenComparisons,
        maximumFuzzyComparisons: maximumFuzzyComparisons
            ?? base.maximumFuzzyComparisons,
        maximumEditDistanceCells: maximumEditDistanceCells
            ?? base.maximumEditDistanceCells,
        maximumQueuedRequests: maximumQueuedRequests
            ?? base.maximumQueuedRequests,
        maximumStructuredValuesPerFile: maximumStructuredValuesPerFile
            ?? base.maximumStructuredValuesPerFile
    )
}
