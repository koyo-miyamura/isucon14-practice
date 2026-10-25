# Ruby アプリの発行 SQL と推奨インデックス

## 対象と前提

- 対象は [lib/isuride](lib/isuride) の Ruby 実装が直接発行する SQL。重複する SQL はまとめ、SQL 内の `?` はバインド値を表す。
- 既存索引は [../sql/1-schema.sql](../sql/1-schema.sql) を基準とする。稼働 DB に手動追加された索引は未確認。
- 以下はコードとスキーマに基づく提案であり、実 DB の実行計画・レイテンシ・ベンチマークは未測定。DDL はこのドキュメントに記載するだけで、適用していない。
- 「優先」は最初に検証する候補、「条件付き」は計測で必要性を確認してから追加する候補。すべてを無条件に追加する意味ではない。
- 索引は主に検索対象とソート量を減らすもの。N+1、全件集計、外部決済待ち、配車の競合制御は別途対応が必要。

## 既存インデックス

全テーブルに以下の主キーがある。

| テーブル | PRIMARY KEY | その他の UNIQUE |
| --- | --- | --- |
| settings | `(name)` | なし |
| chair_models | `(name)` | なし |
| chairs | `(id)` | なし |
| chair_locations | `(id)` | なし |
| users | `(id)` | `(username)`, `(access_token)`, `(invitation_code)` |
| payment_tokens | `(user_id)` | なし |
| rides | `(id)` | なし |
| ride_statuses | `(id)` | なし |
| owners | `(id)` | `(name)`, `(access_token)`, `(chair_register_token)` |
| coupons | `(user_id, code)` | なし |

特に、`chairs.access_token` は `users`・`owners` と異なり、既存の索引がない。

## 発行 SQL 一覧

### 1. 認証・共通処理

出典: [app_handler.rb](lib/isuride/app_handler.rb)、[chair_handler.rb](lib/isuride/chair_handler.rb)、[owner_handler.rb](lib/isuride/owner_handler.rb)、[base_handler.rb](lib/isuride/base_handler.rb)。

```sql
-- 利用者 Cookie の照合: 既存 UNIQUE(access_token)
SELECT * FROM users WHERE access_token = ?;

-- 椅子 Cookie の照合: 追加候補 A1
SELECT * FROM chairs WHERE access_token = ?;

-- オーナー Cookie の照合: 既存 UNIQUE(access_token)
SELECT * FROM owners WHERE access_token = ?;

-- 椅子登録時のオーナー照合: 既存 UNIQUE(chair_register_token)
SELECT * FROM owners WHERE chair_register_token = ?;

-- 最新状態: 追加候補 A5
SELECT status FROM ride_statuses WHERE ride_id = ? ORDER BY created_at DESC LIMIT 1;

-- db_transaction が発行する制御文。例外時は ROLLBACK
BEGIN;
COMMIT;
ROLLBACK;
```

### 2. 利用者登録・招待・支払い方法

出典: [app_handler.rb](lib/isuride/app_handler.rb)。`POST /api/app/users`、`POST /api/app/payment-methods`。

```sql
INSERT INTO users (id, username, firstname, lastname, date_of_birth, access_token, invitation_code) VALUES (?, ?, ?, ?, ?, ?, ?);

-- 初回・招待クーポンは同じ SQL。初回は code=CP_NEW2024, discount=3000
INSERT INTO coupons (user_id, code, discount) VALUES (?, ?, ?);

-- 招待コード利用人数の確認: 追加候補 A7
SELECT * FROM coupons WHERE code = ? FOR UPDATE;

-- 招待元の確認: 既存 UNIQUE(invitation_code)
SELECT * FROM users WHERE invitation_code = ?;

-- 招待者への報酬クーポン
INSERT INTO coupons (user_id, code, discount) VALUES (?, CONCAT(?, '_', FLOOR(UNIX_TIMESTAMP(NOW(3))*1000)), ?);

INSERT INTO payment_tokens (user_id, token) VALUES (?, ?);
```

### 3. ライド作成・クーポン確保

出典: [app_handler.rb](lib/isuride/app_handler.rb)。`POST /api/app/rides`。

```sql
-- 未完了ライドの確認。取得した各ライドで共通の最新状態 SQL も発行: A2
SELECT * FROM rides WHERE user_id = ?;

INSERT INTO rides (id, user_id, pickup_latitude, pickup_longitude, destination_latitude, destination_longitude) VALUES (?, ?, ?, ?, ?, ?);

-- MATCHING など、各状態の追加で共用
INSERT INTO ride_statuses (id, ride_id, status) VALUES (?, ?, ?);

-- 初回利用の判定: A2 の左端 user_id を利用可能
SELECT COUNT(*) FROM rides WHERE user_id = ?;

-- 既存 PRIMARY KEY(user_id, code) で最大 1 行に絞れる
SELECT * FROM coupons WHERE user_id = ? AND code = 'CP_NEW2024' AND used_by IS NULL FOR UPDATE;

-- 未使用クーポンを古い順に確保: A9
SELECT * FROM coupons WHERE user_id = ? AND used_by IS NULL ORDER BY created_at LIMIT 1 FOR UPDATE;

-- どちらも既存 PRIMARY KEY(user_id, code)
UPDATE coupons SET used_by = ? WHERE user_id = ? AND code = ?;
UPDATE coupons SET used_by = ? WHERE user_id = ? AND code = 'CP_NEW2024';

-- 作成後の再取得、評価処理でも使用: 既存 PRIMARY KEY(id)
SELECT * FROM rides WHERE id = ?;
```

### 4. 見積もり・割引計算

出典: [app_handler.rb](lib/isuride/app_handler.rb) の `calculate_discounted_fare`。
`POST /api/app/rides/estimated-fare`、配車作成、履歴、通知、評価処理から呼ばれる。

```sql
-- ライドに紐づく使用済みクーポン: A8
SELECT * FROM coupons WHERE used_by = ?;

-- 見積もり時の初回クーポン: 既存 PRIMARY KEY(user_id, code)
SELECT * FROM coupons WHERE user_id = ? AND code = 'CP_NEW2024' AND used_by IS NULL;

-- 見積もり時の未使用クーポン: A9
SELECT * FROM coupons WHERE user_id = ? AND used_by IS NULL ORDER BY created_at LIMIT 1;
```

### 5. 履歴・評価・決済

出典: [app_handler.rb](lib/isuride/app_handler.rb)。`GET /api/app/rides`、`POST /api/app/rides/:ride_id/evaluation`。

```sql
-- 履歴一覧: A2
SELECT * FROM rides WHERE user_id = ? ORDER BY created_at DESC;

-- 履歴などで椅子・オーナーを取得: 既存 PRIMARY KEY(id)
SELECT * FROM chairs WHERE id = ?;
SELECT * FROM owners WHERE id = ?;

-- 評価保存: 既存 PRIMARY KEY(id)
UPDATE rides SET evaluation = ? WHERE id = ?;

-- 決済準備: 既存 PRIMARY KEY(user_id), PRIMARY KEY(name)
SELECT * FROM payment_tokens WHERE user_id = ?;
SELECT value FROM settings WHERE name = 'payment_gateway_url';

-- 決済 POST が非 204 の場合に、決済件数との照合用に取得: A2
SELECT * FROM rides WHERE user_id = ? ORDER BY created_at ASC;
```

このほか、一覧の各ライドで最新状態・割引計算・椅子・オーナーの SQL を発行する。
評価時はライド再取得と `COMPLETED` の履歴 INSERT も行う。これらは前項までの SQL と同形。
[payment_gateway.rb](lib/isuride/payment_gateway.rb) 自体は HTTP クライアントであり、SQL は渡されたコールバックが実行する。

### 6. 利用者通知・椅子の評価統計

出典: [app_handler.rb](lib/isuride/app_handler.rb)。`GET /api/app/notification`、`get_chair_stats`。

```sql
-- 利用者の最新ライド: A2
SELECT * FROM rides WHERE user_id = ? ORDER BY created_at DESC LIMIT 1;

-- 未通知状態を古い順に 1 件: まず A5、必要なら B1
SELECT * FROM ride_statuses WHERE ride_id = ? AND app_sent_at IS NULL ORDER BY created_at ASC LIMIT 1;

-- 既存 PRIMARY KEY(id)
UPDATE ride_statuses SET app_sent_at = CURRENT_TIMESTAMP(6) WHERE id = ?;

-- 椅子のライド履歴: A4
SELECT * FROM rides WHERE chair_id = ? ORDER BY updated_at DESC;

-- 各ライドの状態履歴: A5
SELECT * FROM ride_statuses WHERE ride_id = ? ORDER BY created_at;
```

割当済みなら椅子の主キー検索と評価統計を実行し、料金計算も行う。
通知は `retry_after_ms: 30` を返すポーリングなので、軽い SQL でも実行頻度に注意する。

### 7. 近隣椅子

出典: [app_handler.rb](lib/isuride/app_handler.rb)。`GET /api/app/nearby-chairs`。

```sql
-- 現行コードは全椅子を読み、Ruby 側で is_active を判定
SELECT * FROM chairs;

-- 椅子ごとの最新ライド: A3
SELECT * FROM rides WHERE chair_id = ? ORDER BY created_at DESC LIMIT 1;

-- 椅子ごとの最新位置: A6
SELECT * FROM chair_locations WHERE chair_id = ? ORDER BY created_at DESC LIMIT 1;

SELECT CURRENT_TIMESTAMP(6);
```

各椅子の最新状態も共通 SQL で調べる。座標の距離判定は Ruby 側で実行するため、現行 SQL のまま緯度・経度へ索引を追加しても距離検索には使われない。

### 8. 椅子登録・稼働・座標・通知・状態更新

出典: [chair_handler.rb](lib/isuride/chair_handler.rb)。`/api/chair/*`。

```sql
INSERT INTO chairs (id, owner_id, name, model, is_active, access_token) VALUES (?, ?, ?, ?, ?, ?);

-- 既存 PRIMARY KEY(id)
UPDATE chairs SET is_active = ? WHERE id = ?;

INSERT INTO chair_locations (id, chair_id, latitude, longitude) VALUES (?, ?, ?, ?);

-- 挿入した座標行の再取得: 既存 PRIMARY KEY(id)
SELECT * FROM chair_locations WHERE id = ?;

-- 座標送信・椅子通知で使う最新ライド: A4
SELECT * FROM rides WHERE chair_id = ? ORDER BY updated_at DESC LIMIT 1;

-- 未通知状態: まず A5、必要なら B2
SELECT * FROM ride_statuses WHERE ride_id = ? AND chair_sent_at IS NULL ORDER BY created_at ASC LIMIT 1;

-- 通知に載せる利用者: 既存 PRIMARY KEY(id)
SELECT * FROM users WHERE id = ? FOR SHARE;

-- 通知済み更新: 既存 PRIMARY KEY(id)
UPDATE ride_statuses SET chair_sent_at = CURRENT_TIMESTAMP(6) WHERE id = ?;

-- 椅子からの状態変更時にライドをロック: 既存 PRIMARY KEY(id)
SELECT * FROM rides WHERE id = ? FOR UPDATE;
```

迎車地点・目的地への座標一致や椅子の報告に応じ、共通の状態 INSERT で `PICKUP`、`ARRIVED`、`ENROUTE`、`CARRYING` を追加する。

### 9. 内部マッチング

出典: [internal_handler.rb](lib/isuride/internal_handler.rb)。`GET /api/internal/matching`。

```sql
-- 最も古い未割当ライド: A3 の chair_id=NULL の範囲を利用可能
SELECT * FROM rides WHERE chair_id IS NULL ORDER BY created_at LIMIT 1;

-- 受付中の椅子からランダムに選択: B4 は抽出対象を減らす候補に留まる
SELECT * FROM chairs INNER JOIN (SELECT id FROM chairs WHERE is_active = TRUE ORDER BY RAND() LIMIT 1) AS tmp ON chairs.id = tmp.id LIMIT 1;

-- 過去ライドがすべて椅子向けに 6 件通知済みなら空きと判定
-- rides 側は A3/A4、ride_statuses 側は A5 または B2
SELECT COUNT(*) = 0 FROM (SELECT COUNT(chair_sent_at) = 6 AS completed FROM ride_statuses WHERE ride_id IN (SELECT id FROM rides WHERE chair_id = ?) GROUP BY ride_id) is_completed WHERE completed = FALSE;

-- 既存 PRIMARY KEY(id)
UPDATE rides SET chair_id = ? WHERE id = ?;
```

候補探索は最大 10 回。`COUNT(chair_sent_at)` は NULL を数えない点に注意。
ランダムソートと空き判定の再集計は、索引追加だけではなくならない。

### 10. オーナー登録・売上・椅子一覧

出典: [owner_handler.rb](lib/isuride/owner_handler.rb)。`/api/owner/*`。

```sql
INSERT INTO owners (id, name, access_token, chair_register_token) VALUES (?, ?, ?, ?);

-- オーナーが保有する椅子: B3
SELECT * FROM chairs WHERE owner_id = ?;

-- 期間内の完了ライド。rides 側は A4、状態側は A5 または B5
SELECT rides.* FROM rides JOIN ride_statuses ON rides.id = ride_statuses.ride_id WHERE chair_id = ? AND status = 'COMPLETED' AND updated_at BETWEEN ? AND ? + INTERVAL 999 MICROSECOND;

-- 椅子一覧と位置履歴からの総移動距離
SELECT id,
owner_id,
name,
access_token,
model,
is_active,
created_at,
updated_at,
IFNULL(total_distance, 0) AS total_distance,
total_distance_updated_at
FROM chairs
LEFT JOIN (SELECT chair_id,
                   SUM(IFNULL(distance, 0)) AS total_distance,
                   MAX(created_at)          AS total_distance_updated_at
            FROM (SELECT chair_id,
                         created_at,
                         ABS(latitude - LAG(latitude) OVER (PARTITION BY chair_id ORDER BY created_at)) +
                         ABS(longitude - LAG(longitude) OVER (PARTITION BY chair_id ORDER BY created_at)) AS distance
                  FROM chair_locations) tmp
            GROUP BY chair_id) distance_table ON distance_table.chair_id = chairs.id
WHERE owner_id = ?;
```

椅子一覧の外側の絞り込みは B3、履歴の走査順は A6 が候補。ただし、派生表は全椅子の位置履歴を集計する構造であり、オーナーによる外側の絞り込みだけで履歴全走査が消えるとは限らない。
ウィンドウ関数のソートが A6 で省略されるかも実行計画で確認する。最終的には移動距離の差分集計・保持を検討する。

### 11. 初期化

出典: [initialize_handler.rb](lib/isuride/initialize_handler.rb)。`POST /api/initialize`。

```sql
-- 既存 PRIMARY KEY(name)
UPDATE settings SET value = ? WHERE name = 'payment_gateway_url';
```

この前に [../sql/init.sh](../sql/init.sh) を実行する。スクリプトはスキーマ、マスタ、圧縮初期データの順に MySQL へ投入するため、`DROP TABLE` / `CREATE TABLE` / データ投入 SQL も間接的に実行される。それらは通常リクエストの SQL 一覧には含めていない。`ENV=local-dev` ではスクリプトは処理せず終了する。

## 優先して検証するインデックス

索引名は本ドキュメントで提案する名前。すべて非 UNIQUE とし、既存のデータ制約は変えない。

| ID | テーブル・列 | 狙いと注意点 |
| --- | --- | --- |
| A1 | chairs `(access_token)` | 椅子 API の認証での全走査を避ける。UNIQUE 化は重複確認と仕様判断を別途行う。 |
| A2 | rides `(user_id, created_at)` | 利用者の全ライド、最新ライド、履歴、件数確認、決済照合。ASC / DESC は逆方向走査で共用できる。 |
| A3 | rides `(chair_id, created_at)` | 椅子の最新作成ライド、最古の未割当ライド。B-tree は NULL も保持するので `IS NULL` も対象。 |
| A4 | rides `(chair_id, updated_at)` | 椅子通知・座標送信・評価統計、売上期間検索。A3 とは並び替える列が異なる。更新ごとに索引保守が発生する。 |
| A5 | ride_statuses `(ride_id, created_at)` | 最新状態と時系列履歴。通知も対象ライドまで絞り込めるが、未通知条件は行を調べる。 |
| A6 | chair_locations `(chair_id, created_at)` | 最新位置の LIMIT 1。全履歴の距離集計自体は残る。座標 INSERT ごとのコストも測る。 |
| A7 | coupons `(code)` | 招待コード単独での利用人数確認。既存主キーの左端は user_id なので code 単独の検索には向かない。 |
| A8 | coupons `(used_by)` | ライドの使用クーポン取得。NULL の行も索引に含まれる。 |
| A9 | coupons `(user_id, used_by, created_at)` | 利用者と未使用条件で絞り、最古のクーポンを取得。PRIMARY KEY(user_id, code) とは用途が違う。 |

```sql
-- 適用前に同等索引がないことを確認する。実行例であり自動適用はしない。
ALTER TABLE chairs
  ADD INDEX idx_chairs_access_token (access_token);

ALTER TABLE rides
  ADD INDEX idx_rides_user_created (user_id, created_at),
  ADD INDEX idx_rides_chair_created (chair_id, created_at),
  ADD INDEX idx_rides_chair_updated (chair_id, updated_at);

ALTER TABLE ride_statuses
  ADD INDEX idx_ride_statuses_ride_created (ride_id, created_at);

ALTER TABLE chair_locations
  ADD INDEX idx_chair_locations_chair_created (chair_id, created_at);

ALTER TABLE coupons
  ADD INDEX idx_coupons_code (code),
  ADD INDEX idx_coupons_used_by (used_by),
  ADD INDEX idx_coupons_user_unused_created (user_id, used_by, created_at);
```

## 計測後に判断するインデックス

| ID | テーブル・列 | 採用判断 |
| --- | --- | --- |
| B1 | ride_statuses `(ride_id, app_sent_at, created_at)` | 利用者の未通知取得向け。通常の状態履歴は 1 ライド約 6 行なので、A5 だけで十分な可能性がある。通知済み更新で索引の更新も必要。 |
| B2 | ride_statuses `(ride_id, chair_sent_at, created_at)` | 椅子の未通知取得向け。内部マッチングの COUNT では必要列を覆える候補。B1 と同様、読取改善と更新コストを比較する。 |
| B3 | chairs `(owner_id)` | オーナーの椅子一覧・売上処理。椅子数やオーナー API の負荷が大きければ優先度を上げる。 |
| B4 | chairs `(is_active)` | ランダム選択の受付中候補を絞る。受付中が大半なら効果は小さく、`ORDER BY RAND()` は解消しない。 |
| B5 | ride_statuses `(ride_id, status)` | 椅子・期間で rides を先に絞る売上 JOIN の候補。通常は 1 ライドの状態数が少ないため A5 と比較して判断。 |

```sql
-- 必要と判断したものだけ追加する。
ALTER TABLE ride_statuses
  ADD INDEX idx_ride_statuses_app_pending (ride_id, app_sent_at, created_at),
  ADD INDEX idx_ride_statuses_chair_pending (ride_id, chair_sent_at, created_at);

ALTER TABLE chairs
  ADD INDEX idx_chairs_owner (owner_id),
  ADD INDEX idx_chairs_active (is_active);

ALTER TABLE ride_statuses
  ADD INDEX idx_ride_statuses_ride_status (ride_id, status);
```

売上 JOIN が `ride_statuses` を起点にする場合は `(status, ride_id)` も比較候補。ただし `COMPLETED` は件数が増えやすく、status 起点が有利とは限らない。B5 と列順違いの索引を両方追加するのではなく、実データの選択率と JOIN 順序で判断する。

## 追加不要・索引だけでは解決しないもの

- `WHERE id = ?` は各テーブルの主キーで処理できる。`FOR UPDATE` / `FOR SHARE` のためだけに別索引は要らない。
- 利用者・オーナーの access_token、招待コード、オーナーの椅子登録トークンは既存 UNIQUE で検索できる。
- 初回クーポンの `(user_id, code)`、決済トークンの user_id、settings の name は既存主キーで十分。
- A2 があれば単独 `(user_id)`、A3/A4 があれば単独 `(chair_id)` を rides に重ねて追加する必要は通常ない。複合索引の左端を利用できる。
- `chair_models` は Ruby の通常処理から直接 SELECT されていない。今回の対象 SQL のための追加索引は不要。
- `SELECT * FROM chairs` は全件取得なので、is_active 索引だけ追加しても改善しない。DB 側で受付中を絞るなら SQL の変更が必要。
- 緯度・経度の索引は、Ruby 側のマンハッタン距離判定をそのまま高速化しない。
- `SELECT *` を多数使っているため、一般的な複合索引を追加しても全列を覆うカバリング索引になるわけではない。
- N+1 を減らすにはまとめ取得・JOIN・状態や統計の保持などを検討する。各 SQL が速くなっても往復回数は残る。
- マッチングの二重割り当てや招待上限の同時実行時の正しさは、索引だけで保証しない。トランザクション・ロック範囲・条件付き更新を別途検証する。
- 同じ created_at / updated_at の行があると、時刻だけの ORDER BY は順序が一意でない。索引追加で選ばれる行が変わり得るため、必要なら仕様を確認してタイブレークを設計する。

## 適用・検証手順

1. 対象 DB の MySQL バージョンと `SHOW INDEX FROM テーブル名` で既存索引を確認する。名前が違っても同じ列構成の索引は重複追加しない。
2. ベンチマークで SQL の実行回数・合計時間・返却行数を測り、認証、最新ライド、最新状態、最新位置など実際に負荷の高い経路から検証する。
3. 代表値を入れた SELECT に `EXPLAIN` を実行する。利用可能なら検証環境で `EXPLAIN ANALYZE` を使い、実走査行数・ソート・JOIN 順序・実時間を比較する。
4. 候補を小さな単位で追加し、読取改善だけでなく座標 INSERT、状態 INSERT、通知済み UPDATE、ライド割当・更新の遅延とロック待ちも比較する。
5. 初期化後も必要なら [../sql/1-schema.sql](../sql/1-schema.sql) の CREATE TABLE に採用した索引を反映する。通常の初期化はテーブルを作り直すため、手動 ALTER だけでは消える。DDL の配置と初期データ投入時間も確認する。

```sql
-- ベンチマーク用 DB / 検証環境での例。実データに存在する値へ置換する。
SHOW INDEX FROM rides;
SHOW INDEX FROM ride_statuses;

EXPLAIN SELECT * FROM rides
WHERE user_id = '実在する利用者ID'
ORDER BY created_at DESC LIMIT 1;

EXPLAIN SELECT status FROM ride_statuses
WHERE ride_id = '実在するライドID'
ORDER BY created_at DESC LIMIT 1;

EXPLAIN SELECT * FROM ride_statuses
WHERE ride_id = '実在するライドID' AND app_sent_at IS NULL
ORDER BY created_at ASC LIMIT 1;

EXPLAIN SELECT * FROM chair_locations
WHERE chair_id = '実在する椅子ID'
ORDER BY created_at DESC LIMIT 1;
```

`EXPLAIN ANALYZE` は対象文を実行する。特に更新文やロック付き SELECT に対して、本番相当の共有 DB で気軽に試さない。索引構築時のロック・ディスク使用量・実行時間も確認する。