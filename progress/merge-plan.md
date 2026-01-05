# Merge Plan

Generated: 2026-01-05T23:16:32+00:00

## Project: Todo API

## Merge Order

Features should be merged in this order to respect dependencies:

### 1. todo-001

  Feature: todo-001
    Name: Express server setup with health endpoint
    Branch: feature/todo-001
    PR: claude-direct
    Dependencies: none

### 2. todo-002

  Feature: todo-002
    Name: In-memory todo storage
    Branch: feature/todo-002
    PR: claude-direct
    Dependencies: none

### 3. todo-003

  Feature: todo-003
    Name: GET /api/todos endpoint
    Branch: feature/todo-003
    PR: claude-direct
    Dependencies: todo-001, todo-002

### 4. todo-004

  Feature: todo-004
    Name: POST /api/todos endpoint
    Branch: feature/todo-004
    PR: claude-direct
    Dependencies: todo-001, todo-002

### 5. todo-005

  Feature: todo-005
    Name: PUT /api/todos/:id endpoint
    Branch: feature/todo-005
    PR: claude-direct
    Dependencies: todo-003, todo-004

### 6. todo-006

  Feature: todo-006
    Name: DELETE /api/todos/:id endpoint
    Branch: feature/todo-006
    PR: claude-direct
    Dependencies: todo-003, todo-004

## Merge Commands

Execute these commands in order:

```bash
# todo-001
gh pr merge claude-direct --merge --delete-branch

# todo-002
gh pr merge claude-direct --merge --delete-branch

# todo-003
gh pr merge claude-direct --merge --delete-branch

# todo-004
gh pr merge claude-direct --merge --delete-branch

# todo-005
gh pr merge claude-direct --merge --delete-branch

# todo-006
gh pr merge claude-direct --merge --delete-branch

```

## Notes

- Review each PR before merging
- Wait for CI to pass after each merge
- If conflicts occur, resolve and re-run CI
