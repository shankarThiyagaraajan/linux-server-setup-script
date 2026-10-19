.PHONY: all build lint test clean

all: lint test build

build:
	tools/build.sh

lint:
	shellcheck -x -S warning bin/server-setup lib/*.sh lib/modules/*.sh tools/*.sh

test:
	bats tests

clean:
	rm -rf dist
