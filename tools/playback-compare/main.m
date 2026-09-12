// Local A/B harness. Uses the user's IINA libmpv; no libraries are redistributed.
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <OpenGL/gl3.h>
#import <mpv/client.h>
#import <mpv/render_gl.h>
#import <dlfcn.h>

@interface MPVView : NSOpenGLView
@property mpv_handle *player;
@property mpv_render_context *renderer;
@property NSUInteger renderedFrames;
- (BOOL)start:(NSString *)path seconds:(double)seconds fill:(BOOL)fill error:(NSString **)error;
- (void)shutdown;
@end

static void *glSymbol(void *ctx, const char *name) { (void)ctx; return dlsym(RTLD_DEFAULT, name); }
static void renderUpdate(void *ctx) {
    MPVView *view = (__bridge MPVView *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{ if (view.renderer) [view setNeedsDisplay:YES]; });
}
@implementation MPVView
- (instancetype)initWithFrame:(NSRect)frame {
    NSOpenGLPixelFormatAttribute attrs[] = { NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
        NSOpenGLPFADoubleBuffer, NSOpenGLPFAAccelerated, NSOpenGLPFAColorSize, 24, 0 };
    self = [super initWithFrame:frame pixelFormat:[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs]];
    if (self) self.wantsBestResolutionOpenGLSurface = YES;
    return self;
}
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (BOOL)start:(NSString *)path seconds:(double)seconds fill:(BOOL)fill error:(NSString **)error {
    self.player = mpv_create();
    if (!self.player) { *error = @"mpv_create failed"; return NO; }
    NSDictionary *options = @{ @"vo": @"libmpv", @"hwdec": @"auto-safe", @"mute": @"yes",
        @"config": @"no", @"load-scripts": @"no", @"terminal": @"yes", @"msg-level": @"all=warn",
        @"loop-file": @"inf", @"keep-open": @"yes", @"video-unscaled": @"no",
        @"panscan": fill ? @"1" : @"0", @"start": [NSString stringWithFormat:@"%.6f", seconds] };
    for (NSString *key in options) {
        int rc = mpv_set_option_string(self.player, key.UTF8String, [options[key] UTF8String]);
        if (rc < 0) { *error = [NSString stringWithFormat:@"%@: %s", key, mpv_error_string(rc)]; return NO; }
    }
    int rc = mpv_initialize(self.player);
    if (rc < 0) { *error = @(mpv_error_string(rc)); return NO; }
    [self.openGLContext makeCurrentContext];
    GLint interval = 1;
    [self.openGLContext setValues:&interval forParameter:NSOpenGLContextParameterSwapInterval];
    mpv_opengl_init_params gl = { .get_proc_address = glSymbol };
    mpv_render_param params[] = { {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl}, {0, NULL} };
    mpv_render_context *renderer = NULL;
    rc = mpv_render_context_create(&renderer, self.player, params);
    if (rc < 0) { *error = @(mpv_error_string(rc)); return NO; }
    self.renderer = renderer;
    mpv_render_context_set_update_callback(renderer, renderUpdate, (__bridge void *)self);
    const char *cmd[] = {"loadfile", path.UTF8String, NULL};
    rc = mpv_command(self.player, cmd);
    if (rc < 0) { *error = @(mpv_error_string(rc)); return NO; }
    return YES;
}
- (void)drawRect:(NSRect)rect {
    if (!self.renderer) return;
    [self.openGLContext makeCurrentContext];
    NSRect pixels = [self convertRectToBacking:self.bounds];
    mpv_opengl_fbo fbo = { .fbo = 0, .w = (int)pixels.size.width, .h = (int)pixels.size.height };
    int flip = 1;
    mpv_render_param params[] = { {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
        {MPV_RENDER_PARAM_FLIP_Y, &flip}, {0, NULL} };
    mpv_render_context_render(self.renderer, params);
    [self.openGLContext flushBuffer];
    mpv_render_context_report_swap(self.renderer);
    self.renderedFrames++;
}
- (void)shutdown {
    if (self.renderer) {
        mpv_render_context_set_update_callback(self.renderer, NULL, NULL);
        [self.openGLContext makeCurrentContext];
        mpv_render_context_free(self.renderer);
        self.renderer = NULL;
    }
    if (self.player) { mpv_terminate_destroy(self.player); self.player = NULL; }
}
@end

@interface DesktopWindow : NSWindow
@end
@implementation DesktopWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface CompareApp : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property MPVView *mpv;
@property AVQueuePlayer *av;
@property id endObserver;
@property AVPlayerLayer *avLayer;
@property NSStatusItem *status;
@property NSScreen *screen;
@property NSString *path;
@property BOOL useMPV;
@property BOOL desktop;
@property BOOL fill;
@property BOOL aboveIcons;
@property BOOL suspended;
@property BOOL selfTest;
@property double startSeconds;
@property NSUInteger generation;
@property NSTimer *timer;
@property id activity;
@property BOOL sawMPVPlayback;
@property BOOL sawAVPlayback;
@property NSURL *restoreFoldwallURL;
@property NSArray<NSRunningApplication *> *foldwallProcesses;
@property NSUInteger shutdownPolls;
@end

@implementation CompareApp
- (void)add:(NSMenu *)menu title:(NSString *)title action:(SEL)action checked:(BOOL)checked {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)updateMenu {
    NSMenu *menu = [NSMenu new];
    [menu addItemWithTitle:self.path.lastPathComponent ?: @"尚未選片" action:nil keyEquivalent:@""];
    [self add:menu title:@"mpv（IINA 核心）" action:@selector(selectMPV:) checked:self.useMPV];
    [self add:menu title:@"AVPlayer（Foldwall 現行核心）" action:@selector(selectAV:) checked:!self.useMPV];
    [menu addItem:NSMenuItem.separatorItem];
    [self add:menu title:@"桌面層播放" action:@selector(toggleDesktop:) checked:self.desktop];
    [self add:menu title:@"填滿螢幕" action:@selector(toggleFill:) checked:self.fill];
    [self add:menu title:@"選擇影片…" action:@selector(choose:) checked:NO];
    [self add:menu title:[NSString stringWithFormat:@"比較起點：%.1f 秒…", self.startSeconds]
        action:@selector(chooseStart:) checked:NO];
    for (NSScreen *screen in NSScreen.screens) {
        NSMenuItem *item = [menu addItemWithTitle:screen.localizedName action:@selector(selectScreen:) keyEquivalent:@""];
        item.target = self; item.representedObject = screen;
        item.state = screen == self.screen ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [menu addItem:NSMenuItem.separatorItem];
    [self add:menu title:@"結束播放比較" action:@selector(quit:) checked:NO];
    self.status.menu = menu;
    self.status.button.title = self.useMPV ? @"比較：mpv" : @"比較：AV";
}
- (void)stop {
    self.generation++;
    [self.timer invalidate]; self.timer = nil;
    [self.mpv shutdown]; self.mpv = nil;
    [self.av pause];
    if (self.endObserver) [NSNotificationCenter.defaultCenter removeObserver:self.endObserver];
    self.endObserver = nil;
    [self.av removeAllItems]; self.avLayer.player = nil; self.avLayer = nil; self.av = nil;
    [self.window orderOut:nil]; [self.window close]; self.window = nil;
    if (self.activity) { [NSProcessInfo.processInfo endActivity:self.activity]; self.activity = nil; }
}
- (void)fail:(NSString *)message {
    NSLog(@"PLAYBACK ERROR: %@", message);
    [self stop];
    if (self.selfTest) exit(1);
    NSAlert *alert = [NSAlert new]; alert.messageText = @"播放比較失敗"; alert.informativeText = message;
    [alert runModal];
}
- (void)play {
    [self stop]; [self updateMenu];
    if (!self.path || self.suspended) return;
    self.activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
        reason:@"Foldwall playback A/B comparison"];
    NSRect frame = self.screen.frame;
    if (self.desktop) {
        self.window = [[DesktopWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless
            backing:NSBackingStoreBuffered defer:NO];
        self.window.level = CGWindowLevelForKey(self.aboveIcons ? kCGDesktopIconWindowLevelKey : kCGDesktopWindowLevelKey) + 2;
        self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary
            | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
        self.window.ignoresMouseEvents = YES;
    } else {
        frame = NSInsetRect(frame, frame.size.width * .15, frame.size.height * .15);
        self.window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled
            backing:NSBackingStoreBuffered defer:NO];
    }
    self.window.releasedWhenClosed = NO;
    self.window.title = self.useMPV ? @"Foldwall 比較 — mpv" : @"Foldwall 比較 — AVPlayer";
    self.window.backgroundColor = NSColor.blackColor;
    self.window.opaque = YES; self.window.hasShadow = !self.desktop;
    [self.window setFrame:frame display:NO];
    if (self.useMPV) {
        self.mpv = [[MPVView alloc] initWithFrame:self.window.contentView.bounds];
        self.window.contentView = self.mpv;
        [self.window orderFront:nil];
        NSString *error;
        if (![self.mpv start:self.path seconds:self.startSeconds fill:self.fill error:&error]) { [self fail:error]; return; }
    } else {
        NSView *view = self.window.contentView; view.wantsLayer = YES;
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:self.path]];
        item.preferredForwardBufferDuration = 4;
        self.av = [AVQueuePlayer queuePlayerWithItems:@[item]]; self.av.muted = YES;
        self.av.actionAtItemEnd = AVPlayerActionAtItemEndPause;
        self.av.preventsDisplaySleepDuringVideoPlayback = NO;
        __weak CompareApp *weakSelf = self;
        self.endObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
            object:item queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; [weakSelf play]; }];
        self.avLayer = [AVPlayerLayer playerLayerWithPlayer:self.av];
        self.avLayer.videoGravity = self.fill ? AVLayerVideoGravityResizeAspectFill : AVLayerVideoGravityResizeAspect;
        self.avLayer.frame = view.bounds; self.avLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        [view.layer addSublayer:self.avLayer];
        [self.window orderFront:nil];
        NSUInteger generation = self.generation;
        [self.av seekToTime:CMTimeMakeWithSeconds(self.startSeconds, 600000) toleranceBefore:kCMTimeZero
            toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (finished && generation == self.generation) [self.av play];
                });
            }];
    }
    NSLog(@"PLAY engine=%@ screen=%@ start=%.3f desktop=%d", self.useMPV ? @"mpv" : @"AVPlayer",
        self.screen.localizedName, self.startSeconds, self.desktop);
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(sample:) userInfo:nil repeats:YES];
}
- (void)sample:(id)sender {
    if (self.mpv.player) {
        double pos = -1; int64_t decoderDrops = -1, outputDrops = -1;
        mpv_get_property(self.mpv.player, "time-pos", MPV_FORMAT_DOUBLE, &pos);
        mpv_get_property(self.mpv.player, "decoder-frame-drop-count", MPV_FORMAT_INT64, &decoderDrops);
        mpv_get_property(self.mpv.player, "frame-drop-count", MPV_FORMAT_INT64, &outputDrops);
        char *hw = mpv_get_property_string(self.mpv.player, "hwdec-current");
        NSLog(@"mpv position=%.3f renderCalls=%lu decoderDrops=%lld outputDrops=%lld hwdec=%s", pos,
            (unsigned long)self.mpv.renderedFrames, decoderDrops, outputDrops, hw ?: "unknown");
        mpv_free(hw);
        if (pos > self.startSeconds + 1 && self.mpv.renderedFrames > 10) self.sawMPVPlayback = YES;
        mpv_event *event;
        while ((event = mpv_wait_event(self.mpv.player, 0))->event_id != MPV_EVENT_NONE) {
            if (event->event_id == MPV_EVENT_END_FILE) {
                mpv_event_end_file *end = event->data;
                if (end->reason == MPV_END_FILE_REASON_ERROR) { [self fail:@(mpv_error_string(end->error))]; return; }
            }
        }
    } else if (self.av) {
        double pos = CMTimeGetSeconds(self.av.currentTime);
        NSLog(@"AVPlayer position=%.3f status=%ld ready=%d", pos, (long)self.av.timeControlStatus, self.avLayer.readyForDisplay);
        if (pos > self.startSeconds + 1 && self.avLayer.readyForDisplay) self.sawAVPlayback = YES;
        if (self.av.currentItem.status == AVPlayerItemStatusFailed) [self fail:self.av.currentItem.error.localizedDescription];
    }
}
- (void)selectMPV:(id)sender { self.useMPV = YES; [self play]; }
- (void)selectAV:(id)sender { self.useMPV = NO; [self play]; }
- (void)toggleDesktop:(id)sender { self.desktop = !self.desktop; [self play]; }
- (void)toggleFill:(id)sender { self.fill = !self.fill; [self play]; }
- (void)selectScreen:(NSMenuItem *)sender { self.screen = sender.representedObject; [self play]; }
- (void)choose:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel]; panel.canChooseDirectories = NO; panel.allowsMultipleSelection = NO;
    [NSApp activateIgnoringOtherApps:YES];
    if ([panel runModal] == NSModalResponseOK) { self.path = panel.URL.path; [self play]; }
}
- (void)chooseStart:(id)sender {
    NSAlert *alert = [NSAlert new]; alert.messageText = @"兩個核心從同一秒數開始播放";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 220, 24)];
    field.stringValue = [NSString stringWithFormat:@"%.1f", self.startSeconds]; alert.accessoryView = field;
    [alert addButtonWithTitle:@"套用"]; [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSScanner *scanner = [NSScanner scannerWithString:field.stringValue]; double seconds;
        if ([scanner scanDouble:&seconds] && scanner.isAtEnd && isfinite(seconds) && seconds >= 0) {
            self.startSeconds = seconds; [self play];
        }
    }
}
- (void)sleep:(NSNotification *)n { self.suspended = YES; [self stop]; }
- (void)wake:(NSNotification *)n { self.suspended = NO; [self play]; }
- (void)screensChanged:(NSNotification *)n {
    if (![NSScreen.screens containsObject:self.screen]) self.screen = NSScreen.mainScreen;
    [self play];
}
- (void)quit:(id)sender { [NSApp terminate:nil]; }
- (void)applicationWillTerminate:(NSNotification *)n {
    [self stop];
    if (self.restoreFoldwallURL) {
        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
        config.activates = NO;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:self.restoreFoldwallURL configuration:config completionHandler:nil];
    }
}
- (void)waitForFoldwall {
    for (NSRunningApplication *app in self.foldwallProcesses) {
        if (!app.terminated) {
            if (++self.shutdownPolls > 50) { [self fail:@"Foldwall 尚未結束，請先關閉它再開始比較。"]; return; }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{ [self waitForFoldwall]; });
            return;
        }
    }
    [self play];
}
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    self.selfTest = [args containsObject:@"--self-test"];
    self.useMPV = YES; self.desktop = YES; self.screen = NSScreen.mainScreen;
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"app.foldwall"];
    self.fill = ![settings[@"videoScaleMode"] isEqual:@"fit"];
    self.aboveIcons = [settings[@"desktopVideoLayer"] isEqual:@"aboveIcons"];
    for (NSScreen *screen in NSScreen.screens) {
        CGDirectDisplayID display = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
        NSString *key = CFBridgingRelease(CFUUIDCreateString(NULL, uuid)); CFRelease(uuid);
        if ([settings[@"videoScreens"] containsObject:key]) { self.screen = screen; break; }
    }
    for (NSUInteger i = 1; i < args.count; i++) {
        if ([args[i] isEqual:@"--self-test"]) continue;
        if ([args[i] isEqual:@"--isolate"]) continue;
        if ([args[i] isEqual:@"--screen"] && i + 1 < args.count) {
            NSString *wanted = args[++i];
            for (NSScreen *screen in NSScreen.screens) {
                CGDirectDisplayID display = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
                CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
                NSString *key = CFBridgingRelease(CFUUIDCreateString(NULL, uuid)); CFRelease(uuid);
                if ([key caseInsensitiveCompare:wanted] == NSOrderedSame) self.screen = screen;
            }
            continue;
        }
        if ([args[i] isEqual:@"--start"] && i + 1 < args.count) { self.startSeconds = MAX(0, args[++i].doubleValue); continue; }
        self.path = args[i];
    }
    self.status = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    [self updateMenu];
    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspace addObserver:self selector:@selector(sleep:) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [workspace addObserver:self selector:@selector(wake:) name:NSWorkspaceScreensDidWakeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(screensChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    if ([args containsObject:@"--isolate"] && !self.selfTest) {
        self.foldwallProcesses = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"app.foldwall"];
        self.restoreFoldwallURL = self.foldwallProcesses.firstObject.bundleURL;
        for (NSRunningApplication *app in self.foldwallProcesses) [app terminate];
        [self waitForFoldwall];
    } else if (self.path) [self play]; else [self choose:nil];
    if (self.selfTest) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self selectAV:nil]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self selectMPV:nil]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 24 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            BOOL ok = self.sawMPVPlayback && self.sawAVPlayback;
            NSLog(@"SELF TEST %@", ok ? @"PASS" : @"FAIL"); [self stop]; exit(ok ? 0 : 1);
        });
    }
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        CompareApp *delegate = [CompareApp new]; app.delegate = delegate;
        [app run];
    }
    return 0;
}
