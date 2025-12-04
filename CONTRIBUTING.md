# Contributing to Untrunc Video Repair Pipeline

Thank you for your interest in contributing! This document provides guidelines for contributing to this project.

## How to Contribute

### Reporting Bugs

1. Check existing issues to avoid duplicates
2. Use the bug report template
3. Include:
   - Operating system and version
   - Docker version
   - AWS region (if applicable)
   - Steps to reproduce
   - Expected vs actual behavior
   - Relevant log output

### Suggesting Features

1. Check existing issues for similar suggestions
2. Describe the use case and problem it solves
3. Provide examples if possible

### Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Run validation: `./validate.sh`
5. Commit with clear messages (`git commit -m 'Add amazing feature'`)
6. Push to your fork (`git push origin feature/amazing-feature`)
7. Open a Pull Request

## Development Setup

### Prerequisites

- Docker 20.10+
- Terraform 1.5+ (for AWS pipeline changes)
- Python 3.11+ (for edge service changes)
- Bash 4+ (for shell scripts)

### Local Testing

```bash
# Validate all code
./validate.sh

# Test edge service locally
cd edge-service
docker compose up --build

# Validate Terraform (without deploying)
cd batch-pipeline
terraform init -backend=false
terraform validate
```

## Code Style

### Python
- Follow PEP 8
- Use type hints
- Document functions with docstrings

### Shell Scripts
- Use `shellcheck` for linting
- Quote all variables
- Use `set -euo pipefail` at the top

### Terraform
- Use consistent formatting (`terraform fmt`)
- Add descriptions to all variables
- Use meaningful resource names

## Testing Checklist

Before submitting a PR, verify:

- [ ] `./validate.sh` passes
- [ ] Docker images build successfully
- [ ] No secrets or credentials committed
- [ ] README updated if needed
- [ ] New features documented

## Questions?

Open an issue with the "question" label.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
