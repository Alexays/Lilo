# Release notes

For a change people using Lilo will notice, run `make changeset`. Choose `patch`, `minor`
or `major` for `lilo`, and describe what changes for the person using the app.
Commit the generated Markdown file with the code. Documentation, tests and build tooling
usually need no changeset.

The status check reads all pending notes. Its `HEAD` base and empty `changedFilePatterns`
list let documentation changes and release commits pass without a placeholder changeset.

Lilo ships as one app. The root `package.json` tracks its version; the UI and extension
bridge keep their own dependencies and share the app's version. All packages are private.

`make changeset-status` shows the pending release. Maintainers run `make changeset-version`
to consume the notes, update `CHANGELOG.md` and sync the app's versions and website metadata.
See [the release guide](../docs/RELEASING.md#version-bump) for the rest of the process and
[Changesets](https://github.com/changesets/changesets/tree/maintenance/v2/docs) for the file format.
