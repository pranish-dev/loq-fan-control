#!/bin/sh
# Run this first. It checks that the command line tools can build a kext.
SDK=$(xcrun --show-sdk-path)
echo "SDK: $SDK"
for f in System/Library/Frameworks/Kernel.framework/Headers/IOKit/IOService.h \
         System/Library/Frameworks/Kernel.framework/Headers/IOKit/IOMemoryDescriptor.h; do
  [ -f "$SDK/$f" ] && echo "OK   $f" || echo "MISSING $f"
done
for l in libkmod.a libkmodc++.a libcc_kext.a; do
  p=$(find "$SDK/usr/lib" "$SDK/System/Library/Frameworks/Kernel.framework" -name "$l" 2>/dev/null | head -1)
  [ -n "$p" ] && echo "OK   $l -> $p" || echo "MISSING $l"
done

find "$(dirname "$(xcrun --find clang)")/.." -name "*cc_kext*" 2>/dev/null | head -3
