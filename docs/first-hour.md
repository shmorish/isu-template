# 最初の計測までの手順書（10:00〜10:45）

ゴールは「計測付きのベンチを1回回し、重いエンドポイントとクエリの上位5つをチームで共有する」ことです。
ここまではアプリの改善に手を出しません。

前提: 3人チーム、サーバー3台（s1〜s3）、当日用 private リポジトリ `git@github.com:<you>/<repo>.git`。
コードブロックのコマンドは、特に断りがなければ**競技サーバー上で**打ちます。

---

## 0. 前日までに手元で準備しておくもの

1. 鍵がなければ作る（`ssh-keygen -t ed25519`、質問は全部 Enter）
2. 公開鍵を GitHub に登録する（`pbcopy < ~/.ssh/id_ed25519.pub` → https://github.com/settings/keys に貼る）。https://github.com/<ユーザー名>.keys に表示されれば登録済み
3. 手元で `ssh -T git@github.com` を実行し、`Hi <ユーザー名>!` と出ることを確認する
4. Discord の Webhook URL を手元のメモに控えておく（リポジトリには書かない）

当日は、ポータルに出た IP を渡して `scripts/ssh-hosts.sh` を実行するだけで `~/.ssh/config` が用意されます。

```
./scripts/ssh-hosts.sh <s1のIP> <s2のIP> <s3のIP>
```

- `~/.ssh/config` の末尾に s1〜s3 の設定を書きます。2回目以降は前回の分を入れ替えます。既存の設定には触りません。
- 実行のたびに `~/.ssh/config.bak-isucon` にバックアップを取ります。
- エージェント転送（サーバー上の `git push` で手元の鍵を使う）、s1 の pprof 用ポート転送、接続の使い回しを設定します。
- ユーザー名が `isucon` 以外の回は `ISU_USER=ubuntu ./scripts/ssh-hosts.sh ...` のように指定します。
- `~/.ssh/config` を TextEdit で開いて編集しないでください。中身が消えて保存された例があります。

---

## 1. 10:00〜10:05　ログインと分担

| 担当 | 最初の15分 |
|---|---|
| A（インフラ） | この手順書の 2〜5 を進める |
| B（アプリ） | アプリのコード、テーブル定義（`webapp/sql/` など）、言語切り替え手順を読む |
| C（仕様） | マニュアルと規約を読み、スコア計算式・減点・反映の猶予・キャッシュの可否をメモして共有する |

Aは全台に入れることを確認します。

```
ssh s1
sudo -v
ssh -T git@github.com
```

`ssh -T git@github.com` で「Hi <ユーザー名>!」と出れば、エージェント転送が効いています。

---

## 2. 10:05〜10:10　サーバーの中身を確認する（A）

3台とも同じとは限りません。ISUCON10 では台ごとのスペック差に気付いたかどうかで差がつきました。

```
nproc; free -h; df -h /
cat /etc/os-release | head -2
systemctl list-units --type=service --state=running | grep -Ei 'isu|nginx|mysql|maria|redis|postgres|h2o|envoy'
sudo ss -tlnp
ls -la ~
```

確認してメモする項目:

- [ ] CPU コア数とメモリ（台ごと）
- [ ] 動いているアプリのサービス名（例: `isu-ruby.service`）と、Go 版のサービス名
- [ ] DB の種類とバージョン（`mysql --version`）。MariaDB なら設定の置き場所が `mariadb.conf.d/` になる
- [ ] リバースプロキシが nginx かどうか（h2o や envoy の回もある）
- [ ] アプリが listen しているポート（`ss -tlnp` の結果）

Go 版のサービスの中身を見て、Taskfile.yml に書く値を決めます。

```
systemctl cat isu-go.service
```

- `WorkingDirectory=` → Taskfile.yml の `APP_DIR`
- `ExecStart=` のバイナリ名 → `APP_BIN`
- `EnvironmentFile=` → DB のパスワードが書いてあるファイル（次の手順で使う）

---

## 3. 10:10〜10:20　s1 をリポジトリ管理にする（A）

まずホームに巨大なファイルがないか確認します。初期データの SQL や画像が数百MBあることがあります。

```
du -sh ~/* ~/webapp/* 2>/dev/null | sort -h | tail -15
```

テンプレートを取り込みます。

```
cd ~ && git init -b main && git remote add origin git@github.com:<you>/<repo>.git && git pull origin main
./scripts/setup.sh s1
task get-conf
task collect
```

- `./scripts/setup.sh s1` は alp・slp・pt-query-digest・task などを入れ、`~/.server_id` に `s1` を書きます。
- `task get-conf` は `/etc/nginx` と `/etc/mysql` を `s1/etc/` にコピーします。
- `task collect` は、スペック・サービス・ポート・nginx の実効設定・MySQL の主要変数・テーブルの件数と定義を `s1/collect.md` にまとめます。手順2で手で見た内容もここに入るので、Claude にはこのファイルを読ませます。パスワードらしき値は伏せ字になります。

Taskfile.yml の先頭3つの変数を、手順2で調べた値に書き換えます。

```
vi Taskfile.yml
```

`.gitignore` の末尾に、Go のバイナリ名と、手順3の `du` で見つけた巨大なファイルを足します。

```
vi .gitignore
git status --short | head -50
```

`git status` に巨大なファイルや不要なファイルが出ていないことを確認してから、コミットします。

```
git add -A && git commit -m init && git push -u origin main
```

ビルドできることも確かめます。

```
task build
```

最後に DB のバックアップを取ります。パスワードは `EnvironmentFile` に書いてあるものを使います。

```
mysqldump -uisucon -p --single-transaction --all-databases | gzip > ~/backup.sql.gz
```

**つまずきやすい所**

- `git pull origin main` が「untracked working tree files would be overwritten」で止まる: ホームに `README.md` などテンプレートと同じ名前のファイルがある。そのファイルを別名に退避してからやり直す。
- `git push` が Permission denied: エージェント転送が効いていない。手元で `ssh-add -l` に鍵が出るか確認する。

---

## 4. 10:15〜10:20　s2・s3 も同じ状態にする（A）

```
cd ~ && git init -b main && git remote add origin git@github.com:<you>/<repo>.git && git fetch && git reset --hard origin/main && git branch -u origin/main
./scripts/setup.sh s2 && task get-conf && task collect && git add s2 && git commit -m "s2 conf" && git push
```

s3 でも `s2` を `s3` に変えて同じことをします。
s2 と s3 の push が重なって失敗したときは、`git pull` してからもう一度 `git push` します。

---

## 5. 10:20〜10:25　初回ベンチ（A + B）

マニュアルの手順に従って、参照実装を Go に切り替えます。サービス名は手順2のメモを使います。

```
sudo systemctl disable --now isu-ruby.service
sudo systemctl enable --now isu-go.service
```

ブラウザでアプリのトップページが開けることを確認してから、ポータルでベンチを回します。
結果のスコアを記録します。

```
task score S=<点数> M="初期 Go"
```

---

## 6. 10:25〜10:35　計測を入れる（A）

ここで入れるのは計測だけです。MySQL の高速化設定などはまだ入れません。変化の原因が分からなくなるためです。

### 6-1. nginx のアクセスログを JSON にする

`s1/etc/nginx/nginx.conf` の `http {` の中に、`snippets/nginx.conf` の先頭にある `log_format json ...` と `access_log ... json;` の2つをコピーします。

既存の `access_log` が `nginx.conf` か `sites-enabled/` の中に残っていると、ログが二重に出ます（ISUCON13 の NaruseJun は、二重に出ていたログを終盤に止めて 277k から 468k に伸びました）。

```
grep -rn access_log s1/etc/nginx/
```

`json` 以外の `access_log` 行があれば、コメントアウトします。

### 6-2. MySQL のスロークエリログを全件出す

`snippets/mysql-isu.cnf` のうち、**`[mysqld]` と「計測中」の3行だけ**を `s1/etc/mysql/mysql.conf.d/zz-isu.cnf` として作ります。

```
mkdir -p s1/etc/mysql/mysql.conf.d
printf '[mysqld]\nslow_query_log = 1\nslow_query_log_file = /var/log/mysql/mysql-slow.log\nlong_query_time = 0\n' > s1/etc/mysql/mysql.conf.d/zz-isu.cnf
```

MariaDB の場合は、置き場所を `s1/etc/mysql/mariadb.conf.d/` に変えます。

### 6-3. アプリに pprof を入れる

`snippets/go/pprof.go` をアプリのディレクトリにコピーし、先頭の `package isuutil` を `package main` に書き換えます。
`main()` の最初の行に `StartPprof()` を足します。

```
cp snippets/go/pprof.go webapp/go/pprof.go
sed -i 's/^package isuutil/package main/' webapp/go/pprof.go
vi webapp/go/main.go
```

### 6-4. 反映して、計測が動いているか確かめる

```
git add -A && git commit -m "計測を入れる" && git push
task deploy
```

`task deploy` は、設定のコピー → ビルド → 再起動（nginx は先に `nginx -t` で文法チェック）→ ログを空にする、までを行います。

計測が動いているかを3つとも確認します。

```
curl -s -o /dev/null localhost/ ; sudo tail -1 /var/log/nginx/access.log
sudo mysql -e "SHOW VARIABLES LIKE 'slow_query_log%'; SHOW VARIABLES LIKE 'long_query_time';"
curl -s localhost:6060/debug/pprof/ | head -3
```

- アクセスログの最後の行が `{"time":...}` の JSON になっている
- `slow_query_log` が `ON`、`long_query_time` が `0.000000`
- pprof のページの HTML が返ってくる

**つまずきやすい所**

- `task deploy` が `nginx -t` で止まる: `log_format` を `http {` の外に書いている。
- MySQL が起動しない: `sudo journalctl -u mysql -n 30` で原因を見る。`/var/log/mysql` が無いか、権限が無いことが多い。
- pprof が返らない: `StartPprof()` を呼ぶ前に `main()` がブロックしている（`e.Start(...)` より前に書く）。

---

## 7. 10:35〜10:45　計測付きベンチと共有（A + 全員）

s1 で Discord の通知先を設定します（ログインするたびに必要）。

```
export DISCORD_WEBHOOK='https://discord.com/api/webhooks/...'
```

**ベンチの直前に**、別のターミナルで pprof の取得を始めます。60秒間 CPU プロファイルを取ります。

```
task pprof
```

ポータルでベンチを回し、終わったら集計します。

```
task analyze
task score S=<点数> M="計測あり"
```

`task analyze` は、alp・slp・pt-query-digest の結果をターミナルに出し、`/tmp/alp.txt`・`/tmp/slp.txt`・`/tmp/slow.txt` を Discord に送ります。
pprof の結果は、手元のブラウザで http://localhost:1080 を開くと見られます（`~/.ssh/config` の `LocalForward` を使う）。

### alp の集計を見やすくする

`/api/user/123` のように ID を含む URL が別々の行に分かれていたら、`scripts/alp.yml` の `matching_groups` に正規表現を書きます。
ログは次の `task deploy` まで残っているので、ベンチを回し直さずに集計だけやり直せます。

```
vi scripts/alp.yml
task alp
```

### 結果の読み方

- **alp**: `SUM`（合計時間）の大きい順に並んでいます。上から5つが改善の候補です。`COUNT` が多いのに `AVG` が小さいものは、キャッシュや静的配信の候補です。
- **slp**: クエリを合計時間の大きい順に1行ずつ並べた表です。まずここで上位5つを見ます。`AVG(ROWSEXAMINED)` が `AVG(ROWSSENT)` より桁違いに大きいクエリは、インデックスが効いておらず全件を読んでいる可能性が高いです。`COUNT` が異常に多いものは N+1 の可能性が高いです。
- **pt-query-digest**: slp で気になったクエリの詳細を見るときに使います。先頭の `Profile` 表の `Rank` から該当クエリを探すと、実際のクエリ例（そのまま `EXPLAIN` に使える）と対象テーブル名が載っています。
- **pprof**: `Top` 表示で、アプリの CPU を使っている関数を確認します。DB 待ちが長い場合は、ここではあまり目立ちません。

### チームで共有する（10:45）

3人で次の3点を確認し、担当を割り振ります。

1. alp の上位5エンドポイント
2. slp の上位5クエリと、それを呼んでいるエンドポイントの対応
3. C がマニュアルから見つけたスコア計算式と、使えそうな猶予・抜け道

ここから先は README の「ループ」の手順で改善を繰り返します。

---

## 10:45 時点のチェックリスト

- [ ] 3台ともリポジトリ管理になっていて、`task deploy` が通る
- [ ] DB のバックアップ（`~/backup.sql.gz`）がある
- [ ] Go 版でベンチが通り、初期スコアを `task score` で記録した（`~/scores.log` と Discord に残る）
- [ ] アクセスログが JSON で1本だけ出ている
- [ ] スロークエリログが全件出ている
- [ ] pprof が取れる
- [ ] `task analyze` の結果をチームで見て、担当を決めた
