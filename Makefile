CC         = clang
ARCHS      = -arch arm64 -arch x86_64
CFLAGS     = $(ARCHS) -dynamiclib -fobjc-arc -O2 -Wall -mmacosx-version-min=14.0
FRAMEWORKS = -framework Foundation -framework QuartzCore -framework Metal -framework AppKit
SRCS       = src/uncapped.m src/overlay.m

build/uncapped.dylib: $(SRCS)
	@mkdir -p build
	$(CC) $(CFLAGS) $(FRAMEWORKS) -o $@ $(SRCS)
	codesign -f -s - $@

clean:
	rm -rf build

.PHONY: clean
