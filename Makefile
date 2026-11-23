BUILD := build
CFLAGS := -Wall -Wextra -Wno-unused-parameter -O2 -g -Iinclude
OBJCFLAGS := $(CFLAGS) -fobjc-arc
FRAMEWORKS := -framework Foundation -framework QuartzCore -framework IOSurface

LIB_SRC := src/common.c src/wire.c src/frames.c src/link.m src/producer.m src/host.m
LIB_OBJ := $(patsubst src/%,$(BUILD)/obj/%.o,$(LIB_SRC))

all: $(BUILD)/libbowser.a $(BUILD)/bowser-test $(BUILD)/bowser-host

$(BUILD)/obj/%.c.o: src/%.c src/*.h include/bowser.h
	@mkdir -p $(dir $@)
	clang $(CFLAGS) -c $< -o $@

$(BUILD)/obj/%.m.o: src/%.m src/*.h include/bowser.h
	@mkdir -p $(dir $@)
	clang $(OBJCFLAGS) -c $< -o $@

$(BUILD)/libbowser.a: $(LIB_OBJ)
	ar rcs $@ $^

$(BUILD)/bowser-test: adapters/test/main.m $(BUILD)/libbowser.a
	clang $(OBJCFLAGS) $< $(BUILD)/libbowser.a -o $@ $(FRAMEWORKS) \
		-framework AppKit -framework Metal -framework CoreText

$(BUILD)/bowser-host: examples/host-swift/main.swift $(BUILD)/libbowser.a
	swiftc -O -g -import-objc-header include/bowser.h $< $(BUILD)/libbowser.a -o $@ \
		$(FRAMEWORKS) -framework AppKit

clean:
	rm -rf $(BUILD)

.PHONY: all clean

$(BUILD)/e2e: tests/e2e.m tests/harness.h $(BUILD)/libbowser.a
	clang $(OBJCFLAGS) $< $(BUILD)/libbowser.a -o $@ $(FRAMEWORKS) -framework AppKit

test: $(BUILD)/bowser-test $(BUILD)/e2e
	$(BUILD)/e2e

.PHONY: test

# ---- CEF adapter (needs scripts/fetch-cef.sh) ----

CEF := third_party/cef/current
CEF_APP := $(BUILD)/bowser-cef.app
CEF_CFLAGS := -I$(CEF) -DCEF_API_VERSION=15800

$(CEF)/include/cef_version.h:
	scripts/fetch-cef.sh

$(BUILD)/cef/bowser-cef: adapters/cef/main.m adapters/cef/windowed.m adapters/cef/engine.h $(BUILD)/libbowser.a \
		$(CEF)/include/cef_version.h
	@mkdir -p $(dir $@)
	clang $(OBJCFLAGS) $(CEF_CFLAGS) adapters/cef/main.m adapters/cef/windowed.m $(BUILD)/libbowser.a -o $@ $(FRAMEWORKS) \
		-framework AppKit -framework Metal -F$(CEF)/Release -framework "Chromium Embedded Framework"

$(BUILD)/cef/helper: adapters/cef/helper.c $(CEF)/include/cef_version.h
	@mkdir -p $(dir $@)
	clang $(CFLAGS) $(CEF_CFLAGS) $< -o $@

$(CEF_APP): $(BUILD)/cef/bowser-cef $(BUILD)/cef/helper adapters/cef/bundle.sh
	adapters/cef/bundle.sh $@ $(BUILD)/cef/bowser-cef $(BUILD)/cef/helper $(CEF)/Release
	@touch $@

$(BUILD)/cef/bowser-cef-bench: adapters/cef/bench.m $(BUILD)/libbowser.a
	@mkdir -p $(dir $@)
	clang $(OBJCFLAGS) $< $(BUILD)/libbowser.a -o $@ $(FRAMEWORKS) -framework AppKit

$(BUILD)/e2e-cef: tests/cef.m tests/harness.h $(BUILD)/libbowser.a
	clang $(OBJCFLAGS) $< $(BUILD)/libbowser.a -o $@ $(FRAMEWORKS) -framework AppKit -framework ImageIO

# BOWSER_SPACE=<n> also checks real host windows, put on Space n.
test-cef: $(CEF_APP) $(BUILD)/e2e-cef $(BUILD)/bowser-host
	$(BUILD)/e2e-cef

.PHONY: test-cef

cef: $(CEF_APP) $(BUILD)/bowser-host $(BUILD)/cef/bowser-cef-bench

.PHONY: cef

# ---- Rex plugin, end to end with the real engine ----

test-rex: $(CEF_APP)
	cd rex/plugin && go test -count=1 ./...

.PHONY: test-rex

# ---- Display-level benchmark (docs/perf.md) ----

$(BUILD)/cef/bowser-cef-probe: adapters/cef/probe.m $(BUILD)/libbowser.a
	@mkdir -p $(dir $@)
	clang $(OBJCFLAGS) $< $(BUILD)/libbowser.a -o $@ $(FRAMEWORKS) -framework AppKit \
		-framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework IOKit
