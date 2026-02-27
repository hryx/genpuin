PREFIX  ?= /usr/local
LUA     ?= lua
LUA_VER := $(shell $(LUA) -e "print((_VERSION or ''):match('%d+%.%d+') or '5.4')")
LUA_DIR  = $(PREFIX)/share/lua/$(LUA_VER)
BIN_DIR  = $(PREFIX)/bin

EXAMPLES = $(wildcard examples/*.lua)

.PHONY: install uninstall examples

install:
	mkdir -p $(BIN_DIR)
	mkdir -p $(LUA_DIR)/genpuin
	sed '1s|.*|#!/usr/bin/env $(notdir $(LUA))|' bin/genpuin > $(BIN_DIR)/genpuin
	chmod +x $(BIN_DIR)/genpuin
	cp genpuin/*.lua $(LUA_DIR)/genpuin/

uninstall:
	rm -f $(BIN_DIR)/genpuin
	rm -rf $(LUA_DIR)/genpuin

examples:
	@mkdir -p out/svg out/ppm
	@for f in $(EXAMPLES); do \
		name=$$(basename $$f .lua); \
		echo "$$name"; \
		$(LUA) bin/genpuin $$f -o out/svg/$$name.svg; \
		$(LUA) bin/genpuin $$f -o out/ppm/$$name.ppm; \
	done
