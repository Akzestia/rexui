# Copyright (c) 2026-present アクゼスティア
# SPDX-License-Identifier: LicenseRef-rexui-1.0
B ?= build
OPT ?= -O2
LTO_LINK ?=
LIB := $(B)/rexui.dylib
SRCS := $(shell find src -name '*.mm' -not -path 'src/rex/stub/*' | sort)
CC_SRCS := $(shell find src -name '*.cc' | sort)
OBJS := $(SRCS:%.mm=$(B)/obj/%.o) $(CC_SRCS:%.cc=$(B)/obj/%.o)
SWIFT_SRCS := $(wildcard src/rex/*.swift)
NAMES := $(B)/gen/rx_names.swift $(B)/gen/rx_names.h
LUA_OBJS := $(patsubst %.c,$(B)/obj/%.o,$(wildcard third_party/lua/*.c))

all: $(LIB) $(B)/rexui-check $(B)/rui-ls

ENGINE_OBJS := $(filter $(B)/obj/src/engine/%,$(OBJS))
$(B)/rexui-check: tools/check/main.cc tools/common/json.h $(ENGINE_OBJS)
	xcrun clang++ $(CC_FLAGS) -I tools -o $@ $< $(ENGINE_OBJS) -framework CoreFoundation -licucore

RUI_LS_SRCS := $(wildcard tools/editor/rui-ls/*.cc)
RUI_LS_OBJS := $(patsubst %.cc,$(B)/obj/%.o,$(filter-out tools/editor/rui-ls/test.cc,$(RUI_LS_SRCS)))
$(B)/obj/tools/editor/rui-ls/%.o: tools/editor/rui-ls/%.cc
	@mkdir -p $(dir $@)
	xcrun clang++ $(CC_FLAGS) -Wno-missing-field-initializers -I tools -MMD -MP -c $< -o $@
-include $(RUI_LS_OBJS:.o=.d)
$(B)/rui-ls: $(RUI_LS_OBJS) $(ENGINE_OBJS)
	xcrun clang++ $(CC_FLAGS) -o $@ $(RUI_LS_OBJS) $(ENGINE_OBJS) -framework CoreFoundation -licucore

$(B)/gen/rexui_deps: src/rex/deps.txt $(B)/rxgen
	@mkdir -p $(B)/gen
	$(B)/rxgen --deps $< $@

$(LIB): $(OBJS) $(LUA_OBJS) $(B)/rex_swift.o jm/exports.txt $(B)/gen/rexui_deps
	xcrun clang++ $(FLAGS) -dynamiclib $(FRAMEWORKS) -L"$$(xcrun --show-sdk-path)/usr/lib/swift" -Wl,-rpath,/usr/lib/swift \
		-Wl,-sectcreate,__TEXT,__rexui_deps,$(B)/gen/rexui_deps -Wl,-exported_symbols_list,jm/exports.txt -Wl,-dead_strip $(OPT) $(LTO_LINK) -o $@.new $(OBJS) $(LUA_OBJS) $(B)/rex_swift.o
	codesign --force --sign - $@.new
	mv $@.new $@

$(B)/obj/%.o: %.mm
	@mkdir -p $(dir $@)
	xcrun clang++ $(FLAGS) $(OPT) -MMD -MP -c $< -o $@

CC_FLAGS ?= -std=c++23 -arch arm64 $(OPT) -Wall -Wextra -Wshadow -Wconversion -Werror -fno-exceptions -fno-rtti -ffp-contract=off -I src -I backends/include -I $(B)
$(B)/obj/%.o: %.cc
	@mkdir -p $(dir $@)
	xcrun clang++ $(CC_FLAGS) -MMD -MP -c $< -o $@

$(B)/obj/third_party/lua/%.o: third_party/lua/%.c
	@mkdir -p $(dir $@)
	xcrun clang -arch arm64 -O2 -std=gnu99 -DLUA_USE_MACOSX -fvisibility=hidden -w -c $< -o $@

SWIFT_GEN := $(SWIFT_SRCS:src/rex/%=$(B)/gen/swift/%)
$(B)/gen/swift.stamp: $(SWIFT_SRCS) src/rex/names.h src/rex/names.mm $(B)/rxgen
	@mkdir -p $(B)/gen/swift
	@rm -f $(filter-out $(SWIFT_GEN),$(wildcard $(B)/gen/swift/*.swift))
	$(B)/rxgen --swift src/rex/names.h src/rex/names.mm $(B)/gen/swift $(SWIFT_SRCS)
	@touch $@
$(SWIFT_GEN): $(B)/gen/swift.stamp ;

$(B)/rex_swift.o: $(SWIFT_GEN) src/rex/bridge.h
	$(SWIFT) -emit-object -o $@ $(SWIFT_GEN)

$(B)/gen/rx_names.stamp: src/rex/names.h src/rex/names.mm $(B)/rxgen
	@mkdir -p $(B)/gen
	$(B)/rxgen --names src/rex/names.h src/rex/names.mm $(B)/gen
	@touch $@
$(NAMES): $(B)/gen/rx_names.stamp ;

$(B)/rxgen: tools/rxgen/rxgen.cc
	xcrun clang++ -std=c++23 -O2 -Wall -Wextra -o $@ $<

$(B)/gen/rx_props.h: src/schema/elements.rxs $(B)/rxgen
	@mkdir -p $(B)/gen
	$(B)/rxgen $< $(B)/gen >/dev/null
	@touch $@

$(OBJS) $(RUI_LS_OBJS) $(B)/rexui-check: | $(B)/gen/rx_props.h
$(OBJS): | $(B)/gen/rx_names.h

-include $(OBJS:.o=.d)

objs: $(OBJS) $(LUA_OBJS)
gen: $(B)/gen/rx_props.h $(NAMES)
.PHONY: all objs gen
