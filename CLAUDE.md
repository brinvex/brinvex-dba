# Brinvex Database Admin - Claude Instructions

## Git

- Commit directly to `main`. Do not create a feature branch first.
- Commit only when asked.
- **Never suggest pushing**, and do not comment on push state (ahead of origin, force push
  needed or not). The user pushes on their own.
- Check `git status` before staging — the working tree often holds the user's own
  uncommitted work, and `git add -A` will sweep it into your commit.
- **No `Co-Authored-By` trailer.** Commit messages carry no co-author line; this is
  the user's repository and their authorship.
- **Keep messages short.** A subject line, plus a few lines of body only where the
  reasoning would not be obvious from the diff.