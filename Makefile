BUILD := build
CFLAGS := -Wall -Wextra -Wno-unused-parameter -O2 -g -Iinclude
OBJCFLAGS := $(CFLAGS) -fobjc-arc
FRAMEWORKS := -framework Foundation -framework QuartzCore -framework IOSurface

LIB_SRC := src/common.c src/wire.c src/frames.c src/producer.m src/host.m
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

$(BUILD)/e2e: tests/e2e.m $(BUILD)/libbowser.a
	clang $(OBJCFLAGS) $< $(BUILD)/libbowser.a -o $@ $(FRAMEWORKS) -framework AppKit

test: $(BUILD)/bowser-test $(BUILD)/e2e
	$(BUILD)/e2e

.PHONY: test
