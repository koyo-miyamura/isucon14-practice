# isucon14-practice

ISUCON14 の練習用リポジトリ。サーバー操作は手元の mac から `make <コマンド>` で行う。
サーバーに ssh してから何かをする必要は基本的にない。

- 入口: [Makefile](Makefile)(`make <TAB>` で補完が効く)
- 処理本体: [isu.sh](isu.sh)

## 初回セットアップ

最初の 1 回だけ。サーバーを git 管理下に置くところまでは手作業で行う(環境が想定と違う可能性があるので、目で見ながら進める)。

### 0. 手元の準備

- サーバーへの ssh 公開鍵は競技環境側で登録済み。`ssh isucon@<IP>` で入れることだけ確認する。
- GitHub の鍵が ssh-agent に入っていることを確認する(`ssh-add -l`)。サーバーから GitHub へ push / fetch するときは `ssh -A` のエージェント転送で手元の鍵を使うので、サーバー側に鍵を置く必要はない。
- GitHub に空のプライベートリポジトリを作る。

```bash
gh repo create koyo-miyamura/isucon2026 --private
```

### 1. 1 台目のサーバーをリポジトリにする(手作業)

```bash
scp .gitignore isucon@<IP>:~/        # このリポジトリの .gitignore を流用(local/ や dotfiles を除外する内容)
ssh -A isucon@<IP>                   # -A は必須。これがないと後の git push で GitHub の認証に失敗する。以降はサーバー上
```

```bash
cd ~
ssh-keyscan github.com >> ~/.ssh/known_hosts   # これがないと非対話の git fetch がホスト鍵確認で止まる
git init -b main
git config --global user.email "nexus9071@gmail.com"
git config --global user.name "koyo"
git add .
git status                           # 巨大ファイルや秘密情報が入っていないか目視
git commit -m "first commit"
git remote add origin git@github.com:koyo-miyamura/isucon2026
git push -u origin main
```

### 2. 手元に clone して運用ファイルを入れる

```bash
git clone git@github.com:koyo-miyamura/isucon2026
cd isucon2026
# このリポジトリから Makefile / isu.sh / README.md / docs/ をコピーする
```

[isu.sh](isu.sh) 先頭の `APP_HOSTS` / `NGINX_HOSTS` / `DB_HOSTS` を今回のサーバー IP に合わせてから commit して push する。

### 3. 2 台目以降のサーバー

`make deploy` は全サーバーの `/home/isucon` が git リポジトリである前提なので、残りのサーバーにも同じリポジトリを載せる。

```bash
ssh -A isucon@<IP>
cd ~
ssh-keyscan github.com >> ~/.ssh/known_hosts
git init -b main
git remote add origin git@github.com:koyo-miyamura/isucon2026
git fetch origin
git reset --hard origin/main         # 1 台目の内容で上書きする。gitignore 対象(local/ など)はそのまま残る
```

### 4. ツール導入と設定取得(ここから make)

```bash
make ping           # 全サーバーへの ssh / sudo / ruby / ツール / リポジトリ位置を確認
make install-tools  # alp / pt-query-digest / rbspy をサーバーに入れる
make init           # nginx / mysql の設定ファイルをサーバーから conf/ に取得
```

`make ping` で `bundle: not in PATH` と出たら、以後 `make deploy RUBY_BIN=/home/isucon/local/ruby/bin` のように Ruby の bin ディレクトリを渡す。

### 5. 計測用の設定を書いて反映する(手作業 + make)

`make init` で取れた `conf/` に、スロークエリログと LTSV アクセスログの設定を手で足す。これを自動化するコマンドはない(元の設定ファイルの構造がサーバーごとに違うため)。

`conf/mysqld.cnf` の `[mysqld]` セクションに追加:

```ini
[mysqld]
slow_query_log=1
slow_query_log_file=/var/log/mysql/slow.log
long_query_time=0
```

`conf/nginx/nginx.conf` の `http {}` ブロック内に追加(`alp ltsv` はこのキー名を前提にしている):

```nginx
    log_format ltsv "time:$time_local"
                    "\thost:$remote_addr"
                    "\tforwardedfor:$http_x_forwarded_for"
                    "\treq:$request"
                    "\tstatus:$status"
                    "\tmethod:$request_method"
                    "\turi:$request_uri"
                    "\tsize:$body_bytes_sent"
                    "\treferer:$http_referer"
                    "\tua:$http_user_agent"
                    "\treqtime:$request_time"
                    "\tcache:$upstream_http_x_cache"
                    "\truntime:$upstream_http_x_runtime"
                    "\tapptime:$upstream_response_time"
                    "\tvhost:$host";

    access_log /var/log/nginx/access.log ltsv;
```

確認ポイント:

- `conf/nginx/sites-available/*` の `server {}` 内に別の `access_log` があると、そちらが優先されて LTSV にならない。あれば削除するか `ltsv` 指定に変える。
- `long_query_time=0` は全クエリを記録する設定なので、ベンチ中のスコアを少し落とす。計測目的ならこれでよい。

書けたら反映して、commit する。

```bash
make set-conf       # サーバーへ反映。nginx -t が通ることを確認
make restart
```

ここまでで準備完了。以降は「ベンチを回したい」の手順を回す。

## シチュエーション別コマンド

### ベンチを回したい

```bash
make prepare-bench  # 設定反映 -> 全サービス再起動 -> ログ削除 -> rbspy 開始
# ここでベンチを実行する
make after-bench    # rbspy 停止 -> ログ・journal・システム情報を収集 -> alp / pt-query-digest -> log/<RUN_ID>/ に回収
```

結果は `log/<RUN_ID>/<サーバーIP>/` に入る。

| ファイル | 中身 |
| --- | --- |
| `alp-result.txt` | nginx アクセスログの集計(エンドポイント別の件数・合計時間) |
| `ptqd-result.txt` | MySQL スロークエリの集計 |
| `rbspy-isuride-ruby.svg` | Ruby アプリの flamegraph(ブラウザで開く) |
| `journal-app.log` | アプリの標準出力・標準エラー(例外のバックトレースはここ) |
| `journal-nginx.log` / `journal-mysql.log` | nginx / MySQL の journal |
| `nginx-access.log` / `nginx-error.log` / `mysql-slow.log` / `mysql-error.log` | 生ログ |
| `system.txt` | uptime / free / top / ss / systemctl status のスナップショット |

スコア計測だけしたいときは rbspy を外す(プロファイラのオーバーヘッドをなくす)。

```bash
make prepare-bench RBSPY_UNITS=
```

### アプリのコードを直した

```bash
make release        # 手元の変更を commit & push し、サーバーで git reset --hard + bundle install + アプリ再起動
```

commit は自分でやる派なら、push 後に `make deploy` だけでよい。
サーバー上で直接ファイルをいじってあると deploy は拒否される。捨ててよければ `make deploy FORCE=1`。

### nginx や MySQL の設定を直した

`conf/nginx/` や `conf/mysqld.cnf` を編集してから次を実行する。

```bash
make set-conf       # サーバーへ反映(nginx -t まで。再起動はしない)
make restart        # mysql -> app -> nginx の順に再起動し、起動を確認
```

`make prepare-bench` にも含まれているので、ベンチ前なら個別に実行しなくてよい。
逆にサーバー側の設定を手元に取り直したいときは `make get-conf`。

### 様子がおかしい

```bash
make status                       # 全サーバーのサービス起動状態
make logs                         # アプリの journal(直前の prepare-bench 以降。未実行なら直近 30 分)
make logs SINCE=-10min            # 期間を指定
make logs UNITS=nginx.service HOST=10.97.0.12   # 対象ユニットやサーバーを指定
make ssh HOST=10.97.0.12          # どうしても直接入りたいとき
```

### DB の中身を見たい

```bash
make mysql                               # DB サーバーの MySQL に対話接続(認証情報はサーバー上の env.sh から)
make mysql Q="SHOW INDEX FROM rides"     # 1 クエリだけ実行して戻る
make mysql Q="SELECT COUNT(*) FROM chairs" HOST=10.97.0.13
```

`EXPLAIN` でインデックスの効きを見るときや、`ALTER TABLE ... ADD INDEX` を直接流すときに使う。
手で足したインデックスは [webapp/sql/](webapp/sql/) の初期化 SQL にも必ず反映する(`/api/initialize` で DB が作り直されるため)。

再起動に失敗したときは、失敗したユニットの journal 直近 50 行が自動で表示される。

### サーバーの再起動だけしたい

```bash
make restart          # 全部
make restart-app      # アプリ(isuride-ruby / isuride-matcher)だけ
make restart-nginx
make restart-mysql
```

### memcached を使いたくなった

```bash
make install-memcached   # サーバーに memcached を入れて起動(デフォルト 11211 ポート)
```

これはサーバー側のデーモンを入れるだけ。Ruby から使うにはクライアントの gem も必要なので、[webapp/ruby/Gemfile](webapp/ruby/Gemfile) に `gem 'dalli'` を追加して `make release` で反映する(deploy 時に `bundle install` が走る)。

### 最終提出の前

計測のために入れたものはスコアを落とすので、最後の計測が終わったら全部外す。

- **MySQL**: `conf/mysqld.cnf` の `slow_query_log=0` にする(または 3 行を消す)。
- **nginx**: `conf/nginx/nginx.conf` の `access_log off;` にする。
- **Sinatra のリクエストログ**: [webapp/ruby/lib/isuride/base_handler.rb](webapp/ruby/lib/isuride/base_handler.rb) の `enable :logging` を `disable :logging` にする。1 リクエストごとに標準エラーへ 1 行書いていて、journal への書き込みがそのままコストになる。
- **デバッグ出力**: 当日足した `puts` / `pp` / `logger.info` を消す。
- **rbspy**: 最後のベンチは `RBSPY_UNITS=` を付けて回す。

反映と確認の手順:

```bash
make release RBSPY_UNITS=            # 上の変更を push して deploy
make prepare-bench RBSPY_UNITS=      # 設定反映 + 再起動 + rbspy なし
# 最後のベンチを回す
make status                          # 全サービスが active なこと
```

最後に、サーバーを再起動しても動くことを確認する(本番は再起動後の状態で採点されることが多い)。`make ssh` で入って `sudo reboot` し、戻ってきたら `make status` で全部 `active` なことと、ベンチがもう一度通ることを見る。`systemctl enable` されていないサービスや、起動順の問題はここで見つかる。

## 変数の渡し方

[isu.sh](isu.sh) 先頭の設定はすべて `make <コマンド> VAR=value` で一時的に上書きできる。よく使うもの:

| 変数 | 用途 | 例 |
| --- | --- | --- |
| `RBSPY_UNITS` | rbspy を仕掛けるユニット。空でスキップ | `RBSPY_UNITS=` / `RBSPY_UNITS="isuride-ruby.service isuride-matcher.service"` |
| `SINCE` | journal の取得開始時刻 | `SINCE=-10min` / `SINCE="2026-10-30 12:00:00"` |
| `HOST` | `ssh` / `logs` / `install-memcached` の対象 | `HOST=10.97.0.13` |
| `FORCE` | deploy でサーバー側の変更を破棄 | `FORCE=1` |
| `RUBY_BIN` | bundle が見つからないときの Ruby の bin | `RUBY_BIN=/home/isucon/local/ruby/bin` |
| `RUN_ID` | after-bench の対象を明示(通常は不要) | `RUN_ID=20261030_153012` |

## コマンドを追加するとき

1. [isu.sh](isu.sh) に `cmd_名前() { ## 説明` の形で関数を書く(`##` 以降が `make help` に出る)。
2. [Makefile](Makefile) の `TARGETS` に名前を足す。
