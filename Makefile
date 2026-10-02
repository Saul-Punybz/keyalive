LABEL   := io.github.saul-punybz.keyalive
PREFIX  ?= $(HOME)/.local
BIN     := $(PREFIX)/bin/keyalive
AGENT   := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG     := $(HOME)/Library/Logs/keyalive.log
# Extra flags for the background agent, e.g. make install ARGS="--interval 45 --include-mice"
ARGS    ?=

.PHONY: build install uninstall status log clean

build: keyalive

keyalive: Sources/keyalive.swift Support/Info.plist
	swiftc -O Sources/keyalive.swift -o keyalive \
	  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Support/Info.plist
	codesign -s - -f --identifier $(LABEL) keyalive

install: build
	mkdir -p $(dir $(BIN)) $(dir $(AGENT))
	cp keyalive $(BIN)
	@args=""; for a in $(ARGS); do args="$$args<string>$$a</string>"; done; \
	sed -e "s|__BIN__|$(BIN)|" -e "s|__LOG__|$(LOG)|g" -e "s|__ARGS__|$$args|" \
	  Support/$(LABEL).plist > $(AGENT)
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENT)
	@echo "KeyAlive installed and running. Log: $(LOG)"
	@echo "If macOS asks for Bluetooth access for keyalive, click Allow."

uninstall:
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	rm -f $(AGENT) $(BIN)
	@echo "KeyAlive removed."

status:
	@launchctl print gui/$$(id -u)/$(LABEL) 2>/dev/null | grep -E "^\s+(state|pid|last exit code) =" || echo "not installed"

log:
	@tail -n 30 $(LOG)

clean:
	rm -f keyalive
