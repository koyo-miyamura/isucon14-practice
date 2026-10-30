#!/usr/bin/env bash
# ISUCON 運用コマンドの本体。手元の mac から実行し、サーバーへの操作はすべて ssh 経由で行う。
# 普段は Makefile 経由で `make <コマンド>` として呼ぶ (make <TAB> で補完が効く)。直接 make <コマンド> でも動く。
#
#   初回:            make ping && make install-tools && make init
#   ベンチのたび:    make prepare-bench  ->  ベンチ実行  ->  make after-bench
#   コード反映:      make release        (= push + deploy)
#   状況確認:        make status / make logs SINCE=-10min / make ssh HOST=10.97.0.12
#
# 下の設定はすべて環境変数で上書きできる。make の引数で渡せばそのまま届く。例:
#   make prepare-bench APP_HOSTS="10.97.0.12 10.97.0.14" RBSPY_UNITS=
set -euo pipefail
cd "$(dirname "$0")"

# ==============================================================================
# [当日] 競技ごとに書き換える設定。ここだけ直せば他は触らなくてよい想定。
#        それぞれの調べ方は README「当日書き換える箇所」を参照。
#        書き換えたら make ping で全部つながること、make help で値を確認する。
# ==============================================================================
read -ra APP_HOSTS   <<<"${APP_HOSTS:-10.97.0.12}"    # [当日] アプリ (puma) を動かすサーバー。複数可 (空白区切り)
read -ra NGINX_HOSTS <<<"${NGINX_HOSTS:-10.97.0.12}"  # [当日] nginx が動くサーバー (alp の対象)
read -ra DB_HOSTS    <<<"${DB_HOSTS:-10.97.0.13}"     # [当日] MySQL が動くサーバー (pt-query-digest の対象)
APP_UNITS=${APP_UNITS:-isuride-ruby.service isuride-matcher.service}  # [当日] systemctl list-units | grep -i isu で確認
NGINX_UNITS=${NGINX_UNITS:-nginx.service}
DB_UNITS=${DB_UNITS:-mysql.service}                   # [当日] mariadb.service の年もある
# スコア計測の回は RBSPY_UNITS= (空) にすると rbspy をスキップする
RBSPY_UNITS=${RBSPY_UNITS-isuride-ruby.service}       # [当日] APP_UNITS のうち puma のユニットだけ
MYSQL_LOGS=${MYSQL_LOGS:-/var/log/mysql/slow.log /var/log/mysql/error.log}  # [当日] slow.log は conf/mysqld.cnf の slow_query_log_file と合わせる
NGINX_LOGS=${NGINX_LOGS:-/var/log/nginx/access.log /var/log/nginx/error.log}
# alp で同じエンドポイントとして束ねる正規表現。パスパラメータを含む URL を webapp/openapi.yaml や routes から拾う
ALP_MATCH=${ALP_MATCH:-/rides/.*/evaluation,/rides/.*/status,/assets/.*,/images/.*}  # [当日] 必ず書き換える
APP_DIR=${APP_DIR:-webapp/ruby}                       # [当日] bundle install するディレクトリ (REMOTE_REPO からの相対)
# ==============================================================================

# ---- サーバー (普段は触らない) ---------------------------------------------------
SSH_USER=${SSH_USER:-isucon}
HOSTS=($(printf '%s\n' "${APP_HOSTS[@]}" "${NGINX_HOSTS[@]}" "${DB_HOSTS[@]}" | sort -u))
# BatchMode=yes: 鍵認証が通らないときにパスワード入力で止まらず即失敗させる
# ForwardAgent=yes: deploy 時の git fetch でサーバーに鍵を置かずに手元の GitHub 用鍵を使う
SSH_OPTS=${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o ForwardAgent=yes}
# 1 コマンドで何度も ssh するので、遅いときは接続を使い回す次の行を有効にする
# SSH_OPTS+=" -o ControlMaster=auto -o ControlPath=~/.ssh/cm-%r@%h:%p -o ControlPersist=10m"

REMOTE_REPO=${REMOTE_REPO:-/home/$SSH_USER}
REMOTE_LOG=${REMOTE_LOG:-$REMOTE_REPO/log}
LOCAL_LOG=${LOCAL_LOG:-log}
GIT_BRANCH=${GIT_BRANCH:-main}
# 非対話 ssh では ~/.bashrc の PATH が効かず bundle が見つからないことがあるので、その場合に PATH へ前置する
RUBY_BIN=${RUBY_BIN:-}
ALL_UNITS="$APP_UNITS $NGINX_UNITS $DB_UNITS"

# ---- プロファイル / 解析 (普段は触らない) -----------------------------------------
# puma が cluster mode だと worker は fork されるので --subprocesses が必須
RBSPY_OPTS=${RBSPY_OPTS:---rate 99 --subprocesses}
RBSPY_VERSION=${RBSPY_VERSION:-0.55.0}
ALP_VERSION=${ALP_VERSION:-1.0.22}

# ---- ベンチ 1 回分の識別子: new-run が書き、after-bench が読む ----------------------
RUN_ID=${RUN_ID:-$(cat "$LOCAL_LOG/.current_run" 2>/dev/null || true)}
SINCE=${SINCE:-$(cat "$LOCAL_LOG/.current_since" 2>/dev/null || true)}
SINCE=${SINCE:--30min}

# ---- 共通ヘルパー --------------------------------------------------------------
log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

# remote HOST [VAR=value ...] <<'EOF' : 標準入力のスクリプトを HOST 上のログインシェルで実行する。
# RUN_ID / SINCE / LOG / REPO はリモート側で常に参照できる。
# ヒアドキュメントは <<'EOF' (クォート付き) にして、手元で展開させず環境変数で値を渡す。
remote() {
  local host=$1; shift
  local env="" kv
  for kv in RUN_ID="$RUN_ID" SINCE="$SINCE" LOG="$REMOTE_LOG/$RUN_ID" REPO="$REMOTE_REPO" "$@"; do
    env+="$(printf '%q' "$kv") "
  done
  # shellcheck disable=SC2086  # SSH_OPTS は意図的に単語分割する
  ssh $SSH_OPTS "$SSH_USER@$host" "${env}bash -lse"
}

# each "HOST HOST ..." [VAR=value ...] <<'EOF' : 標準入力のスクリプトを各ホストで順に実行し、失敗したら止まる。
each() {
  local hosts=$1 script h; shift
  script=$(cat)
  for h in $hosts; do
    log "$h"
    remote "$h" "$@" <<<"$script"
  done
}

# root 所有のファイルを扱うため、リモート側の rsync を sudo で動かす
# shellcheck disable=SC2086
rsync_sudo() { rsync -rtv -e "ssh $SSH_OPTS" --rsync-path="sudo rsync" "$@"; }

require_run() { [ -n "$RUN_ID" ] || die "RUN_ID is empty: run 'make prepare-bench' first or pass RUN_ID=..."; }

# restart_units "HOST ..." "UNIT ..." : 再起動して is-active を確認し、失敗したら journal を出して止まる
restart_units() {
  each "$1" UNITS="$2" <<'EOF'
for u in $UNITS; do sudo systemctl restart "$u"; done
for u in $UNITS; do
  if systemctl is-active --quiet "$u"; then
    echo "$u: active"
  else
    echo "!! $u failed to start on $(hostname)" >&2
    sudo journalctl -u "$u" -n 50 --no-pager >&2
    exit 1
  fi
done
EOF
}

# 開いたままのログファイルを安全に空にするため、rm ではなく truncate を使う
truncate_files() {
  each "$1" FILES="$2" <<'EOF'
for f in $FILES; do
  if [ -f "$f" ]; then sudo truncate -s0 "$f"; echo "truncated $f"; else echo "skip: $f not found"; fi
done
EOF
}

# collect_logs "HOST ..." NAME "UNIT ..." "FILE ..." : SINCE 以降の journal と生ログを $LOG に集める。
# journal には systemd 管理プロセスの標準出力・標準エラーが入るので、アプリの例外はここで拾える。
collect_logs() {
  each "$1" NAME="$2" UNITS="$3" FILES="$4" <<'EOF'
mkdir -p "$LOG"
args=""; for u in $UNITS; do args="$args -u $u"; done
sudo journalctl $args --since "$SINCE" --no-pager -o short-iso > "$LOG/journal-$NAME.log"
for f in $FILES; do
  if [ -f "$f" ]; then sudo cat "$f" > "$LOG/$NAME-$(basename "$f")"; else echo "skip: $f not found"; fi
done
ls -l "$LOG"
EOF
}

# ---- セットアップ --------------------------------------------------------------
cmd_ping() { ## 全ホストの ssh / sudo / ruby / ツール / リポジトリ / ユニット状態を確認する (最初に実行)
  each "${HOSTS[*]}" RUBY_BIN="$RUBY_BIN" ALL_UNITS="$ALL_UNITS" <<'EOF'
echo "host=$(hostname) user=$(id -un) arch=$(uname -m) os=$(lsb_release -ds 2>/dev/null || uname -r)"
sudo -n true && echo "sudo: ok (NOPASSWD)"
[ -z "$RUBY_BIN" ] || export PATH="$RUBY_BIN:$PATH"
command -v ruby   >/dev/null && echo "ruby: $(ruby -v)"            || echo "ruby: not in PATH (set RUBY_BIN=... for deploy)"
command -v bundle >/dev/null && echo "bundle: $(command -v bundle)" || echo "bundle: not in PATH (set RUBY_BIN=... for deploy)"
if git -C "$REPO" rev-parse --short HEAD >/dev/null 2>&1; then
  echo "repo: $REPO @ $(git -C "$REPO" rev-parse --short HEAD)"
else
  echo "repo: $REPO is not a git repository"
fi
for t in alp pt-query-digest rbspy; do
  command -v "$t" >/dev/null && echo "$t: installed" || echo "$t: missing (make install-tools)"
done
for u in $ALL_UNITS; do printf '%-26s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done
EOF
}

cmd_init() { ## ローカルにディレクトリを作り、nginx / mysql / puma の設定をサーバーから取得する
  mkdir -p conf/nginx/sites-available conf/systemd "$LOCAL_LOG"
  cmd_get_conf
}

cmd_install_tools() { ## alp / pt-query-digest / rbspy を全ホストに入れる (何度実行してもよい)
  each "${HOSTS[*]}" ALP_VERSION="$ALP_VERSION" RBSPY_VERSION="$RBSPY_VERSION" <<'EOF'
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq rsync wget curl unzip percona-toolkit
case "$(uname -m)" in
  x86_64)  alp_arch=amd64; rbspy_arch=x86_64 ;;
  aarch64) alp_arch=arm64; rbspy_arch=aarch64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if ! alp --version 2>/dev/null | grep -q "$ALP_VERSION"; then
  curl -fsSL -o "$tmp/alp.zip" "https://github.com/tkuchiki/alp/releases/download/v$ALP_VERSION/alp_linux_$alp_arch.zip"
  unzip -oq "$tmp/alp.zip" -d "$tmp"
  sudo install "$tmp/alp" /usr/local/bin/alp
fi
if ! rbspy --version 2>/dev/null | grep -q "$RBSPY_VERSION"; then
  curl -fsSL -o "$tmp/rbspy.tar.gz" "https://github.com/rbspy/rbspy/releases/download/v$RBSPY_VERSION/rbspy-$rbspy_arch-unknown-linux-gnu.tar.gz"
  tar -xzf "$tmp/rbspy.tar.gz" -C "$tmp"
  sudo install "$tmp/rbspy-$rbspy_arch-unknown-linux-gnu" /usr/local/bin/rbspy
fi
echo "alp:   $(alp --version)"
echo "rbspy: $(rbspy --version)"
echo "ptqd:  $(pt-query-digest --version)"
EOF
}

cmd_install_memcached() { ## memcached を入れる。make install-memcached HOST=... (省略時は APP_HOSTS)
  each "${*:-${HOST:-${APP_HOSTS[*]}}}" <<'EOF'
export DEBIAN_FRONTEND=noninteractive
sudo apt-get install -y -qq memcached
sudo systemctl enable --now memcached
systemctl is-active memcached
EOF
}

# ---- 設定ファイルの同期 --------------------------------------------------------
cmd_get_conf() { ## nginx + mysql + puma の設定を conf/ に取得する
  cmd_get_nginxconf
  cmd_get_mysqlconf
  cmd_get_pumaconf
}

cmd_get_nginxconf() {
  local h=${NGINX_HOSTS[0]}
  log "$h"
  mkdir -p conf/nginx/sites-available
  rsync_sudo "$SSH_USER@$h:/etc/nginx/nginx.conf" conf/nginx/nginx.conf
  rsync_sudo "$SSH_USER@$h:/etc/nginx/sites-available/" conf/nginx/sites-available/
}

cmd_get_mysqlconf() {
  local h=${DB_HOSTS[0]}
  log "$h"
  rsync_sudo "$SSH_USER@$h:/etc/mysql/mysql.conf.d/mysqld.cnf" conf/mysqld.cnf
}

cmd_set_conf() { ## conf/ をサーバーへ反映する (nginx -t / daemon-reload まで。再起動はしない)
  cmd_set_nginxconf
  cmd_set_mysqlconf
  cmd_set_pumaconf
}

cmd_set_nginxconf() {
  local h
  for h in "${NGINX_HOSTS[@]}"; do
    log "$h"
    rsync_sudo conf/nginx/nginx.conf "$SSH_USER@$h:/etc/nginx/nginx.conf"
    rsync_sudo conf/nginx/sites-available/ "$SSH_USER@$h:/etc/nginx/sites-available/"
    remote "$h" <<'EOF'
sudo chown -R root:root /etc/nginx/nginx.conf /etc/nginx/sites-available
sudo nginx -t
EOF
  done
}

cmd_set_mysqlconf() {
  local h
  for h in "${DB_HOSTS[@]}"; do
    log "$h"
    rsync_sudo conf/mysqld.cnf "$SSH_USER@$h:/etc/mysql/mysql.conf.d/mysqld.cnf"
    remote "$h" <<'EOF'
sudo chown root:root /etc/mysql/mysql.conf.d/mysqld.cnf
EOF
  done
}

# puma の workers / threads / bind は systemd ユニットの ExecStart で渡されているので、
# puma の設定 = APP_UNITS のユニットファイルとして扱う。puma.rb を使う場合はリポジトリ内の APP_DIR に置き、
# ExecStart を `puma -C puma.rb` に変えて deploy で配る。
cmd_get_pumaconf() { ## puma を起動する systemd ユニット (APP_UNITS) を conf/systemd/ に取得する
  local h=${APP_HOSTS[0]} u
  log "$h"
  mkdir -p conf/systemd
  for u in $APP_UNITS; do
    rsync_sudo "$SSH_USER@$h:/etc/systemd/system/$u" "conf/systemd/$u"
  done
}

cmd_set_pumaconf() { ## conf/systemd/ のユニットを APP_HOSTS へ反映して daemon-reload する (再起動はしない)
  local h u
  for u in $APP_UNITS; do
    [ -f "conf/systemd/$u" ] || die "conf/systemd/$u not found: run 'make get-pumaconf' first"
  done
  for h in "${APP_HOSTS[@]}"; do
    log "$h"
    for u in $APP_UNITS; do
      rsync_sudo "conf/systemd/$u" "$SSH_USER@$h:/etc/systemd/system/$u"
    done
    remote "$h" UNITS="$APP_UNITS" <<'EOF'
for u in $UNITS; do
  sudo chown root:root "/etc/systemd/system/$u"
  sudo systemd-analyze verify "/etc/systemd/system/$u"
done
sudo systemctl daemon-reload
EOF
  done
}

# ---- サービス ------------------------------------------------------------------
cmd_restart() { ## mysql -> app -> nginx の順に再起動し、それぞれ起動を確認する
  cmd_restart_mysql
  cmd_restart_app
  cmd_restart_nginx
}
cmd_restart_app()   { restart_units "${APP_HOSTS[*]}"   "$APP_UNITS"; }
cmd_restart_nginx() { restart_units "${NGINX_HOSTS[*]}" "$NGINX_UNITS"; }
cmd_restart_mysql() { restart_units "${DB_HOSTS[*]}"    "$DB_UNITS"; }

cmd_cleanlog() { ## nginx の access/error log と mysql の slow/error log を空にする
  truncate_files "${NGINX_HOSTS[*]}" "$NGINX_LOGS"
  truncate_files "${DB_HOSTS[*]}"    "$MYSQL_LOGS"
}

cmd_status() { ## 全ホストのユニット状態を表示する
  each "${HOSTS[*]}" ALL_UNITS="$ALL_UNITS" <<'EOF'
for u in $ALL_UNITS; do printf '%-26s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done
EOF
}

cmd_logs() { ## journal を見る。make logs SINCE=-10min UNITS="nginx.service" HOST=...
  local h=${1:-${HOST:-${APP_HOSTS[0]}}} args="" u
  for u in ${UNITS:-$APP_UNITS}; do args="$args -u $u"; done
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$SSH_USER@$h" "sudo journalctl $args --since '$SINCE' --no-pager -o short-iso"
}

cmd_ssh() { ## サーバーにログインする。make ssh HOST=...
  exec ssh "$SSH_USER@${1:-${HOST:-${APP_HOSTS[0]}}}"
}

cmd_mysql() { ## DB サーバーの MySQL に入る。make mysql [HOST=...] [Q="SELECT ..."] (Q を付けると 1 回実行して戻る)
  local h=${HOST:-${DB_HOSTS[0]}} tty=-t
  # 認証情報はサーバー上の env.sh から読む。パスワードは引数でなく MYSQL_PWD で渡し、ps に出さない
  # [当日] env.sh の変数名 (ISUCON_DB_*) が年によって違うので、make mysql が失敗したらここを合わせる
  local remote_cmd='set -a; . "$REPO/env.sh"; set +a; export MYSQL_PWD=$ISUCON_DB_PASSWORD; exec mysql -h 127.0.0.1 -P "$ISUCON_DB_PORT" -u "$ISUCON_DB_USER" "$ISUCON_DB_NAME"'
  if [ -n "${Q:-}" ]; then
    remote_cmd+=" -e $(printf '%q' "$Q")"
    tty=
  fi
  # shellcheck disable=SC2086
  exec ssh $SSH_OPTS $tty "$SSH_USER@$h" "REPO=$(printf '%q' "$REMOTE_REPO") bash -c $(printf '%q' "$remote_cmd")"
}

# ---- ベンチ --------------------------------------------------------------------
cmd_new_run() { ## 新しい RUN_ID を発行し、サーバー側の現在時刻を SINCE として記録する
  mkdir -p "$LOCAL_LOG"
  # 手元とサーバーの時計がずれていても journalctl --since が正しく効くよう、サーバーの時刻を使う
  # shellcheck disable=SC2086
  SINCE=$(ssh $SSH_OPTS "$SSH_USER@${HOSTS[0]}" "date '+%F %T'")
  RUN_ID=$(date +%Y%m%d_%H%M%S)
  echo "$RUN_ID" > "$LOCAL_LOG/.current_run"
  echo "$SINCE"  > "$LOCAL_LOG/.current_since"
  echo "RUN_ID=$RUN_ID SINCE=$SINCE"
}

cmd_rbspy_start() { ## APP_HOSTS 上で RBSPY_UNITS に rbspy をバックグラウンドで仕掛ける
  require_run
  if [ -z "$RBSPY_UNITS" ]; then echo "RBSPY_UNITS is empty, skipping rbspy"; return; fi
  # --duration は使わない。ベンチ開始は手動で時間が読めないので、after-bench の SIGINT で止める
  each "${APP_HOSTS[*]}" UNITS="$RBSPY_UNITS" RBSPY_OPTS="$RBSPY_OPTS" <<'EOF'
mkdir -p "$LOG"
for unit in $UNITS; do
  pid=$(systemctl show -p MainPID --value "$unit")
  if [ -z "$pid" ] || [ "$pid" = 0 ]; then echo "!! $unit is not running on $(hostname)" >&2; exit 1; fi
  name=${unit%.service}
  sudo nohup rbspy record --pid "$pid" $RBSPY_OPTS --format flamegraph \
    --file "$LOG/rbspy-$name.svg" --raw-file "$LOG/rbspy-$name.raw.gz" \
    >"$LOG/rbspy-$name.out" 2>&1 </dev/null &
done
sleep 2
if ! pgrep -f "rbspy record" >/dev/null; then
  echo "!! rbspy did not start on $(hostname)" >&2
  cat "$LOG"/rbspy-*.out >&2 || true
  exit 1
fi
pgrep -af "rbspy record"
EOF
}

cmd_rbspy_stop() { ## rbspy に SIGINT を送り、flamegraph が書き出されるまで待つ
  require_run
  each "${APP_HOSTS[*]}" <<'EOF'
if pgrep -f "rbspy record" >/dev/null; then
  sudo pkill -INT -f "rbspy record"
  for i in $(seq 60); do pgrep -f "rbspy record" >/dev/null || break; sleep 1; done
  if pgrep -f "rbspy record" >/dev/null; then echo "!! rbspy still running after 60s" >&2; exit 1; fi
fi
mkdir -p "$LOG"
sudo chown -R "$(id -un):" "$LOG"
ls -l "$LOG"/rbspy-* 2>/dev/null || echo "no rbspy output on $(hostname)"
EOF
}

cmd_prepare_bench() { ## 設定反映 -> 全再起動 -> ログ削除 -> rbspy 開始。このあとベンチを回す
  cmd_new_run
  cmd_set_conf
  cmd_restart
  cmd_cleanlog
  cmd_rbspy_start
  echo
  echo ">>> ready: RUN_ID=$RUN_ID SINCE=$SINCE"
  echo ">>> run the benchmarker, then: make after-bench"
}

cmd_after_bench() { ## rbspy 停止 -> journal/ログ/システム情報の収集 -> alp + pt-query-digest -> log/RUN_ID/ に回収
  require_run
  cmd_rbspy_stop
  cmd_collect_logs
  cmd_analyze
  cmd_fetch_logs
  cmd_show_result
}

cmd_collect_logs() { ## SINCE 以降の journal (標準出力・標準エラー)、生ログ、システム情報を集める
  require_run
  collect_logs "${APP_HOSTS[*]}"   app   "$APP_UNITS"   ""
  collect_logs "${NGINX_HOSTS[*]}" nginx "$NGINX_UNITS" "$NGINX_LOGS"
  collect_logs "${DB_HOSTS[*]}"    mysql "$DB_UNITS"    "$MYSQL_LOGS"
  each "${HOSTS[*]}" ALL_UNITS="$ALL_UNITS" <<'EOF'
mkdir -p "$LOG"
{
  echo "## $(hostname) $(date '+%F %T')"
  echo; echo "## uptime";           uptime
  echo; echo "## free -m";          free -m
  echo; echo "## df -h /";          df -h /
  echo; echo "## top -bn1";         top -bn1 | head -25
  echo; echo "## ss -s";            ss -s
  echo; echo "## systemctl status"; systemctl status $ALL_UNITS --no-pager 2>&1 || true
} > "$LOG/system.txt"
sudo chown -R "$(id -un):" "$LOG"
EOF
}

cmd_analyze() { ## サーバー上で alp (nginx ホスト) と pt-query-digest (db ホスト) を実行する
  require_run
  each "${NGINX_HOSTS[*]}" ALP_MATCH="$ALP_MATCH" <<'EOF'
alp ltsv --file "$LOG/nginx-access.log" -m "$ALP_MATCH" --sort=sum -r > "$LOG/alp-result.txt"
head -n 5 "$LOG/alp-result.txt"
EOF
  each "${DB_HOSTS[*]}" <<'EOF'
pt-query-digest "$LOG/mysql-slow.log" > "$LOG/ptqd-result.txt"
head -n 5 "$LOG/ptqd-result.txt"
EOF
}

cmd_fetch_logs() { ## 各ホストの log/RUN_ID を手元の log/RUN_ID/<host>/ に rsync で回収する
  require_run
  local h
  for h in "${HOSTS[@]}"; do
    log "$h"
    mkdir -p "$LOCAL_LOG/$RUN_ID/$h"
    # shellcheck disable=SC2086
    rsync -rtz -e "ssh $SSH_OPTS" "$SSH_USER@$h:$REMOTE_LOG/$RUN_ID/" "$LOCAL_LOG/$RUN_ID/$h/"
  done
}

cmd_show_result() { ## RUN_ID の alp / pt-query-digest の先頭と flamegraph のパスを表示する
  require_run
  local h f
  for h in "${NGINX_HOSTS[@]}"; do
    f="$LOCAL_LOG/$RUN_ID/$h/alp-result.txt"
    [ -f "$f" ] && { log "alp ($h)"; head -n 25 "$f"; }
  done
  for h in "${DB_HOSTS[@]}"; do
    f="$LOCAL_LOG/$RUN_ID/$h/ptqd-result.txt"
    [ -f "$f" ] && { log "pt-query-digest ($h)"; head -n 40 "$f"; }
  done
  log "files"
  find "$LOCAL_LOG/$RUN_ID" -type f | sort
  log "flamegraph"
  find "$LOCAL_LOG/$RUN_ID" -name 'rbspy-*.svg' | sed 's/^/open /'
}

# ---- リリース ------------------------------------------------------------------
cmd_deploy() { ## APP_HOSTS で git reset --hard origin/GIT_BRANCH + bundle install + app 再起動 (FORCE=1 でサーバー側の変更を破棄)
  local h
  for h in "${APP_HOSTS[@]}"; do
    log "$h"
    # サーバー上で直接いじった変更を reset --hard で飛ばす事故を防ぐため、dirty なら拒否する
    remote "$h" BRANCH="$GIT_BRANCH" FORCE="${FORCE:-}" RUBY_BIN="$RUBY_BIN" APP_DIR="$APP_DIR" <<'EOF'
cd "$REPO"
[ -z "$RUBY_BIN" ] || export PATH="$RUBY_BIN:$PATH"
if [ -z "$FORCE" ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "!! $(hostname): working tree is dirty, refusing to reset (FORCE=1 discards local changes)" >&2
  git status --short >&2
  exit 1
fi
git fetch --quiet origin "$BRANCH"
git reset --hard "origin/$BRANCH"
command -v bundle >/dev/null || { echo "!! bundle not in PATH; pass RUBY_BIN=/path/to/ruby/bin" >&2; exit 1; }
(cd "$APP_DIR" && bundle install --quiet)
echo "checked out $(git rev-parse --short HEAD) on $(hostname)"
EOF
    restart_units "$h" "$APP_UNITS"
  done
}

cmd_push() { ## 手元の変更を全部 add / commit / push する
  git add .
  git commit -m "push from isu.sh $(date '+%F %T')"
  git push origin "$GIT_BRANCH"
}

cmd_release() { ## push + deploy
  cmd_push
  cmd_deploy
}

# ---- ヘルプ / ディスパッチ ----------------------------------------------------
# 関数定義行の `## ` 以降をヘルプ文として使う。ヘルプに載せたいコマンドにはこの形式で書く。
cmd_help() { ## コマンド一覧と現在の設定を表示する
  echo "usage: make <command> [VAR=value ...]"
  echo
  grep -E '^cmd_[a-z_]+\(\) *\{ *## ' "$0" \
    | sed -E 's/^cmd_([a-z_]+)\(\) *\{ *## (.*)$/\1\t\2/' \
    | awk -F'\t' '{ gsub("_", "-", $1); printf "  \033[36m%-18s\033[0m %s\n", $1, $2 }'
  echo
  echo "  [当日] APP_HOSTS=${APP_HOSTS[*]}  NGINX_HOSTS=${NGINX_HOSTS[*]}  DB_HOSTS=${DB_HOSTS[*]}"
  echo "  [当日] APP_UNITS=$APP_UNITS  DB_UNITS=$DB_UNITS  RBSPY_UNITS=$RBSPY_UNITS"
  echo "  [当日] ALP_MATCH=$ALP_MATCH"
  echo "  [当日] MYSQL_LOGS=$MYSQL_LOGS  APP_DIR=$APP_DIR"
  echo "  RUN_ID=$RUN_ID  SINCE=$SINCE"
}

# メイン処理
cmd=${1:-help}
[ $# -eq 0 ] || shift
fn="cmd_${cmd//-/_}"
declare -F "$fn" >/dev/null || die "unknown command: $cmd (see make help)"
"$fn" "$@"
