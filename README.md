# WPA Investigation Workshop

## Goal

This workshop teaches users and maintainers of the WatermarkPodAutoscaler (WPA) controller how to investigate common issues when using a WPA resource to horizontally scale an application.

It focuses on WPA configurations that use Datadog as the metrics provider — either through a `DatadogMetric` CRD or by referencing Datadog metrics directly in the WPA's external metrics configuration.

Most issues covered here also apply to HPA when Datadog is used as the external metrics provider in a Kubernetes cluster.

## What you need

| | |
|---|---|
| CLIs | `kind`, `kubectl`, `helm`, `git`, `docker` |
| Datadog | an API key **and** an APP key, plus access to the org that owns them |
| Docker | around 6 GB of memory available to the daemon |

The APP key is not optional: the external metrics server uses it to query Datadog, and without it every
query is rejected and all the cases fail for the same uninteresting reason.

## Getting started

```bash
export DD_API_KEY=...
export DD_APP_KEY=...
export DD_SITE=datadoghq.com     # datadoghq.eu, us3/us5/ap1.datadoghq.com, ...
export WORKSHOP_NAME=your-name   # optional, defaults to $(whoami)

./setup.sh
```

`setup.sh` creates a single-node kind cluster called `wpa-workshop-$WORKSHOP_NAME`, installs the WPA
controller, the Datadog Operator, and an Agent with the external metrics server enabled, then deploys
every investigation case. It refuses to finish unless `external.metrics.k8s.io` is genuinely serving,
because a broken APIService makes every case look broken for the wrong reason.

Then work through the cases:

```bash
./case.sh list          # every case and where it stands
./case.sh show 01       # the end-user report
./case.sh verify 01     # did you fix it?
./case.sh reset 01      # start over
```

Give any change **about two minutes** before deciding it didn't work. Datadog ingestion, the Cluster
Agent's 30-second external-metrics refresh and the WPA controller's own poll interval all stack up.

## How the cases work

Each case is a namespace containing a deliberately broken WPA and a workload for it to scale. You get
the symptoms the end user reported — never the root cause; working that out from partial information is
the whole exercise.

`cases-tmpl/` holds the templates. `setup.sh` renders them into `workspace/case-NN/`, which is what you
edit (and what is gitignored, so pulling new cases can never clash with a half-finished investigation).
You can also just `kubectl edit` the live objects.

`setup.sh` also writes `workspace/README.md`: the list of cases with their titles and namespaces, and
how to work through them. Start there once the cluster is up.

`.solutions/` explains every case. The leading dot only keeps it out of a casual `ls`; it is plain text
on the honour system, and reading it early is the one way to get nothing out of this.

## Maintaining a workshop

```bash
./update.sh              # pull new cases and component versions, keep the cluster
./update.sh --reset-cases  # ...and restore every case to its original broken state
./delete.sh              # remove the cluster and this participant's Datadog objects
```

`update.sh` leaves cases you have already edited alone by default. `delete.sh` prints exactly what it
will remove and asks before doing it; it is scoped by `workshop_name`, so it will not touch a
colleague's objects in a shared org. Note that metrics already submitted cannot be deleted — and that
`wpa_workshop.app.load` is a custom metric, so a forgotten cluster keeps costing you.

## Writing a new case

A case is just a directory: `all_case_ids()` globs `cases-tmpl/case-*/`, so creating
`cases-tmpl/case-03/` is what registers it. What it has to contain, and the invariants that are easy
to get wrong — `algorithm: average`, the watermark arithmetic, which `__TOKEN__`s exist, how not to
spoil the case in its own filename — are written up as a Claude Code skill in
[.claude/skills/new-case/SKILL.md](.claude/skills/new-case/SKILL.md).

### Using it with Claude Code

The skill is committed with the repo, so there is nothing to install: Claude Code discovers
`.claude/skills/*/SKILL.md` in the project you have open. Clone the repo, start `claude` from its
root, and:

```
/new-case
```

or just ask for a new case in your own words — the `description:` in the skill's frontmatter is what
Claude matches against, so "add a case about a WPA stuck in dry-run" reaches it too. `/help` lists it
among the available skills; if it is missing, you started Claude Code somewhere other than the
repository root.

To have it available in every project rather than this one, copy the directory into your personal
skills folder:

```bash
cp -r .claude/skills/new-case ~/.claude/skills/
```

### Using it with another agent

`SKILL.md` is Markdown with a small YAML frontmatter block (`name`, `description`) and no
Claude-Code-specific syntax in the body. Any agent that takes instructions from a file can use it —
point yours at the path, or paste the body in as context before asking for a case. The frontmatter is
metadata for skill discovery; it is safe to drop when pasting.

## Running it as a group

Set a different `WORKSHOP_NAME` per participant. It becomes the cluster name and therefore the
`kube_cluster_name` tag on every metric, which is how one dashboard can show everyone's progress side by
side.

## Repository layout

| Path | |
|---|---|
| [setup.sh](setup.sh), [update.sh](update.sh), [delete.sh](delete.sh), [case.sh](case.sh) | the workshop lifecycle |
| [lib/common.sh](lib/common.sh) | shared shell helpers, pinned versions |
| [kind/](kind/), [manifests/](manifests/) | cluster and Datadog Agent configuration |
| [cases-tmpl/](cases-tmpl/) | investigation case templates, rendered into `workspace/` |
| [.solutions/](.solutions/) | spoilers, hidden behind a leading dot |
| [.claude/skills/new-case/](.claude/skills/new-case/) | how to author a new case, as a Claude Code skill |
| [workshop-plan.md](workshop-plan.md) | requirements and the case list |
