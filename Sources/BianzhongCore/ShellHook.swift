import Foundation

/// Generates minimal non-intrusive zsh hooks that report long-running failed commands to Bianzhong.
public enum ShellHook {
    public static func zshScript(bzExecutablePath: String = "bz") -> String {
        """
        # Bianzhong zsh slow-command failure hook
        # Add to ~/.zshrc: eval "$(\(bzExecutablePath) shell-hook zsh)"
        : ${BIANZHONG_SHELL_MIN_SECONDS:=15}
        : ${BIANZHONG_SHELL_SKIP_CMDS:="vim nvim nano less man top htop btop ssh tmux omp codex claude bz"}

        _bianzhong_preexec() {
          _bianzhong_cmd_start=$SECONDS
          _bianzhong_last_cmd="$1"
        }

        _bianzhong_precmd() {
          local exit_code=$?
          local start_ts=${_bianzhong_cmd_start:-0}
          local cmd="${_bianzhong_last_cmd:-}"
          _bianzhong_cmd_start=0
          _bianzhong_last_cmd=""

          [[ -n "${BIANZHONG_DEPTH:-}" ]] && return 0
          (( start_ts == 0 )) && return 0
          (( exit_code == 0 || exit_code == 130 )) && return 0

          local elapsed=$(( SECONDS - start_ts ))
          (( elapsed < BIANZHONG_SHELL_MIN_SECONDS )) && return 0

          local first_word="${cmd%% *}"
          local skip
          for skip in ${(s: :)BIANZHONG_SHELL_SKIP_CMDS}; do
            [[ "$first_word" == "$skip" ]] && return 0
          done

          (
            "\(bzExecutablePath)" emit \\
              --source "bz://sensor/shell/zsh" \\
              --type "dev.bianzhong.shell.command_failed" \\
              --correlation-key "shell:$PWD" \\
              --cwd "$PWD" \\
              --title "命令失败 (exit=$exit_code, ${elapsed}s)" \\
              --subtitle "$PWD" \\
              --body "Command: $cmd | Exit: $exit_code | Duration: ${elapsed}s | CWD: $PWD" \\
              >/dev/null 2>&1
          ) &!
        }

        autoload -Uz add-zsh-hook
        add-zsh-hook preexec _bianzhong_preexec
        add-zsh-hook precmd _bianzhong_precmd
        """
    }
}
