DAEMON_DIR := daemon
PLUGIN_MCP := plugin/mcp
BIN := $(DAEMON_DIR)/.build/release/memagent

.PHONY: build test install plugin status logs clean

build:
	cd $(DAEMON_DIR) && swift build -c release

test:
	cd $(DAEMON_DIR) && swift run selftest

install: build
	$(BIN) install

plugin:
	cd $(PLUGIN_MCP) && npm install --no-fund --no-audit
	@echo "Try it for one session:   claude --plugin-dir \"$(CURDIR)/plugin\""
	@echo "Install persistently:     /plugin marketplace add \"$(CURDIR)\""
	@echo "                          /plugin install mem-agent@mem-agent-local"

status:
	$(BIN) status || $(DAEMON_DIR)/.build/debug/memagent status

logs:
	$(BIN) logs -n 50

clean:
	cd $(DAEMON_DIR) && swift package clean
