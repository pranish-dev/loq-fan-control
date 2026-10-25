SDK := $(shell xcrun --show-sdk-path)
KF  := $(SDK)/System/Library/Frameworks/Kernel.framework
OUT := build/LOQFanMon.kext
# libcc_kext moved into the clang toolchain in newer SDKs; find it if present
CCKEXT := $(firstword $(shell find $(dir $(shell xcrun --find clang))/.. -name 'libclang_rt.cc_kext.a' 2>/dev/null))

CXXFLAGS := -arch x86_64 -mmacosx-version-min=12.0 -isysroot $(SDK) -std=gnu++17 -x c++ \
  -fapple-kext -fno-rtti -fno-exceptions -fno-builtin -fno-common -fno-stack-protector \
  -mkernel -nostdinc++ -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
  -I$(KF)/Headers -I$(KF)/PrivateHeaders -Wall

all: $(OUT)

build/LOQFanMon.o: LOQFanMon.cpp
	@mkdir -p build
	clang++ $(CXXFLAGS) -c $< -o $@

$(OUT): build/LOQFanMon.o Info.plist
	@mkdir -p $(OUT)/Contents/MacOS
	clang++ -arch x86_64 -mmacosx-version-min=12.0 -isysroot $(SDK) -nostdlib \
	  -Xlinker -kext -Xlinker -no_adhoc_codesign build/LOQFanMon.o \
	  -lkmodc++ -lkmod $(CCKEXT) -o $(OUT)/Contents/MacOS/LOQFanMon
	cp Info.plist $(OUT)/Contents/Info.plist
	@echo "Built $(OUT)"

clean:
	rm -rf build
