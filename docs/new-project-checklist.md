# New workspace checklist

1. Copy `templates/rooignore` into the target workspace as `.rooignore` and adjust project-specific generated folders.
2. Start Embarsy: `scripts/start.sh all`.
3. Open the workspace in VSCode.
4. Configure Roo Code with `docs/roo-code-setup.md`.
5. Start indexing and wait for the green Roo status.
6. Run 8–10 natural-language baseline queries, for example:
   - authentication logic
   - API error handling
   - database connection setup
   - feature flag checks
   - request validation
   - background job processing
   - logging and tracing
   - cache invalidation
7. Save a small function change and verify that Roo updates the relevant block without a full re-index.

