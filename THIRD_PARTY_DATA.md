# Third-party data: Open Dictionary

The official WordWorkbench macOS release may include Open Dictionary's
`distribution.sqlite` as a separately licensed data component.

- Data project: [ahpxex/open-dictionary](https://github.com/ahpxex/open-dictionary)
- Data provenance: English Wiktionary contributors, extracted with Wiktextract,
  then curated and structured by Open Dictionary.
- Data license: [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)
- Code in this repository is licensed separately (see [LICENSE](LICENSE) and the
  License section of [README.md](README.md)); it is **not** CC BY-SA 4.0, and this
  project's code license never overrides or re-licenses the data terms below.

If you redistribute an application package that contains this database, you
must preserve this notice, give the required attribution, and comply with the
ShareAlike terms for the data component. A suitable attribution line is:

> Contains data from Open Dictionary (https://github.com/ahpxex/open-dictionary),
> derived from English Wiktionary via Wiktextract. Data licensed under
> CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/).

The data must not be committed to this source repository. Release builders may
place it at `data/open-dictionary-v2/distribution.sqlite`; `outputs/build.sh`
then copies it only into the generated `.app` package.

The app checks GitHub's official Open Dictionary Release metadata at startup.
It does not silently download a dictionary. When the user confirms an update,
the app downloads `distribution.sqlite.gz`, checks the publisher-provided
SHA-256 digest and asset size, extracts to a staging file, runs a real SQLite
lookup, and only then replaces the active local database. The prior database is
kept as `distribution.sqlite.previous` by the filesystem replacement step.

## Derived evaluation fixtures

`benchmarks/semantic-ranking/generate_heldout_cases.py` exports candidate text
from the local database to build the independent held-out evaluation set. The
generated JSON contains dictionary text and is therefore written to the ignored
`.harness-local/` area; it is **not** committed to this repository.
Only the generator script and its case specification are committed, so the
evaluation stays reproducible without redistributing the data. Anyone re-running
it must respect the CC BY-SA 4.0 attribution and ShareAlike terms above.

## Local model runtime (separate component)

The optional local reranker in `tools/local-reranker/` downloads
`bge-reranker-v2-m3` GGUF weights (Apache-2.0) and a llama.cpp runtime (MIT) into
ignored cache directories. Neither is committed. See
`tools/local-reranker/README.md` for versions, sizes, checksums and the
uninstall command.
