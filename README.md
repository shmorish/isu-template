# isucon-template

ISUCON 当日用テンプレート。repo は各サーバーの `/home/isucon` に置き、`.gitignore` のホワイトリストで必要なものだけ追跡する。

```
Taskfile.yml      deploy / analyze / score などの当日コマンド (task --list で一覧)
setup.sh          各サーバーで1回だけ実行 (alp, slp, pt-query-digest, task 等の導入)
ssh-hosts.sh      手元の Mac で実行。当日のIPを渡すと ~/.ssh/config に s1〜s3 を書く
collect.sh        サーバーの状況 (スペック・サービス・nginx 設定・テーブル定義) を s1/collect.md にまとめる
alp.yml           alp の設定。当日 matching_groups を書く
s1/ s2/ s3/       サーバー別 /etc 設定 (task get-conf で取り込む)
snippets/         nginx / MySQL / sysctl / Go のコピペ部品
```

## 事前準備
1. このテンプレートから private repo を作る
2. 各サーバーから GitHub に push できる手段を決める (`ssh -A` でエージェント転送、または deploy key)
3. Discord の Webhook を用意する (**repo にはコミットしない**。当日 `export DISCORD_WEBHOOK=...`)
4. private-isu や過去問で、下の「当日の手順」を通しで練習する

## 当日の手順

最初の計測（10:45頃）までの詳しい手順と確認コマンドは [docs/first-hour.md](docs/first-hour.md) を参照。

### 1台目 (s1)
```bash
cd ~ && git init -b main && git remote add origin git@github.com:<you>/<repo>.git && git pull origin main
./setup.sh s1
task get-conf                    # /etc/nginx, /etc/mysql を s1/etc に取り込む
task collect                     # s1/collect.md にサーバーの状況をまとめる
vi Taskfile.yml                  # APP_DIR / APP_BIN / APP_SERVICE を問題に合わせる
vi .gitignore                    # ビルド成果物と巨大ファイルを追記
git add -A && git commit -m init && git push -u origin main
mysqldump -uisucon -p --all-databases | gzip > ~/backup.sql.gz   # 壊したとき用
```

### 2台目以降 (s2, s3)
```bash
cd ~ && git init -b main && git remote add origin git@github.com:<you>/<repo>.git && git fetch && git reset --hard origin/main && git branch -u origin/main
./setup.sh s2 && task get-conf && task collect && git add s2 && git commit -m "s2 conf" && git push
```

### 計測を入れる (最初の30分)
- `snippets/nginx.conf` の JSON ログを `s1/etc/nginx/nginx.conf` に入れる
- `snippets/mysql-isu.cnf` を `s1/etc/mysql/mysql.conf.d/zz-isu.cnf` として置く
- アプリの main で `StartPprof()` を呼ぶ (`snippets/go/pprof.go`)
- `task deploy` → ベンチ → `task analyze`

### ループ
```
変更を1つ → push → (対象サーバーで) task deploy → ベンチ → task analyze → task score S=<点数> M="何をしたか"
```
スコアが下がったら原因を探さず `git revert`。

### 終盤 (残り1時間)
- `access_log off;`、`slow_query_log = 0`、`NO_PPROF=1`、アプリのロガー停止
- `mysql-isu.cnf` の耐久性設定が入っていることを確認
- 全台再起動 → ベンチが通るか確認 → **ブラウザで画面を確認**
- 残り30分でコード凍結

## Go スニペット (`snippets/go/`)
アプリに**ファイルごとコピー**して package 名を合わせる。

| ファイル | 中身 |
|---|---|
| db.go | `interpolateParams`・コネクションプール設定済みの接続、bulk insert / IN 句の書き方 |
| cache.go | TTL 付きジェネリックキャッシュ + singleflight (同時ミスを1回のロードに) |
| id.go | 複数台で衝突しないアプリ側 ID 採番 (`SELECT MAX(id)` から再開) |
| pprof.go | pprof を :6060 で起動、`NO_PPROF=1` で無効 |

`cd snippets/go && go test -race ./...` でテストが通る (Go 1.22 以上の機能を使用)。
