# Contributing to WordPress Rclone Migrations

Thank you for your interest in contributing to this project! We welcome contributions that help improve the script while maintaining its core principles of being fast, secure, and reliable.

## Development Guidelines

### Versioning
This project follows [Semantic Versioning (SemVer)](https://semver.org/):
- **MAJOR** version for incompatible API changes
- **MINOR** version for backwards-compatible functionality additions
- **PATCH** version for backwards-compatible bug fixes

### Commit Messages
We use [Conventional Commits](https://www.conventionalcommits.org/) for clear and consistent commit messages:

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

#### Types
- `feat`: New features
- `fix`: Bug fixes
- `docs`: Documentation changes
- `refactor`: Code refactoring without feature changes
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

#### Examples
```
feat: add backup functionality with timestamped directories
fix: resolve localhost MySQL connection issue
docs: update README with backup instructions
refactor: simplify database credential extraction
```

## Core Principles

Please maintain these principles in any contributions:
- **Fast**: Incremental sync, parallel transfers
- **Secure**: SSH keys, encrypted connections, secure credential storage
- **Reliable**: Connection testing, atomic operations, error handling

## Getting Started

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/your-feature`
3. Make your changes following the guidelines above
4. Test your changes thoroughly
5. Commit using conventional commits
6. Submit a pull request

## Testing

Before submitting:
- Test with different WordPress setups (standard, WordOps, Bedrock)
- Verify both SSH key and password authentication work
- Test dry-run mode functionality
- Ensure error handling works correctly

Thank you for contributing!