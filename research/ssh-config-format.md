# ssh_config Format Specification — Research Notes

Research compiled from OpenSSH man pages and documentation.

## Line Parsing

- Lines are `keyword value` or `keyword=value` pairs
- Lines starting with `#` are comments
- Empty lines are ignored
- Keywords are **case-insensitive**; values are **case-sensitive**
- Double quotes (`"`) enclose values containing spaces
- Inside double quotes: `\"` for literal quote, `\\` for literal backslash
- Single quotes are NOT special (treated as literal characters)

## Host Sections

- Syntax: `Host <pattern> [<pattern2> ...]`
- Patterns are **whitespace-separated** (NOT comma-separated)
- Glob patterns: `*` (zero or more chars), `?` (exactly one char)
- Negation: `!pattern` — if ANY negated pattern matches, entire Host entry is ignored
- Negated match alone never produces a positive result
- Example: `Host * !staging` matches everything except "staging"

## Match Conditional Sections

- Syntax: `Match <criteria1> <value1> [<criteria2> <value2> ...]`
- All criteria must be true (AND logic)
- Criteria pattern values are **comma-separated** (unlike Host which is whitespace-separated)
- Available criteria: canonical, final, exec, localnetwork, host, originalhost, tagged, user, localuser
- `all` keyword: always matches (must appear alone or with canonical/final)
- Negation: prefix criteria with `!`

## First-Match-Wins Semantics

- For each directive, the first matching section's value wins
- More specific declarations go near the beginning, defaults at the end
- Processing order across files: command-line > user config > system config
- Within a file: top to bottom, first match per directive key

## Accumulating Directives

- Some directives collect values from ALL matching sections instead of first-match-wins
- In SSH: IdentityFile, CertificateFile, LocalForward, RemoteForward, SendEnv
- Each new declaration ADDS to the list
- Order matters — directives tried in order specified

## Include Directive

- Syntax: `Include <path> [<path2> ...]`
- Supports glob expansion (lexical/alphabetical order)
- Supports token expansion and tilde expansion
- Relative paths resolve to `~/.ssh/` (user config) or `/etc/ssh/` (system config)
- Can appear inside Host or Match blocks for conditional inclusion
- Included files parsed inline at point of Include

## Token Expansion

- Tokens use `%` prefix followed by single character
- Expanded at **runtime/query time**, not parse time
- `%%` always produces literal `%`
- Token availability varies by directive (some tokens only valid in certain directives)
- Common tokens: `%h` (hostname), `%u` (local user), `%r` (remote user), `%p` (port), `%n` (original hostname), `%d` (home dir), `%l` (local hostname)

## Boolean Values

- `yes` / `no` (case-insensitive)
- Some directives accept extended values: `ask`, `confirm`, `accept-new`, time intervals

## Type Coercion

- Strings: raw values (case-sensitive)
- Integers: numeric values
- Booleans: yes/no
- Paths: tilde-expanded (`~` → home directory)
- Enums: restricted set of valid values
- String lists: accumulated values
- String pairs: two values per line (e.g., `LocalForward 8080 remote:80`)

## Pattern Matching Details

From the PATTERNS section of the man page:
- A pattern consists of zero or more non-whitespace characters, `*`, or `?`
- A **pattern-list** is a comma-separated list of patterns (used in Match criteria)
- Patterns within pattern-lists may be negated with `!` prefix
- A negated match will never produce a positive result by itself

## Key Distinction

- **Host patterns**: whitespace-separated
- **Match criteria values**: comma-separated pattern-lists
- Both support glob matching and `!` negation
