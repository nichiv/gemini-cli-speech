#!/bin/bash

# Gemini CLI with Speech (Hybrid Wrapper Script)
#
# 機能:
# 1. scriptコマンドで標準出力を監視。
# 2. ✦, 実行許可, プロンプトの状態管理。
# 3. プロンプト検知をフラグ管理し、猶予期間明けに自動実行（行待ちハング防止）。

# --- 設定 ---
DEBUG_LOG="$HOME/.gemini/hooks/gemini-speak-debug.log"
SUMMARY_LOG_FILE="$HOME/.gemini/hooks/stop-hook-summary.log"
TRANSCRIPT_FILE="/tmp/gemini-transcript-$$.txt"
SPOKEN_HASH_FILE="/tmp/gemini-speak-hash-$$.txt"
CURRENT_SAY_PID_FILE="/tmp/gemini-say-pid-$$.txt"
SUMMARY_MODEL="gemini-2.0-flash"

# --- 初期化 ---
touch "$SPOKEN_HASH_FILE"
mkdir -p "$(dirname "$SUMMARY_LOG_FILE")"
> "$TRANSCRIPT_FILE"

log() {
  echo "[$(date '+%H:%M:%S')] $1" >> "$DEBUG_LOG"
}

log "--- START SCRIPT (Reliable Loop Version) ---"

# --- 関数定義 ---

speak_text() {
  local text="$1"
  if [ -z "$text" ]; then return; fi

  if [ -f "$CURRENT_SAY_PID_FILE" ]; then
    old_pid=$(cat "$CURRENT_SAY_PID_FILE")
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      kill "$old_pid" 2>/dev/null
      wait "$old_pid" 2>/dev/null
    fi
  fi

  log "Speaking: ${text:0:50}..."
  (
    echo "$text" | /usr/bin/say -v "Kyoko" -r 219 2>/dev/null
  ) &
  echo $! > "$CURRENT_SAY_PID_FILE"
}

clean_text() {
  echo "$1" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | sed -E 's/[（(][0-9]+字[）)]//g' | tr -d '\r' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//'
}

generate_summary_text() {
  local input_text="$1"
  local prompt_msg="以下のメッセージをカテゴリ分類し、要約してください。
出力形式：【カテゴリ】要約内容（合計100字以内）
カテゴリ例：コード実装、質問・確認、説明・解説、提案・アドバイス、設定変更、ファイル操作、調査報告、エラー報告、テスト報告、作業報告
メッセージ：
$input_text"

  log "Requesting summary from Gemini..."
  local raw_output
  raw_output=$(echo "" | /opt/homebrew/bin/gemini -m "$SUMMARY_MODEL" "$prompt_msg" 2>/dev/null)
  if [ $? -ne 0 ]; then
    raw_output=$(echo "" | /opt/homebrew/bin/gemini "$prompt_msg" 2>/dev/null)
  fi
  [ -z "$raw_output" ] && return 1
  clean_text "$raw_output"
}

get_permission_message() {
  local tool_name="$1"
  case "$tool_name" in
    "run_shell_command") echo "Bashコマンドを実行して良いですか？" ;; 
    "read_file"|"list_directory") echo "ファイルを読み込んで良いですか？" ;; 
    "write_file") echo "ファイルに書き込んで良いですか？" ;; 
    "replace") echo "ファイルを編集して良いですか？" ;; 
    "glob") echo "ファイルを検索して良いですか？" ;; 
    "search_file_content") echo "コードを検索して良いですか？" ;; 
    "google_web_search"|"web_fetch") echo "ウェブで検索して良いですか？" ;; 
    *) echo "この操作を実行して良いですか？" ;; 
  esac
}

get_latest_session_file() {
  find ~/.gemini/tmp -maxdepth 4 -name "session-*.json" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -n 1
}

# --- メイン処理 ---

cleanup() {
  log "Cleanup triggered."
  if [ -n "$BG_PID" ]; then
    kill "$BG_PID" 2>/dev/null
    wait "$BG_PID" 2>/dev/null
  fi
  rm -f "$TRANSCRIPT_FILE" "$SPOKEN_HASH_FILE" "$CURRENT_SAY_PID_FILE"
  log "--- END SCRIPT ---"
}
trap cleanup EXIT INT TERM

INITIAL_LATEST_SESSION=$(get_latest_session_file)

(
  my_session=""
  responding=false
  prompt_detected=false
  last_star_time=0
  last_permission_time=0
  
  # 非ブロッキングでファイルを読み取るための設定
  exec 3< <(tail -f "$TRANSCRIPT_FILE" 2>/dev/null)
  
  while true; do
    # 0.2秒待機して1行読み取り
    if read -t 1 line <&3; then
        clean_line=$(echo "$line" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | sed -E 's/[（(][0-9]+字[）)]//g' | tr -d '\r')

        # 1. 応答開始 (✦)
        if [[ "$clean_line" == *"✦"* ]]; then
          responding=true
          prompt_detected=false
          last_star_time=$(date +%s)
          log "[BG] Response started (✦)."
        fi

        # 2. 実行許可検知
        if echo "$clean_line" | grep -q "Allow execution of:" || [[ "$clean_line" == *"│ ?"* ]]; then
          current_time=$(date +%s)
          if [ $((current_time - last_permission_time)) -ge 2 ]; then
            log "[BG] Permission prompt detected."
            responding=false
            prompt_detected=false
            
            if [ -n "$my_session" ]; then
              last_msg=$(jq '.messages | map(select(.type == "gemini" or .type == "model")) | last' "$my_session" 2>/dev/null)
              msg_id=$(echo "$last_msg" | jq -r '.id // empty')
              if [ -n "$msg_id" ] && ! grep -q "${msg_id}_perm" "$SPOKEN_HASH_FILE"; then
                echo "${msg_id}_perm" >> "$SPOKEN_HASH_FILE"
                echo "${msg_id}_content" >> "$SPOKEN_HASH_FILE"
                tool_name=$(echo "$last_msg" | jq -r '.toolCalls[-1].name // empty' 2>/dev/null)
                speak_text "$(get_permission_message "$tool_name")"
                last_permission_time=$(date +%s)
                log "[BG] Spoken permission for $msg_id."
              fi
            fi
          fi
        fi

        # 3. 完了検知 (フラグのみ立てる)
        if [[ "$clean_line" == *"│ >"* ]] || [[ "$clean_line" == *"Type your message"* ]]; then
            if [ "$responding" = true ]; then
                log "[BG] Prompt marker detected. Marking for processing."
                prompt_detected=true
            fi
        fi
    fi

    # --- タイマーベースの処理 (readの成否に関わらず毎回実行) ---
    
    current_time=$(date +%s)
    
    # 応答中かつプロンプト検知済みで、1秒経過していたら処理実行
    if [ "$responding" = true ] && [ "$prompt_detected" = true ] && [ $((current_time - last_star_time)) -ge 1 ]; then
        log "[BG] Cooldown finished. Processing completion."
        responding=false
        prompt_detected=false
        
        if [ -n "$my_session" ]; then
            last_msg=$(jq '.messages | map(select(.type == "gemini" or .type == "model")) | last' "$my_session" 2>/dev/null)
            msg_id=$(echo "$last_msg" | jq -r '.id // empty')
            content=$(echo "$last_msg" | jq -r '.content // empty')
            
            if [ -n "$msg_id" ] && [ -n "$content" ] && [ "$content" != "null" ]; then
                if ! grep -q "${msg_id}_content" "$SPOKEN_HASH_FILE"; then
                    # 最終チェック（ツール待ちがないか）
                    has_pending=$(echo "$last_msg" | jq -r '.toolCalls[]? | select(.result == null) | .name' 2>/dev/null)
                    if [ -z "$has_pending" ]; then
                        echo "${msg_id}_content" >> "$SPOKEN_HASH_FILE"
                        log "[BG] Speaking content for $msg_id"
                        
                        if [ ${#content} -gt 50 ]; then
                          summary=$(generate_summary_text "$content")
                          if [ $? -eq 0 ] && [ -n "$summary" ]; then
                            {
                              echo "──────────────────────────────────────"
                              echo "$(date '+%Y-%m-%d %H:%M:%S')"
                              echo "Working Directory: $(pwd)"
                              echo "──────────────────────────────────────"
                              echo "$summary"
                              echo ""
                            } >> "$SUMMARY_LOG_FILE"
                            speak_text "$summary"
                          else
                            speak_text "$content"
                          fi
                        else
                          speak_text "$content"
                        fi
                    else
                        log "[BG] Suppressed content: tool call pending."
                        echo "${msg_id}_content" >> "$SPOKEN_HASH_FILE"
                    fi
                fi
            fi
        fi
    fi

    # セッション特定（初回）
    if [ -z "$my_session" ]; then
      current_latest=$(get_latest_session_file)
      if [ -n "$current_latest" ] && [ "$current_latest" != "$INITIAL_LATEST_SESSION" ]; then
        my_session="$current_latest"
        log "[BG] Locked on session: $my_session"
      fi
    fi

  done
) &
BG_PID=$!

script -F -q "$TRANSCRIPT_FILE" /opt/homebrew/bin/gemini "$@"
exit_code=$?

exit $exit_code
