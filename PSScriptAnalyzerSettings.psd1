@{
    # Fail CI on genuine correctness/style issues, but allow plural nouns:
    # several internal helpers (Get-Targets, Get-Submodules, ...) return
    # collections, where a plural noun is the clearer, correct name.
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSUseSingularNouns'
    )
}
