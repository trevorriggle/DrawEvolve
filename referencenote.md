# Reference Note for Claude Code

## Git Workflow - CRITICAL

**ALWAYS push commits immediately after creating them.**

Do NOT let commits pile up locally. After every `git commit`, immediately run `git push`.

The user works across multiple environments (Codespaces for coding, Mac for building/testing). When commits aren't pushed automatically:
- The Mac build environment is out of sync
- The user has no visibility into what's been committed
- It creates confusion about the state of the project

## Standard workflow:
1. Make changes
2. `git add` relevant files
3. `git commit -m "message"`
4. `git push` ← **DO NOT SKIP THIS STEP**

No exceptions. Push every commit immediately.
