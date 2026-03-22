---
name: "modular-architecture"
description: "Maintains modular file structure under 700 lines for AI-friendly context; use when files are large, need refactoring, or splitting code"
---

You are maintaining modular file structure for continuous AI integration.

## Core Principle

**FILES <= 700 LINES FOR AI-FRIENDLY CONTEXT**. Prevent monolithic files that hurt AI performance.

## When This Skill Activates

- Any file approaching 500+ lines
- When refactoring or splitting code
- During code review when file size is flagged

## File Size Targets

| File Type | Target | Maximum | Action if Exceeded |
|-----------|--------|---------|-------------------|
| Documentation | <500 lines | 700 lines | Split into sub-modules |
| Python modules | <400 lines | 600 lines | Extract classes/functions |
| React components | <300 lines | 500 lines | Split into sub-components |
| Test files | <400 lines | 600 lines | Group by feature |

## When to Split a File

### Trigger: File >700 lines

**Action**: Split into sub-files:

```
module/
├── README.md (overview + links)
├── core.md (300 lines)
├── service.md (350 lines)
├── api.md (250 lines)
└── testing.md (177 lines)
```

### Trigger: File >600 lines (Python/TypeScript)

**Action**: Extract into modules:

```python
# module/services/
├── __init__.py (exports)
├── core.py (base class, 200 lines)
├── operations.py (business logic, 150 lines)
├── queries.py (data access, 180 lines)
└── validation.py (validation rules, 120 lines)
```

## Anti-Patterns to Reject

### Monolithic God Files

```
backend.py (2,400 lines)  # REJECT: Split into modules
```

### Circular Dependencies

```python
# product_service.py imports revision_service.py
# revision_service.py imports product_service.py
# REJECT: Refactor to remove cycle
```

### Deep Nesting (>3 levels)

```
src/modules/feature/services/handlers/validators/custom/
# REJECT: Too deep, flatten to 2-3 levels max
```

## Modular Structure Pattern

```
module/
├── README.md (index, <200 lines)
├── core.py (main logic, <400 lines)
├── helpers.py (utilities, <300 lines)
├── types.py (type definitions, <200 lines)
└── tests/
    ├── test_core.py (<400 lines)
    └── test_helpers.py (<300 lines)
```

## Verification Commands

```bash
# Find files >700 lines (customize paths for your project)
find src -name "*.md" -exec wc -l {} \; | awk '$1 > 700'

# Find Python files >600 lines
find src -name "*.py" -exec wc -l {} \; | awk '$1 > 600'

# Find React/TS files >500 lines
find src -name "*.tsx" -exec wc -l {} \; | awk '$1 > 500'
```

## Refactoring Checklist

When splitting a file:

- [ ] Create new directory structure
- [ ] Move code to appropriate modules
- [ ] Update imports in dependent files
- [ ] Update documentation cross-references
- [ ] Run tests (verify nothing broke)
- [ ] Update README with new structure

---
*Skill Version: 1.0*
