---
name: "testing-strategy"
description: "Enforces TDD principles and testing standards across all modules; use when writing tests, working on TDD, unit tests, integration tests, or test coverage"
---

You are enforcing TDD principles and testing standards across all modules.

## Core Principle

**TESTS BEFORE CODE**. Every feature starts with a failing test.

## When This Skill Activates

- Working on test files
- Any file that should have corresponding tests
- When writing new features or fixing bugs

## Testing Pyramid

```
         E2E (5%)
      ─────────────
    Integration (20%)
   ─────────────────────
  Unit Tests (75%)
─────────────────────────────
```

### Unit Tests (75% of tests)

**Target**: 90%+ coverage, fast execution (<1s)

```python
# tests/unit/test_service.py
def test_create_item_assigns_pending_status():
    """New items get 'pending' status by default."""
    item = Service().create({
        'name': 'Test Item',
        'owner_id': 'owner-123'
    })

    assert item['status'] == 'pending'
    assert item['owner_id'] == 'owner-123'
```

### Integration Tests (20% of tests)

**Target**: 80%+ coverage, moderate speed (<10s)

```python
# tests/integration/test_workflow.py
def test_approve_item_updates_status_and_creates_record():
    """Approval workflow updates item and creates audit trail."""
    item_id = create_test_item(status='pending')

    result = Service().approve(item_id, approver_id='admin-123')

    item = db.get_item(item_id)
    assert item['status'] == 'approved'
    assert item['approved_by'] == 'admin-123'

    record = db.get_approval(item_id)
    assert record['approved_by'] == 'admin-123'
    assert record['approved_at'] is not None
```

### E2E Tests (5% of tests)

**Target**: Critical paths only, slower execution (<60s)

```python
# tests/e2e/test_full_workflow.py
def test_user_can_create_approve_and_view():
    """Complete user journey from creation to publication."""
    # 1. User creates item
    result = create_item('test_data', user='user@example.com')
    assert result['status'] == 'success'

    # 2. Item is pending
    item = get_item(result['id'])
    assert item['status'] == 'pending'

    # 3. User approves
    approve_result = approve_item(result['id'], user='user@example.com')
    assert approve_result['status'] == 'approved'
```

## Coverage Requirements

### Shared Libraries: 100% Coverage (ENFORCED)

```bash
# Customize: your shared library coverage command
pytest tests/ \
  --cov=shared_lib \
  --cov-fail-under=100 \
  || exit 1
```

### Application Code: 90% Coverage (TARGET)

```bash
pytest tests/ \
  --cov=src \
  --cov-fail-under=90
```

## Test Organization

```
tests/
├── unit/                   # Pure function tests, no DB
│   ├── test_service.py
│   ├── test_operations.py
│   └── test_validation.py
├── integration/            # Database + API tests
│   ├── test_workflow.py
│   ├── test_api.py
│   └── test_pipeline.py
├── e2e/                    # Full user flows
│   └── test_full_workflow.py
└── fixtures/               # Shared test data
    ├── test_data.json
    └── mocks/
```

## TDD Red-Green-Refactor Cycle

1. **Red**: Write failing test
2. **Green**: Write minimum code to pass
3. **Refactor**: Clean up code while keeping tests green

**Never skip Red step** - if test passes immediately, it's not testing new behavior.

---
*Skill Version: 1.0*
