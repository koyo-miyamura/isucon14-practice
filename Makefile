# 入口だけを並べた Makefile。処理の中身は isu.sh を参照。
# make <TAB> でターゲット補完が効くこと、make の手癖で使えることが目的。
# コマンドを足したら isu.sh の cmd_xxx と、ここの一覧の両方に名前を追加する。
#
#   初回:            make ping && make install-tools && make init
#   ベンチのたび:    make prepare-bench  ->  ベンチ実行  ->  make after-bench
#   コード反映:      make release        (= push + deploy)
#   状況確認:        make status / make logs SINCE=-10min / make ssh HOST=10.97.0.12
#
# 変数は make の引数で渡せばそのまま isu.sh に環境変数として届く。例:
#   make prepare-bench RBSPY_UNITS=
#   make deploy FORCE=1 RUBY_BIN=/home/isucon/local/ruby/bin

.DEFAULT_GOAL := help

TARGETS := help ping init install-tools install-memcached \
	get-conf get-nginxconf get-mysqlconf set-conf set-nginxconf set-mysqlconf \
	restart restart-app restart-nginx restart-mysql cleanlog status logs ssh mysql \
	new-run rbspy-start rbspy-stop prepare-bench after-bench \
	collect-logs analyze fetch-logs show-result \
	deploy push release

.PHONY: $(TARGETS)
$(TARGETS):
	@./isu.sh $@
