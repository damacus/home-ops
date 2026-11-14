# Keeping these notes useful

Use this when adding a guide, recording an incident or finishing a project.
The aim is to help the next visit, which is quite often me in a hurry.

## Where to write

Keep a service's main guide in its folder README. Cluster-wide operating
instructions live in `docs/`; provisioning stays in `provisioning/`.
Bridgetown publishes those sources directly. Don't copy them into `site_docs/`,
which owns navigation and presentation.

Start with what reading the page will help someone do. Assume basic Kubernetes
knowledge, explain the local oddities, and put common actions before background.
Use one main operating guide with links to substantial reference material and
incidents. Four or more second-level headings get an automatic contents list.

## Record work without inventing status

A project page needs a short goal, dated current position, meaningful stages,
next step and blockers. Link the PRs or incidents that explain the work.
Write down what was checked: configuration in Git, a merged change and a live
verification are different evidence.

Use front matter to place a project in the site:

```yaml
doc_type: project
status: active
reviewed: "2026-11-14"
description: A short explanation of the work and what remains.
```

Supported states are `active`, `paused` and `completed`. Only active projects
appear on the home page. Paused work appears below them in In progress.
Don't mark old unfinished work active just because it still has unchecked boxes.

## Finish and keep the lessons

When a project completes, set `status: completed` on its existing page. It
moves into History without changing its URL. Update the service guide to
describe operating the result; the completed migration steps aren't its
day-to-day instructions.

For an incident or historical document use:

```yaml
doc_type: history
description: What happened and why the reader might care.
```

Keep symptoms, misleading clues, failed approaches and the reason the fix
worked. Link incidents from relevant troubleshooting sections. Mark old
commands and machine-specific identifiers as historical. Remove obsolete
project administration and repeated checklists from current guides.

Preserve the root `docs.txt` and its Armbian field knowledge. Stale sections
can be corrected while retaining the useful history.

## Check the site

```console
bundle exec bin/bridgetown deploy
```

Check changed pages, navigation, internal links, contents anchors, search and
a narrow viewport. Long tables must scroll within the article. The rendered
site is under `output/`; keep generated files out of Git. No extra test
framework or workflow is needed for writing these notes.
