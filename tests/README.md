# Testing backup-restic

Tests use [bats-core](https://github.com/bats-core/bats-core) and run in both the devcontainer and CI.

## Running tests locally

In the devcontainer (bats is pre-installed):

```bash
bats tests/
```

Or run a specific test file:

```bash
bats tests/unit.bats
```

## Running tests outside devcontainer

Install bats:

```bash
# Ubuntu/Debian
sudo apt-get install -y bats

# macOS
brew install bats-core

# Or from source
git clone --depth 1 https://github.com/bats-core/bats-core.git
cd bats-core
sudo ./install.sh /usr/local
```

Then run:

```bash
bats tests/
```

## Test structure

- `test_helper.bash` - shared setup, mocks, helpers
- `unit.bats` - config resolution, command routing, basic validation
- `security.bats` - `validate_trusted_file`, permissions, ownership
- `hooks.bats` - hook execution order, environment variables
- `notify.bats` - notification lazy loading, filtering

## Adding new tests

1. Create a new `.bats` file in `tests/`
2. Start with:
   ```bash
   #!/usr/bin/env bats
   load test_helper
   ```
3. Use the helpers from `test_helper.bash`:
   - `create_job "name"` - creates a valid job config
   - `create_hook "name.sh" "body"` - creates an executable hook
   - `assert_called "pattern"` - checks mock call log
   - `skip_if_not_root` - skips root-only tests

## Running as root

Some tests require root (ownership checks). Run with:

```bash
sudo bats tests/
```

Or in a container:

```bash
docker run --rm -v "$PWD":/workspace -w /workspace --user root \
  mcr.microsoft.com/devcontainers/base:ubuntu \
  bash -c "apt-get update && apt-get install -y bats && bats tests/"
```
