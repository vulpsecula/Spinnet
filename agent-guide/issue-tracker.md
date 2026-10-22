# Issue workflow

Issues and specs live in GitHub Issues. Infer the repository from the checkout's
Git remote; `gh` does this inside the clone. Issue changes follow the user's
requested scope. Reading or triaging an issue does not itself authorize publishing
a new issue, comment or pull request.

## Read and query

- Read an issue with `gh issue view <number> --comments`; include its labels and
  current assignee when deciding whether work is available.
- A bare `#42` may identify an issue or PR. Resolve its type before treating it
  as a ticket; use `gh pr view 42` and `gh pr diff 42` for a PR.
- `gh issue list` and `gh pr list` default to 30 results. Use an explicit limit
  for a bounded query and pagination for an exhaustive inventory.

For all open issues, the REST issues endpoint also returns PRs, so filter them:

```sh
gh api --paginate 'repos/{owner}/{repo}/issues?state=open&per_page=100' \
  --jq '.[] | select(.pull_request == null) | {number, title, body, labels: [.labels[].name], assignees: [.assignees[].login]}'
```

Read a selected issue's complete comment history with:

```sh
gh api --paginate 'repos/{owner}/{repo}/issues/<number>/comments?per_page=100' \
  --jq '.[] | {author: .user.login, body}'
```

## Write within the requested scope

For multiline text, write the exact Markdown to a file and use `--body-file`:

```sh
gh issue create --title 'Title' --body-file /path/to/body.md
gh issue comment <number> --body-file /path/to/comment.md
```

Use `gh issue edit` for labels or assignees, and `gh issue close` to resolve an
issue after its requested result is complete. Use the canonical triage labels
listed in [AGENTS.md](../AGENTS.md#triage-labels).
When a workflow says “publish to the issue tracker”, the destination is a GitHub
issue; “fetch the ticket” means read its body, comments and current state.

## PR triage

**PRs as a request surface: no.** Feature requests are issues. Review or update a
PR when requested. If external-PR triage is explicitly needed, use the REST
`author_association` field; `gh pr list --json` does not expose `authorAssociation`:

```sh
gh api --paginate 'repos/{owner}/{repo}/pulls?state=open&per_page=100' \
  --jq '.[] | select(.author_association == "CONTRIBUTOR" or .author_association == "FIRST_TIME_CONTRIBUTOR" or .author_association == "FIRST_TIMER" or .author_association == "NONE") | {number, title, author: .user.login, author_association}'
```

## Existing task maps

Use this section only for an existing map or a user-requested map workflow.
Ordinary work needs no Wayfinder labels or new map.

- A map is an issue whose child issues are tickets. Prefer GitHub sub-issues;
  when unavailable, use a task list and `Part of #<map>` in each child.
- GitHub native issue dependencies are the canonical blocking links. The
  `dependencies/blocked_by` API takes the blocker's database `issue_id`, obtained
  from `gh api repos/{owner}/{repo}/issues/<number> --jq .id`; it is neither the
  displayed issue number nor a GraphQL node ID. If native dependencies are
  unavailable, use an explicit `Blocked by: #<n>` line and read each blocker's state.
- Fetch every page of the map's sub-issues (`gh api --paginate
  'repos/{owner}/{repo}/issues/<map>/sub_issues?per_page=100'`), including nested
  maps when relevant. Open, unassigned children with no open blockers form the
  available work; use map order when choosing among them.
- Existing `wayfinder:<type>` labels describe that map's workflow. Keep them when
  updating its tickets; they are not required for unrelated issues.
