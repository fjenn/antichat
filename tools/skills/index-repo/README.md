# AntiChat skills index

This repository holds one file that the AntiChat app reads: `skills-index.json`, the list of skills you can add
in **Settings > Skills**. The app downloads this file (at most once a day) so the list stays up to date without
an app update. Nothing about you or your Mac is sent when it does.

## What is in here

| File | What it is |
|---|---|
| `skills-index.json` | The list: for every skill its title, a one-line summary, its category, who wrote it, its licence, where its files are, and the size and SHA-256 hash of every file. |
| `build-index.py` | The generator. It reads the source repositories and writes `skills-index.json`. |
| `refresh.py` | Runs the generator, checks the result, and refuses to write anything it cannot vouch for. |
| `overrides.json` | The decisions made by a person: which skills are listed, their titles, summaries and categories, and which skills were looked at and left out. |
| `NOTICE.md` | Where the skills come from and under which licences. |
| `.github/workflows/refresh.yml` | Runs `refresh.py` every Monday and commits the new list when it is valid. |

This repository does not contain the skills themselves. Every skill stays in its author's repository:

- [anthropics/knowledge-work-plugins](https://github.com/anthropics/knowledge-work-plugins) (Apache-2.0)
- [anthropics/skills](https://github.com/anthropics/skills) (Apache-2.0, per skill)
- [alirezarezvani/claude-skills](https://github.com/alirezarezvani/claude-skills) (MIT)

When you add a skill, the app downloads that skill's files from its author's repository at one exact commit,
checks every file against the size and hash in the list, and shows you the whole skill before anything is
installed.

## How the list is kept up to date

Every week, with no person involved:

1. The generator looks at the newest version of each source repository.
2. A skill that is already on the list moves to its newest version.
3. A skill that is new upstream is added only if it passes the automatic checks: no shell scripts, no bundled
   code that opens network connections or starts programs, within the size limits, valid `SKILL.md`, no text
   that matches an unsafe pattern, not an engineering skill. It gets a title and summary derived from its own
   description. The run's summary lists it so a person can review it later.
4. A skill that now fails a check is dropped from the list. The run's summary says which and why.
5. Every file of every skill is downloaded once and compared with its size and hash.
6. The new list is committed only if all of this worked. If the generator fails, if a file cannot be confirmed,
   if a skill breaks the app's rules, or if the list lost more than 10% of its skills, nothing changes.

You can read each run's summary under **Actions > refresh**.

## Run it yourself

Python 3 is all you need (standard library only).

```sh
python3 -I refresh.py --work /tmp/skills-refresh            # dry run: generate and check, change nothing
python3 -I refresh.py --work /tmp/skills-refresh --apply    # write skills-index.json when it is valid
python3 -I refresh.py validate --files                      # check the committed list, files included
```

## Licence

The tooling in this repository (`build-index.py`, `refresh.py`, the workflow) is under the MIT licence, see
`LICENSE`. The skills are not: each skill keeps its own licence, recorded per skill in `skills-index.json` and
explained in `NOTICE.md`. The authors of the skills do not endorse AntiChat.

The source of these files is the AntiChat repository (`tools/skills/`); changes are made there and copied here.
