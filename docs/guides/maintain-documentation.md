---
type: Guide
title: "Maintain documentation"
description: "Maintain stable OKF documents and terminology with controlled technical English."
docId: DOC-4
tags: ["documentation", "terminology"]
generated:
  by: process:codex
  at: 2026-10-02T16:49:46Z
---

# Maintain documentation

The repository has three OKF v0.2 bundles.

| Directory | Mori bundle | Profile |
| --- | --- | --- |
| `docs/user` | `user-documentation` | `mori/user-documentation-profile.dhall` |
| `docs/guides` | `guides` | `mori/user-documentation-profile.dhall` |
| `docs/terminology` | `terminology` | `mori/terminology-profile.dhall` |

The selectors pin v0.19.0 of `mori://shinzui/okf-profiles` with a Dhall integrity hash.
The project manifest declares each bundle and its published profile binding.
Validation requires `okf` 0.9.0.0 or later, Dhall, and Mori with `terms validate`.

## Write the content

Use [ASD-STE100 Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf) for the writing rules and dictionary.
The new user docs, guides, and term definitions use this writing standard.
Earlier specifications, plans, and example notes remain outside this editorial scope.

1. Use the approved meaning and part of speech for each general word.
2. Define necessary project technical names in the terminology bundle.
3. Use the same technical name for the same concept.
4. Write instructions in the imperative form.
5. Put one instruction in each sentence.
6. Keep procedural sentences within 20 words and descriptive sentences within 25 words.
7. Use active voice and short paragraphs about one subject.
8. Put necessary conditions before the applicable instruction.
9. Keep command names, configuration keys, and code identifiers exact.
10. Compare each procedure with its source code and runnable example.

Technical names include database objects, file formats, protocols, package names, and documented project concepts.
Technical verbs describe software operations such as compile, configure, validate, and run.
These permissions do not make arbitrary general words technical terms.
Code blocks keep their programming language syntax.

## Add a page or term

1. Select the bundle that matches the reader's task.
2. Allocate the next unused `DOC-N` or `TERM-N` handle.
3. Add the required frontmatter from the applicable profile.
4. Record the actual producer and UTC content revision time in `generated`.
5. Link the page from the appropriate navigation page.

   Document types are `Navigation`, `Tutorial`, `Guide`, `Explanation`, `Reference`, and `Runbook`.
   Each term has `type: Term`, a one-sentence definition, and `status: current` or `deprecated`.
   A deprecated term also identifies its replacement.

Keep each term at the terminology bundle root.
Use topic tags to classify terms.
Add new terms to [Find a term](../user/terminology.md).
Use `related` for associated concepts and `broader` only for a more general concept.
Use repository-relative anchors for evidence.
Use canonical `mori://` URIs for references to other repositories.
Do not reuse or renumber existing handles.
Do not claim independent verification for your own review.

## Validate the change

1. Regenerate the index for each changed bundle.

   ```sh
   okf index docs/user --write --okf-version 0.2
   okf index docs/guides --write --okf-version 0.2
   okf index docs/terminology --write --okf-version 0.2
   ```

2. Record the actual change in the applicable log.

   ```sh
   okf log add docs/user --kind Update -m "Describe the actual change."
   ```

3. Run the documentation gate.

   ```sh
   just check-docs
   ```

4. Review the diff for unintended changes.

OKF checks structure, profile fields, and log coverage.
Mori checks terminology relationships and evidence anchors.
These checks do not certify ASD-STE100 vocabulary or factual accuracy.
Review both against the standard and project evidence.
