@testable import SecondBrainMCP

/// Builds focused resource ceilings without repeating the production policy.
func searchTestLimits(
    maximumDirectoryEntries: Int? = nil,
    maximumFiles: Int? = nil,
    maximumFileBytes: Int? = nil,
    maximumAggregateBytes: Int? = nil,
    maximumAggregateProjectionBytes: Int? = nil,
    maximumAggregateSections: Int? = nil,
    maximumSectionsPerFile: Int? = nil,
    maximumMarkdownLines: Int? = nil,
    maximumFrontMatterLines: Int? = nil,
    maximumTags: Int? = nil,
    maximumAggregateTagBytes: Int? = nil,
    maximumCandidates: Int? = nil,
    maximumMetadataCharacters: Int? = nil,
    maximumMetadataBytes: Int? = nil,
    maximumSnippetCharacters: Int? = nil,
    maximumSnippetBytes: Int? = nil,
    maximumResponseBytes: Int? = nil,
    maximumSourceTokensPerField: Int? = nil,
    maximumLiteralOccurrencesPerField: Int? = nil,
    maximumLiteralOccurrencesPerRequest: Int? = nil,
    maximumTokenComparisons: Int? = nil,
    maximumFuzzyComparisons: Int? = nil,
    maximumEditDistanceCells: Int? = nil,
    maximumQueuedRequests: Int? = nil,
    maximumStructuredValuesPerFile: Int? = nil,
    maximumPDFPagesPerFile: Int? = nil,
    maximumPDFTextBytesPerFile: Int? = nil
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
        maximumAggregateProjectionBytes: maximumAggregateProjectionBytes
            ?? base.maximumAggregateProjectionBytes,
        maximumAggregateSections: maximumAggregateSections
            ?? base.maximumAggregateSections,
        maximumSectionsPerFile: maximumSectionsPerFile
            ?? base.maximumSectionsPerFile,
        maximumMarkdownLines: maximumMarkdownLines
            ?? base.maximumMarkdownLines,
        maximumFrontMatterLines: maximumFrontMatterLines
            ?? base.maximumFrontMatterLines,
        maximumTags: maximumTags ?? base.maximumTags,
        maximumAggregateTagBytes: maximumAggregateTagBytes
            ?? base.maximumAggregateTagBytes,
        maximumCandidates: maximumCandidates ?? base.maximumCandidates,
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
        maximumLiteralOccurrencesPerField: maximumLiteralOccurrencesPerField
            ?? base.maximumLiteralOccurrencesPerField,
        maximumLiteralOccurrencesPerRequest: maximumLiteralOccurrencesPerRequest
            ?? base.maximumLiteralOccurrencesPerRequest,
        maximumTokenComparisons: maximumTokenComparisons
            ?? base.maximumTokenComparisons,
        maximumFuzzyComparisons: maximumFuzzyComparisons
            ?? base.maximumFuzzyComparisons,
        maximumEditDistanceCells: maximumEditDistanceCells
            ?? base.maximumEditDistanceCells,
        maximumQueuedRequests: maximumQueuedRequests
            ?? base.maximumQueuedRequests,
        maximumStructuredValuesPerFile: maximumStructuredValuesPerFile
            ?? base.maximumStructuredValuesPerFile,
        maximumPDFPagesPerFile: maximumPDFPagesPerFile
            ?? base.maximumPDFPagesPerFile,
        maximumPDFTextBytesPerFile: maximumPDFTextBytesPerFile
            ?? base.maximumPDFTextBytesPerFile
    )
}
