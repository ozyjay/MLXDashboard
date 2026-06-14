# Discover Model Variant Rows Design

## Goal

Improve Discover search results so related Hugging Face MLX model repos are presented as one model family row with visible quantization variants, similar in spirit to OllamaPull's compact search list. The user should be able to scan a family, compare variants such as `4bit`, `6bit`, `8bit`, `bf16`, and `DWQ`, and install the exact selected Hugging Face repo.

## Scope

This feature changes the Discover search presentation and selection model. It does not change model download mechanics, installed-model cache layout, provider routing, role presets, or `mlx_lm.server` startup behavior.

Unsupported runtime models remain filtered by the existing compatibility path. A later "show unsupported" toggle can revisit disabled unsupported variants, but this first pass keeps Discover focused on runnable candidates.

## User Experience

Discover remains a dense, table-first workflow. Search results are grouped into one row per model family. The model column becomes richer while preserving compact scanning:

```text
Model family name
model_type / downloads summary / compatibility summary
[4bit] [6bit] [8bit] [DWQ] [bf16]
```

Each variant chip represents one exact Hugging Face repo. The selected chip controls the row action. Installing from the row installs the selected variant's repo ID.

Installed and failed status are shown per chip when the exact repo ID matches an existing model registry record. The row action reflects whether the selected variant is installable or already installed.

## Default Variant Selection

Each family row has a selected variant after search grouping. The default selection rule is:

1. Prefer `4bit`.
2. Then prefer `6bit`.
3. Then choose the variant with the highest downloads.

This favors variants that are likely to run comfortably on a local Apple Silicon machine while still giving the user explicit control.

## Data Model

The Python search bridge continues to return exact repo-level `HuggingFaceModelSummary` values because install operations require precise repo IDs.

The dashboard layer groups these summaries into a new family-level model, conceptually:

```swift
struct ModelFamilySearchResult {
    var id: String
    var displayName: String
    var variants: [ModelSearchVariant]
    var selectedVariantID: String
}

struct ModelSearchVariant {
    var id: String
    var label: String
    var downloads: Int?
    var likes: Int?
    var modelType: String?
    var installState: VariantInstallState
}
```

Exact names can follow local style during implementation. The important boundary is that `HuggingFaceModelSummary` remains repo-level, while Discover view state becomes family-level.

## Grouping

Grouping uses a conservative normalized family key derived from the Hugging Face repo name. It strips known quantization and variant suffixes such as:

- `4bit`, `6bit`, `8bit`
- `bf16`, `fp16`
- `DWQ`
- `Q4`, `Q6`, `Q8`

The normalizer handles common separators like `-`, `_`, and spaces near the suffix.

If the normalizer cannot confidently identify a variant suffix, the result remains a one-variant family row. Avoid merging unrelated repos just because their names share a prefix.

## Variant Labels

Variant labels should be short and familiar:

- `4bit`
- `6bit`
- `8bit`
- `bf16`
- `DWQ`
- `Q4`
- `Q8`

If multiple labels apply, prefer the more descriptive label from the repo suffix. If no suffix is detected, use `Default`.

## Selection And Install Flow

Search produces grouped family rows and initializes each row's selected variant using the default variant rule.

Clicking a variant chip updates that family row's selected variant. The Install button installs the selected variant's exact repo ID. Existing install, retry, and continuation paths should receive a `HuggingFaceModelSummary` for that selected repo, so downstream install behavior stays unchanged.

Search selection state should move from selecting a repo row to selecting a family row plus variant. Where possible, keep view-model APIs small and testable rather than pushing grouping logic into SwiftUI views.

## Status And Compatibility

Runtime compatibility filtering remains in the search pipeline before grouping. Known unsupported variants are not shown in this first pass.

Installed and failed status are derived per variant from the model registry using exact repo ID matches. A family row can therefore contain both installed and installable variants.

The search status text can continue to report the number of displayed family rows and filtered unsupported repos. It does not need to list every hidden variant.

## Error Handling

If variant metadata is incomplete, keep the variant visible as long as the repo itself is otherwise runnable or compatibility is unknown. Missing downloads or likes should display as the existing placeholder behavior.

If grouping encounters ambiguous names, prefer separate one-variant rows. Incorrectly failing to group is acceptable; incorrectly merging unrelated models is not.

## Testing

Add focused tests for:

- grouping `Foo-4bit`, `Foo-6bit`, and `Foo-bf16` into one family;
- leaving unrelated names separate;
- selecting `4bit` by default, then `6bit`, then highest downloads;
- installing the selected variant repo ID;
- preserving installed or failed status per variant;
- keeping unsupported runtime variants out of grouped rows through the existing compatibility filter.

## Non-Goals

- No new Hugging Face download strategy.
- No queue UI.
- No model-detail drawer.
- No remote `mlx_lm.server` changes.
- No "show unsupported" toggle in this pass.
