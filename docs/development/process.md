# Issues, plans and releases

Work goes through four steps: **issue → plan → approval → pull request**.
Nothing is implemented before its plan is approved. The maintainer decides
what gets planned and what gets built; labels carry these decisions.

## 1. Issue

Every change starts as a GitHub issue:

- **Bug report** and **Feature request** templates ask for what is needed
  (steps and version for bugs, problem and "done when" for features).
- Findings from test reports become issues, one per topic, with a link to
  the report.
- Security problems go to the
  [private vulnerability report](https://github.com/pklnx/document-archive/security/advisories/new),
  not to a public issue.

## 2. Plan

The maintainer labels an issue **`plan`** to ask for an implementation plan.
The plan is posted as a comment on the issue, and the label changes from
`plan` to **`review`**. A plan covers:

- the approach and the files or components it touches,
- data model, iCloud sync or behavior changes (a change to `DocumentArchive/Model`
  means `schema-change`),
- what is sent to external services (Mistral) and whether it can be turned off,
- which automated tests will be added (tests are mandatory), and what is
  checked by hand on macOS and iOS,
- open questions and decisions to make,
- the expected size (one pull request or several).

## 3. Review and approval

The maintainer reads the plan and asks questions or for changes in the
issue; the plan is updated in place. When it is good, the maintainer
replaces `review` with **`ready`**. Only `ready` issues are implemented.

The order of `ready` issues is chosen during implementation, with a short
reason (dependencies between issues, risk, size). Changes to an approved plan
that come up during the work are noted in the issue before the pull request.

## 4. Pull request

Each issue gets its own branch and pull request. The description says
`Closes #N`, so merging closes the issue. Labels follow the
[label table](./#pull-requests-and-labels). The pull request includes tests for
the behavior it changes (see [Tests](./#tests)); without them it is not ready
for review. Which tests the implementer, the reviewer and CI run is in the
[test strategy](./#test-strategy). CI must be green; the maintainer reviews and enables auto-merge.

## Labels

| Label | Set by | Meaning |
|---|---|---|
| `plan` | maintainer | Please write an implementation plan. |
| `review` | implementer | The plan is posted and waits for the maintainer. |
| `ready` | maintainer | The plan is approved; the issue may be implemented. |
| `feature`, `bug`, `docs`, `chore` | template or by hand | Kind of change. |

Label changes do not notify anyone by themselves: after setting `plan` or
`ready`, say so in the chat with the implementer (for example "plan #18" or
"ready: #18, #19").

## Releases

Versions follow [semantic versioning](https://semver.org/). Before 1.0, the
minor version goes up for new features and breaking changes, the patch
version for fixes.

To release:

1. Check that CI on `main` is green, and run the tests listed for a release
   in the [test strategy](./#test-strategy) (full local run, the nightly UI
   test workflow by hand, the manual check list).
2. Set `MARKETING_VERSION` in the Xcode project to the new version (for
   example `0.2.0`) and raise `CURRENT_PROJECT_VERSION` by one, in a pull
   request labeled `chore`.
3. On GitHub: **Releases → Draft a new release → Choose a tag**, type the new
   version (for example `v0.2.0`) and create it on `main`.
4. Click **Generate release notes**. Pull requests are grouped by label
   (breaking changes, data model changes, features, fixes, documentation,
   dependencies, maintenance; see `.github/release.yml`). Add upgrade notes
   for `breaking` and `schema-change` entries.
5. Publish.

The macOS *About* window shows the version (`MARKETING_VERSION`) and build number.

To build a release instead of the latest `main`:

```sh
git fetch --tags
git checkout v0.2.0
open DocumentArchive.xcodeproj   # then Product → Archive
```
