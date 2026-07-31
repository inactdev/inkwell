# Inkwell

Inkwell is a new project, currently at its first commit with no application code yet.
The scope will be recorded here as soon as it is decided.

## Working in this repo

- The repository is local only for now. There is no remote and nothing is pushed anywhere.
- Every contributor works in their own isolated git worktree; nobody develops directly in the primary checkout.
- Runtime state is never shared between worktrees. If Inkwell grows a database or any other stateful service, each worktree runs its own private instance with its own data, its own generated names, and its own automatically allocated ports.
