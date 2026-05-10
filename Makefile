.PHONY: all compile test test-unit clips clean release run

all: clips compile

compile:
	rebar3 compile

clips:
	cd c_src && make

test: test-unit

test-unit:
	rebar3 as test eunit --dir=test/unit

clean:
	rebar3 clean
	cd c_src && make clean

release: clips
	rebar3 as prod release

run: all
	DB_USER=$${DB_USER:-shikun} erl -pa _build/default/lib/*/ebin \
		-noshell -eval '{ok,_}=application:ensure_all_started(ersub),ersub_migration:run(),receive after infinity -> ok end.'

dialyzer:
	rebar3 dialyzer

xref:
	rebar3 xref
