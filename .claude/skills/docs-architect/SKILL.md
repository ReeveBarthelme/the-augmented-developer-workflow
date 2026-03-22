---
name: "docs-architect"
description: "Create architecture decision records (ADRs), maintenance guides, and system documentation; use when documenting decisions, creating guides, or updating docs"
---

# Documentation Architecture

This skill provides workflows for creating high-quality documentation including Architecture Decision Records (ADRs), maintenance guides, system documentation, and keeping documentation current with code changes.

## Documentation Philosophy

**"Future You" Will Thank You:**

- Write docs when context is fresh (not 6 months later)
- Document WHY, not just WHAT (code shows what)
- Use examples and real scenarios
- Keep docs close to code they describe

## Quick Reference

### Create Architecture Decision Record (ADR)

```bash
# Create ADR from template
# Fill in sections:
# - Context
# - Decision
# - Rationale
# - Consequences
# - Alternatives Considered
```

### Update Project Documentation

```bash
# Keep main documentation current
# Add to appropriate section:
# - Latest Status
# - Recent Fixes
# - Quick Reference Tables
# - Core Files Reference

# Follow existing format and style
```

## Architecture Decision Records (ADRs)

### What is an ADR?

**Purpose:** Document important architectural decisions with context, rationale, and trade-offs
**When to Create:** Major technical decisions that affect multiple components or have long-term impact

### ADR Structure

**Sections:**

1. **Title** - ADR-NNN: Brief decision description
2. **Status** - Proposed / Accepted / Deprecated / Superseded
3. **Context** - Problem and constraints
4. **Decision** - What was decided
5. **Rationale** - Why this decision over alternatives
6. **Consequences** - Impact (positive and negative)
7. **Alternatives Considered** - Other options and why not chosen
8. **Related Decisions** - Link to other ADRs

### Example ADR

```markdown
# ADR-001: Database Selection

## Status
Accepted

## Context
The application requires a relational database with support for JSON fields
and full-text search. Two options: PostgreSQL (self-managed) vs managed service.

## Decision
Use PostgreSQL with managed hosting. Use JSONB for flexible data storage.

## Rationale
- Lower operational cost with managed hosting
- JSONB provides schema flexibility without sacrificing query performance
- pgvector extension available for future embedding storage
- Strong ecosystem and community support

## Consequences
**Positive:**
- Reduced operational overhead
- Simpler codebase (single data store)

**Negative:**
- Vendor lock-in to managed service
- Less control over database internals

## Alternatives Considered
**MongoDB:**
- Pros: Native JSON, flexible schema
- Cons: Less mature transactions, separate search engine needed
- Decision: PostgreSQL JSONB provides equivalent flexibility with stronger consistency
```

## Documentation Standards

### File Naming

- **ADRs:** `ADR-NNN-short-title.md` (e.g., `ADR-001-database-selection.md`)
- **Guides:** `SYSTEM_NAME_GUIDE.md` (e.g., `AUTH_SYSTEM_GUIDE.md`)
- **Specs:** `FEATURE_SPECIFICATION.md` (e.g., `SEARCH_SPECIFICATION.md`)

### Markdown Style

```markdown
# H1 - Document Title (one per doc)

## H2 - Major Sections

### H3 - Subsections

**Bold** - Emphasis, labels
`code` - Inline code, commands, filenames
```

### Code Examples

```markdown
# Good: Show context and explanation
```bash
# Update all vectors (takes ~10 minutes for large datasets)
python3 scripts/generate_vectors.py --batch-size 10

# Expected output:
# Processing batch 1/136...
# Generated 1357 vectors
```

**Bad:** Just the command without context
```

### Decision Documentation

```markdown
# Always document:
- **Why** a decision was made (most important)
- **When** it was made (date context)
- **Who** made it (if relevant)
- **What** alternatives were considered
- **What** the trade-offs are
```

## Updating Documentation

### When Code Changes

1. **Check affected docs** - Grep for file/function names
2. **Update inline comments** - Keep code self-documenting
3. **Update project docs** - If behavior changes
4. **Update ADR** - If decision rationale changes
5. **Update guides** - If procedures change

## Documentation Types

### 1. ADRs (Architecture Decision Records)

- **Location:** `docs/architecture/`
- **Purpose:** Record major technical decisions
- **Audience:** Engineers, architects, future team members
- **Format:** Structured markdown (see template)

### 2. Maintenance Guides

- **Location:** Root directory or `docs/`
- **Purpose:** Operational runbooks
- **Audience:** Maintainers, on-call engineers
- **Format:** How-to with troubleshooting

### 3. System Specifications

- **Location:** Root directory or `docs/`
- **Purpose:** Detailed feature/system documentation
- **Audience:** Developers implementing or modifying features
- **Format:** Technical specs with examples

### 4. API Documentation

- **Location:** Inline (docstrings) + `docs/api/`
- **Purpose:** How to use functions, classes, modules
- **Audience:** Developers using the code
- **Format:** Docstrings + generated docs

### 5. README Files

- **Location:** Root (`README.md`) and subdirectories
- **Purpose:** Quick start and overview
- **Audience:** New developers, external users
- **Format:** Concise, link-heavy

## Documentation Quality Checklist

### Before Merging

- [ ] Updated project docs if behavior changed
- [ ] Added/updated docstrings for new/modified functions
- [ ] Created ADR for architectural decisions
- [ ] Updated maintenance guides for operational changes
- [ ] Added examples for complex features
- [ ] Checked links work (no broken references)
- [ ] Code examples tested (copy-paste and run)

### Documentation Review

- [ ] Clear and concise (no unnecessary jargon)
- [ ] Correct and accurate (matches actual behavior)
- [ ] Complete (no critical gaps)
- [ ] Consistent (follows style guide)
- [ ] Current (no outdated information)

## Resources

- Markdown Guide: <https://www.markdownguide.org/>
