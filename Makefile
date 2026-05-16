CC      ?= clang
SDK_PRIVATE := $(shell xcrun --show-sdk-path)/System/Library/PrivateFrameworks
CFLAGS  ?= -Wall -Wextra -Wno-unused-parameter -O2 -fmodules -fobjc-arc
LDLIBS   = -framework CoreDisplay \
           -framework IOKit \
           -framework CoreGraphics \
           -framework ApplicationServices \
           -framework Foundation \
           -F $(SDK_PRIVATE) -framework DisplayServices
PREFIX  ?= /usr/local

ddc-mirror: ddc-mirror.m
	$(CC) $(CFLAGS) $< $(LDLIBS) -o $@

install: ddc-mirror
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 ddc-mirror $(DESTDIR)$(PREFIX)/bin/ddc-mirror

clean:
	rm -f ddc-mirror

.PHONY: install clean
