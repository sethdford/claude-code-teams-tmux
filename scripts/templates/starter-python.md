# {{PROJECT_NAME}} — Python Starter Guide

This guide documents conventions and setup procedures for {{PROJECT_NAME}}, a Python project.

## Project Overview

{{PROJECT_NAME}} is a **Python {{PYTHON_VERSION}}** project{{FRAMEWORK:+ using {{FRAMEWORK}}}}.

**Quick Links:**
- Test command: `{{TEST_CMD}}`
- Build command: `{{BUILD_CMD}}`
- Package manager: `{{PACKAGE_MANAGER}}`

## Project Structure

```
{{PROJECT_NAME}}/
├── {{PROJECT_NAME}}/          # Main package
│   ├── __init__.py             # Package marker
│   ├── main.py                 # Entry point
│   ├── {{FRAMEWORK}}/          # Framework-specific modules
│   │   ├── routes.py           # API routes
│   │   ├── models.py           # Data models
│   │   └── schemas.py          # Validation schemas
│   └── utils/                  # Shared utilities
├── tests/                      # Test files (mirror main structure)
├── docs/                       # Documentation
├── pyproject.toml              # Project manifest (modern)
├── setup.py                    # Setup script (legacy)
├── requirements.txt            # Pinned dependencies
├── requirements-dev.txt        # Development dependencies
└── Makefile                    # Build targets
```

## Build & Test

### Virtual Environment Setup
```bash
python -m venv venv
source venv/bin/activate  # Linux/macOS
# or
venv\Scripts\activate  # Windows
```

### Installation
```bash
{{PACKAGE_MANAGER}} install -r requirements.txt
{{PACKAGE_MANAGER}} install -r requirements-dev.txt
```

### Running Tests
```bash
{{TEST_CMD}}
```

### Type Checking
```bash
mypy {{PROJECT_NAME}}
```

### Running Application
```bash
{{DEV_CMD}}
```

## Code Conventions

### Naming Conventions
- **Classes**: PascalCase (e.g., `UserService`, `DataValidator`)
- **Functions/Methods**: snake_case (e.g., `get_user`, `validate_input`)
- **Constants**: UPPER_SNAKE_CASE (e.g., `MAX_RETRIES`, `DEFAULT_TIMEOUT`)
- **Private methods**: prefix with `_` (e.g., `_internal_method`)
- **Modules**: lowercase with underscores (e.g., `user_service.py`)

### Type Hints
- **Required for all public functions**: `def get_user(user_id: int) -> User:`
- Use `Optional[T]` for nullable types
- Use `List[T]`, `Dict[K, V]` for collections (or use 3.10+ syntax: `list[T]`, `dict[K, V]`)
- Document complex types in docstrings

### Docstrings
- Format: Google style or NumPy style (be consistent)
- Include: summary, parameters, return value, exceptions
- Example:
  ```python
  def get_user(user_id: int) -> User:
      """Fetch a user by ID.
      
      Args:
          user_id: The user's ID.
          
      Returns:
          User object if found.
          
      Raises:
          UserNotFound: If user doesn't exist.
      """
  ```

### Testing Requirements
- Test files: `tests/test_*.py` or `*_test.py`
- **Minimum 80% coverage** for new code
- Use `pytest` with fixtures for setup/teardown
- Mock external dependencies (APIs, databases)

### Code Style
- Follow **PEP 8** (use `black` for auto-formatting)
- Use `isort` to organize imports
- Use `flake8` or `ruff` for linting
- Lines ≤ 100 characters

## Common Tasks

### Add a New Endpoint (FastAPI/Flask)
```python
# In routes.py or app.py
@app.post("/users")
def create_user(user: UserSchema) -> User:
    """Create a new user."""
    # Validate & persist
    return user_service.create(user)
```

### Add a Test
```python
# In tests/test_user_service.py
def test_get_user_returns_user(user_service):
    """Test that get_user returns the correct user."""
    user = user_service.get_user(1)
    assert user.id == 1
    assert user.name == "Expected Name"
```

### Update Dependencies
```bash
{{PACKAGE_MANAGER}} install --upgrade -r requirements.txt
```

### Database Migration (SQLAlchemy)
```bash
alembic revision --autogenerate -m "Add user table"
alembic upgrade head
```

### Run Linting & Formatting
```bash
black {{PROJECT_NAME}} tests
isort {{PROJECT_NAME}} tests
flake8 {{PROJECT_NAME}} tests
mypy {{PROJECT_NAME}}
```

## Troubleshooting

### "ModuleNotFoundError" on import
- Ensure virtual environment is activated
- Check `PYTHONPATH` includes project root: `export PYTHONPATH=$(pwd)`
- Verify package structure has `__init__.py` files

### Version conflicts or dependency resolution failures
- Clear cache: `{{PACKAGE_MANAGER}} cache purge`
- Recreate environment: `rm -rf venv && python -m venv venv`
- Check `requirements.txt` for conflicting versions

### Tests fail due to missing database
- Use pytest fixtures with in-memory SQLite: `sqlite:///:memory:`
- Or use `pytest-postgresql` for real PostgreSQL
- Check `conftest.py` for setup/teardown

### Performance issues with large datasets
- Profile with `cProfile`: `python -m cProfile -s cumtime app.py`
- Use generators instead of lists for large iterables
- Check for N+1 query problems (use `select_related`/`prefetch_related`)

## Next Steps

1. **Activate venv**: `source venv/bin/activate`
2. **Install deps**: `{{PACKAGE_MANAGER}} install -r requirements.txt`
3. **Run tests**: `{{TEST_CMD}}` should pass
4. **Read ARCHITECTURE.md** for system design
5. **Check CODING-STANDARDS.md** for detailed conventions
6. **Follow DEFINITION-OF-DONE.md** when submitting PRs
