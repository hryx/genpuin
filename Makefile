PREFIX ?= /usr/local
LUA_DIR = $(PREFIX)/share/lua/5.4
BIN_DIR = $(PREFIX)/bin

.PHONY: install uninstall

install:
	mkdir -p $(BIN_DIR)
	mkdir -p $(LUA_DIR)/genpuin
	cp bin/genpuin $(BIN_DIR)/genpuin
	chmod +x $(BIN_DIR)/genpuin
	cp genpuin/*.lua $(LUA_DIR)/genpuin/

uninstall:
	rm -f $(BIN_DIR)/genpuin
	rm -rf $(LUA_DIR)/genpuin
