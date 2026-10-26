// overlay.m — small click-through FPS readout.
// SPDX-License-Identifier: GPL-3.0-only
#import <AppKit/AppKit.h>

static NSPanel *gPanel;
static NSTextField *gLabel;

static void createPanel(void) {
    gPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 360, 48)
                                        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
    gPanel.level = NSStatusWindowLevel;
    gPanel.opaque = NO;
    gPanel.backgroundColor = [NSColor colorWithWhite:0 alpha:0.6];
    gPanel.ignoresMouseEvents = YES;
    gPanel.hasShadow = NO;
    gPanel.hidesOnDeactivate = NO;
    gPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary |
                                NSWindowCollectionBehaviorStationary;

    gLabel = [NSTextField labelWithString:@"uncapped"];
    gLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold];
    gLabel.textColor = [NSColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1];
    gLabel.maximumNumberOfLines = 0;
    gLabel.usesSingleLineMode = NO;
    [gPanel.contentView addSubview:gLabel];
}

static void layoutPanel(void) {
    NSSize text = gLabel.intrinsicContentSize;
    NSSize size = NSMakeSize(ceil(text.width) + 20, ceil(text.height) + 12);
    gLabel.frame = NSMakeRect(10, 6, ceil(text.width), ceil(text.height));
    NSScreen *screen = NSApp.keyWindow.screen ?: NSScreen.mainScreen;
    NSRect vis = screen.visibleFrame;
    [gPanel setFrame:NSMakeRect(NSMinX(vis) + 12, NSMaxY(vis) - 12 - size.height, size.width, size.height)
             display:YES];
}

// Called on the main queue. Created lazily, after Roblox has set up NSApp.
void UncappedOverlayUpdate(NSString *text) {
    if (!NSApp) return;
    if (!gPanel) createPanel();
    gLabel.stringValue = text;
    layoutPanel();
    if (!gPanel.isVisible) [gPanel orderFrontRegardless];
}
