# Shell Autocompletion for `ib`

## Overview

Add tab completion for `ib` commands and agent names in bash and zsh shells.

## Complexity Assessment: Low to Medium

| Aspect | Difficulty | Notes |
|--------|------------|-------|
| Command name completion | Easy | Static list: `new-agent`, `list`, `look`, `send`, etc. |
| Agent name completion | Easy | Dynamic: query `.ittybitty/agents/*/` directories |
| Option completion | Medium | Each command has different flags (`--force`, `--worker`, etc.) |
| Bash support | Easy | Standard `COMPREPLY` + `compgen` |
| Zsh support | Easy | Zsh can use bash completion scripts OR native `_arguments` |

---

## Bash Completion Fundamentals

### How It Works

Bash completion uses the `complete` builtin command to define which suggestions appear for a given executable when the user presses Tab.

### Key Components

1. **COMPREPLY**: An array variable that holds all completion suggestions to present to users
2. **compgen**: A builtin that generates completion suggestions and filters them based on what's typed
3. **COMP_WORDS**: Array of words in the current command line
4. **COMP_CWORD**: Index into COMP_WORDS of the word being completed

### compgen Options

| Option | Purpose |
|--------|---------|
| `-W "wordlist"` | Generate completions from a word list |
| `-d` | Complete directory names |
| `-f` | Complete file names |
| `-c` | Complete command names |
| `-A function` | Complete function names |

Example: `compgen -W "now tomorrow never" n` returns only suggestions beginning with "n".

### Installation Locations (Bash)

- **System-wide**: `/etc/bash_completion.d/` - automatically loaded when bash starts
- **Per-user**: Source from `~/.bashrc`:
  ```bash
  source /path/to/completion-script.bash
  ```
- **Dynamic**: Use `eval` to load on shell startup:
  ```bash
  eval "$(ib completions bash)"
  ```

### Basic Template

```bash
_ib_completions() {
    local cur prev words cword
    _init_completion || return

    # cur = current word being completed
    # prev = previous word
    # cword = index of current word

    case $cword in
        1)
            # First argument: complete command names
            COMPREPLY=($(compgen -W "list look send ..." -- "$cur"))
            ;;
        2)
            # Second argument: depends on command
            case $prev in
                look|send|kill)
                    # Complete agent IDs
                    ;;
            esac
            ;;
    esac
}

complete -F _ib_completions ib
```

---

## Zsh Completion Fundamentals

### How It Works

Zsh has two completion systems:
1. **compctl** (old) - simpler but limited
2. **compsys** (new) - powerful, uses `_arguments`, `compdef`, etc.

### Key Components

1. **#compdef**: Declaration line at top of completion file
2. **compdef**: Function to associate completion functions with commands
3. **_arguments**: High-level wrapper for option/argument completion
4. **compadd**: Low-level builtin for adding completions

### The `_arguments` Function

Called "the syntax from hell" but powerful. Basic format:

```zsh
_arguments \
    '-f[input file]:filename:_files' \
    '-v[verbose mode]' \
    '1:first arg:_net_interfaces' \
    '*:remaining args:_files'
```

Format: `'OPTSPEC[DESCRIPTION]:MESSAGE:ACTION'`

### Installation Locations (Zsh)

Completion files go in directories listed in `$fpath`. Add a directory:

```zsh
fpath=(~/my-completions $fpath)
```

Common locations:
- `/usr/share/zsh/site-functions/`
- `/opt/homebrew/share/zsh/site-functions/` (macOS with Homebrew)
- `~/.zsh/completions/` (user-specific)

### Zsh Can Use Bash Completions

Zsh includes `bashcompinit` to run bash completion scripts:

```zsh
autoload -U +X bashcompinit && bashcompinit
source /path/to/bash-completion-script.bash
```

This means we can write ONE bash script and use it in both shells.

---

## Recommended Approach: Self-Installing Completion

Add a `ib completions` command that outputs the completion script:

```bash
# Option 1: Append to rc file
ib completions bash >> ~/.bashrc
ib completions zsh >> ~/.zshrc

# Option 2: Dynamic loading (recommended)
# In .bashrc:
eval "$(ib completions bash)"

# In .zshrc:
eval "$(ib completions zsh)"
```

**Pros**:
- User adds one line to their shell rc file
- Completions stay in sync with `ib` as it updates
- No separate files to manage
- No external dependencies

## Alternative: Bundled Completion Files

Ship `ib.bash` and `_ib` (zsh) files that users can install:
- Bash: Copy to `/etc/bash_completion.d/` or source from `.bashrc`
- Zsh: Copy to a directory in `$fpath`

---

## Bash vs Zsh: Single Implementation Strategy

**Good news**: We don't need two separate implementations.

### Option 1: Bash + bashcompinit (Recommended)

Write one bash completion script. For zsh users:

```zsh
autoload -U +X bashcompinit && bashcompinit
eval "$(ib completions bash)"
```

**Pros**: Single codebase, 80% of the benefit
**Cons**: Slightly less fancy than native zsh

### Option 2: Native Zsh Completion

Use `_arguments` for rich zsh experience (descriptions in menus, etc.).

```zsh
#compdef ib

_ib() {
    local -a commands
    commands=(
        'new-agent:Start a new agent with a prompt'
        'list:Show all agents and their state'
        'look:View an agents recent output'
        # ...
    )

    _arguments \
        '1:command:->command' \
        '*::arg:->args'

    case $state in
        command)
            _describe 'command' commands
            ;;
        args)
            case $words[1] in
                look|send|kill|merge)
                    _ib_agents
                    ;;
            esac
            ;;
    esac
}

_ib_agents() {
    local agents
    agents=(${(f)"$(ls -1 .ittybitty/agents/ 2>/dev/null)"})
    _describe 'agent' agents
}

_ib
```

**Pros**: Richer UI, descriptions in completion menu
**Cons**: More code to maintain

### Recommendation

Start with bash + bashcompinit. Add native zsh later if users request it.

---

## Complete Implementation Example

### Bash Completion Script

```bash
# ib completion script for bash
# Usage: eval "$(ib completions bash)"

_ib_completions() {
    local cur prev words cword
    _init_completion 2>/dev/null || {
        COMPREPLY=()
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        cword=$COMP_CWORD
    }

    # All commands
    local commands="new-agent new list ls tree watch status diff info merge send look kill nuke resume hooks log ask acknowledge ack questions watchdog config help"

    # Commands that take an agent ID as first arg
    local agent_cmds="look send status diff info kill resume merge watchdog"

    # new-agent options
    local new_agent_opts="--name --manager --worker --yolo --model --no-worktree --allow-tools --deny-tools --print"

    case $cword in
        1)
            # First arg: complete command names
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            ;;
        *)
            # Subsequent args: depends on command
            local cmd="${COMP_WORDS[1]}"
            case $cmd in
                look|send|status|diff|info|kill|resume|merge|watchdog)
                    if [[ $cword -eq 2 ]]; then
                        # Complete agent IDs
                        local agents=""
                        if [[ -d .ittybitty/agents ]]; then
                            agents=$(ls -1 .ittybitty/agents/ 2>/dev/null)
                        fi
                        COMPREPLY=($(compgen -W "$agents" -- "$cur"))
                    else
                        # Command-specific options
                        case $cmd in
                            look)
                                COMPREPLY=($(compgen -W "--lines --follow" -- "$cur"))
                                ;;
                            kill|merge)
                                COMPREPLY=($(compgen -W "--force" -- "$cur"))
                                ;;
                        esac
                    fi
                    ;;
                new-agent|new)
                    COMPREPLY=($(compgen -W "$new_agent_opts" -- "$cur"))
                    ;;
                list|ls)
                    COMPREPLY=($(compgen -W "--manager --all" -- "$cur"))
                    ;;
                hooks)
                    if [[ $cword -eq 2 ]]; then
                        COMPREPLY=($(compgen -W "status install uninstall" -- "$cur"))
                    fi
                    ;;
                nuke)
                    if [[ $cword -eq 2 ]]; then
                        local agents=""
                        if [[ -d .ittybitty/agents ]]; then
                            agents=$(ls -1 .ittybitty/agents/ 2>/dev/null)
                        fi
                        COMPREPLY=($(compgen -W "--force $agents" -- "$cur"))
                    fi
                    ;;
                config)
                    if [[ $cword -eq 2 ]]; then
                        COMPREPLY=($(compgen -W "get set" -- "$cur"))
                    fi
                    ;;
                log)
                    COMPREPLY=($(compgen -W "--quiet" -- "$cur"))
                    ;;
            esac
            ;;
    esac
}

complete -F _ib_completions ib
```

### Zsh Wrapper (using bashcompinit)

```zsh
# ib completion for zsh (via bashcompinit)
# Usage: eval "$(ib completions zsh)"

autoload -U +X bashcompinit && bashcompinit

# [paste bash completion here]

complete -F _ib_completions ib
```

---

## What Users Need to Install

**Nothing extra!** With `ib completions bash/zsh`:

| Shell | User Action |
|-------|-------------|
| Bash | Add `eval "$(ib completions bash)"` to `~/.bashrc` |
| Zsh | Add `eval "$(ib completions zsh)"` to `~/.zshrc` |

No homebrew packages, no copying files. One line in their shell config.

---

## Implementation Tasks

1. [ ] Add `cmd_completions` function to `ib` script
   - Accept `bash` or `zsh` argument
   - Output appropriate completion script
2. [ ] Implement bash completion logic (~80-100 lines)
   - Command name completion
   - Agent ID completion (dynamic from `.ittybitty/agents/`)
   - Option completion per command
3. [ ] Add zsh wrapper using bashcompinit (~15 lines)
4. [ ] Document in README
5. [ ] Add to `ib help` output
6. [ ] (Optional) Add native zsh completion for richer UI

---

## Commands and Their Arguments Reference

| Command | Takes Agent ID | Options/Args |
|---------|---------------|--------------|
| `new-agent` / `new` | No | `--name`, `--manager`, `--worker`, `--yolo`, `--model`, `--no-worktree`, `--allow-tools`, `--deny-tools`, `--print`, prompt text |
| `list` / `ls` | No | `--manager <id>`, `--all` |
| `tree` | No | - |
| `watch` | No | - |
| `look` | Yes | `--lines <n>`, `--follow` |
| `send` | Yes | message text |
| `status` | Yes | - |
| `diff` | Yes | - |
| `info` | Yes | - |
| `kill` | Yes | `--force` |
| `resume` | Yes | - |
| `merge` | Yes | `--force` |
| `nuke` | No | `--force`, optional agent ID |
| `hooks` | No | `status`, `install`, `uninstall` |
| `log` | No | `--quiet`, message text |
| `ask` | No | question text |
| `acknowledge` / `ack` | No | question ID |
| `questions` | No | - |
| `watchdog` | Yes | - |
| `config` | No | `get <key>`, `set <key> <value>` |

---

## References

- [Bash Programmable Completion Tutorial](https://iridakos.com/programming/2018/03/01/bash-programmable-completion-tutorial) - Comprehensive guide with examples
- [GNU Bash Reference Manual - Programmable Completion](https://www.gnu.org/software/bash/manual/html_node/Programmable-Completion.html) - Official documentation
- [GNU Bash - Programmable Completion Builtins](https://www.gnu.org/software/bash/manual/html_node/Programmable-Completion-Builtins.html) - `complete`, `compgen` reference
- [zsh-completions HOWTO](https://github.com/zsh-users/zsh-completions/blob/master/zsh-completions-howto.org) - Official zsh-completions guide
- [Writing ZSH Completion Scripts](https://blog.mads-hartmann.com/2017/08/06/writing-zsh-completion-scripts.html) - Practical zsh tutorial
- [A Guide to the Zsh Completion with Examples](https://thevaluable.dev/zsh-completion-guide-examples/) - Detailed zsh guide
- [Baeldung - Shell Auto-Completion](https://www.baeldung.com/linux/shell-auto-completion) - General overview

---

## Status

**Status**: Planned
**Priority**: Low
**Effort**: ~2-4 hours for full implementation
