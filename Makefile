# ===== 当日に問題に合わせて書き換える =====
APP_DIR     ?= $(HOME)/webapp/go
APP_BIN     ?= isucon
APP_SERVICE ?= isu-go.service
# ==========================================

SERVER_ID ?= $(shell cat $(HOME)/.server_id 2>/dev/null)
NGINX_LOG := /var/log/nginx/access.log
SLOW_LOG  := /var/log/mysql/mysql-slow.log
SERVICES  := nginx mysql $(APP_SERVICE)

.PHONY: setup get-conf deploy deploy-conf build restart bench-prep analyze alp slow pprof notify score

setup: ## 各サーバーで1回: make setup SERVER_ID=s1
	./setup.sh $(SERVER_ID)

get-conf: ## サーバーの /etc 設定を repo に取り込む
	@test -n "$(SERVER_ID)" || (echo "SERVER_ID 未設定"; exit 1)
	mkdir -p $(SERVER_ID)/etc
	for d in nginx mysql; do [ -d /etc/$$d ] && sudo cp -r /etc/$$d $(SERVER_ID)/etc/ || true; done
	sudo chown -R $(USER):$(USER) $(SERVER_ID)

deploy: ## pull → 設定反映 → ビルド → 再起動 → ログを空に
	git pull
	$(MAKE) deploy-conf build restart bench-prep

deploy-conf:
	@test -n "$(SERVER_ID)" || (echo "SERVER_ID 未設定"; exit 1)
	set -e; for d in nginx mysql sysctl.d systemd; do \
	  if [ -d $(SERVER_ID)/etc/$$d ]; then sudo cp -r $(SERVER_ID)/etc/$$d/. /etc/$$d/; fi; done
	if [ -d $(SERVER_ID)/etc/sysctl.d ]; then sudo sysctl --system >/dev/null; fi
	sudo systemctl daemon-reload

build:
	cd $(APP_DIR) && go build -o $(APP_BIN)

restart: ## enabled なサービスだけ再起動 (DB専用機ではアプリを disable しておく)
	if systemctl is-enabled nginx >/dev/null 2>&1; then sudo nginx -t; fi
	set -e; for s in $(SERVICES); do \
	  if systemctl is-enabled $$s >/dev/null 2>&1; then sudo systemctl restart $$s; fi; done

bench-prep: ## ベンチ前にログを空にする
	sudo truncate -s 0 $(NGINX_LOG) $(SLOW_LOG) 2>/dev/null || true

analyze: alp slow ## ベンチ後: 集計を /tmp に出して通知
	$(MAKE) notify

alp:
	sudo alp json --file $(NGINX_LOG) --config alp.yml | tee /tmp/alp.txt

slow:
	sudo pt-query-digest $(SLOW_LOG) > /tmp/slow.txt; head -n 120 /tmp/slow.txt

pprof: ## ベンチ開始直前に実行 → ブラウザで :1080 (ssh -L 1080:localhost:1080)
	go tool pprof -http=0.0.0.0:1080 "http://localhost:6060/debug/pprof/profile?seconds=60"

notify: ## DISCORD_WEBHOOK を環境変数で渡す (repo にコミットしない)
	@[ -n "$$DISCORD_WEBHOOK" ] || { echo "DISCORD_WEBHOOK 未設定、通知スキップ"; exit 0; }; \
	curl -s -F "content=$(SERVER_ID) $$(git log -1 --format='%h %s')" \
	  $$( [ -f /tmp/alp.txt ] && echo -F file1=@/tmp/alp.txt ) \
	  $$( [ -f /tmp/slow.txt ] && echo -F file2=@/tmp/slow.txt ) \
	  "$$DISCORD_WEBHOOK" >/dev/null

score: ## make score S=12345 [M="メモ"] → scores.md に記録してコミット
	@test -n "$(S)" || (echo "S=スコア を指定"; exit 1)
	echo "| $$(date +%H:%M) | $(S) | $$(git log -1 --format='%h %s') | $(M) |" >> scores.md
	git add scores.md && git commit -qm "score $(S)" && git push -q
