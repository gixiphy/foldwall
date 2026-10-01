//  MPVBridge.m
//  說明見 MPVBridge.h。這裡是唯一碰 mpv C API、dlsym 與 OpenGL 的地方。

#define GL_SILENCE_DEPRECATION 1
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#import "MPVBridge.h"

#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>   // 只用型別與常數；函式一律經 MPVGLProcAddress 取
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <stdatomic.h>

// 只用型別與常數，不 link 任何符號。
#import <mpv/client.h>
#import <mpv/render.h>
#import <mpv/render_gl.h>

NSErrorDomain const MPVBridgeErrorDomain = @"app.foldwall.mpv";

static NSError *MPVError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:MPVBridgeErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"unknown"}];
}

// MARK: - 函式表

/// dlsym 出來的整組符號。型別照 client.h／render.h 抄，少一個都不載。
typedef struct {
    unsigned long (*client_api_version)(void);
    mpv_handle *(*create)(void);
    int (*initialize)(mpv_handle *);
    void (*terminate_destroy)(mpv_handle *);
    int (*set_option_string)(mpv_handle *, const char *, const char *);
    int (*command_node)(mpv_handle *, mpv_node *, mpv_node *);
    int (*set_property)(mpv_handle *, const char *, mpv_format, void *);
    int (*set_property_string)(mpv_handle *, const char *, const char *);
    int (*get_property)(mpv_handle *, const char *, mpv_format, void *);
    char *(*get_property_string)(mpv_handle *, const char *);
    void (*free)(void *);
    void (*free_node_contents)(mpv_node *);
    int (*observe_property)(mpv_handle *, uint64_t, const char *, mpv_format);
    void (*set_wakeup_callback)(mpv_handle *, void (*)(void *), void *);
    mpv_event *(*wait_event)(mpv_handle *, double);
    const char *(*error_string)(int);
    int (*render_context_create)(mpv_render_context **, mpv_handle *, mpv_render_param *);
    void (*render_context_set_update_callback)(mpv_render_context *, mpv_render_update_fn, void *);
    uint64_t (*render_context_update)(mpv_render_context *);
    int (*render_context_render)(mpv_render_context *, mpv_render_param *);
    void (*render_context_report_swap)(mpv_render_context *);
    void (*render_context_free)(mpv_render_context *);
} MPVFunctions;

@interface MPVLibraryHandle () {
@public
    MPVFunctions _fn;
    void *_handle;
}
@end

@implementation MPVLibraryHandle

+ (nullable instancetype)openAtPath:(NSString *)path error:(NSError **)error {
    // RTLD_LOCAL：mpv 連的 FFmpeg 符號不要污染全域命名空間（app 自己沒 link FFmpeg，
    // 但別的動態庫可能有同名符號）。RTLD_NOW：缺相依現在就知道，不要播到一半才炸。
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *message = dlerror();
        if (error) *error = MPVError(1, message ? @(message) : @"dlopen failed");
        return nil;
    }
    MPVLibraryHandle *library = [MPVLibraryHandle new];
    library->_handle = handle;
    MPVFunctions *fn = &library->_fn;

#define LOAD(field, symbol) \
    do { \
        *(void **)&fn->field = dlsym(handle, symbol); \
        if (!fn->field) { \
            if (error) *error = MPVError(2, [NSString stringWithFormat:@"missing symbol %s", symbol]); \
            dlclose(handle); \
            return nil; \
        } \
    } while (0)

    LOAD(client_api_version, "mpv_client_api_version");
    LOAD(create, "mpv_create");
    LOAD(initialize, "mpv_initialize");
    LOAD(terminate_destroy, "mpv_terminate_destroy");
    LOAD(set_option_string, "mpv_set_option_string");
    LOAD(command_node, "mpv_command_node");
    LOAD(set_property, "mpv_set_property");
    LOAD(set_property_string, "mpv_set_property_string");
    LOAD(get_property, "mpv_get_property");
    LOAD(get_property_string, "mpv_get_property_string");
    LOAD(free, "mpv_free");
    LOAD(free_node_contents, "mpv_free_node_contents");
    LOAD(observe_property, "mpv_observe_property");
    LOAD(set_wakeup_callback, "mpv_set_wakeup_callback");
    LOAD(wait_event, "mpv_wait_event");
    LOAD(error_string, "mpv_error_string");
    LOAD(render_context_create, "mpv_render_context_create");
    LOAD(render_context_set_update_callback, "mpv_render_context_set_update_callback");
    LOAD(render_context_update, "mpv_render_context_update");
    LOAD(render_context_render, "mpv_render_context_render");
    LOAD(render_context_report_swap, "mpv_render_context_report_swap");
    LOAD(render_context_free, "mpv_render_context_free");
#undef LOAD
    return library;
}

// 刻意沒有 dealloc 裡的 dlclose：一個行程只開一次、握到結束（見 MPVRuntime）。

- (unsigned long)clientAPIVersion {
    return _fn.client_api_version();
}

- (nullable NSString *)probeVersionStringWithOptions:(NSDictionary<NSString *, NSString *> *)options {
    mpv_handle *core = _fn.create();
    if (!core) return nil;
    // 只是為了讀一個屬性。選項照播放那套（script 全關），舊版沒有的選項略過。
    for (NSString *key in options) {
        _fn.set_option_string(core, key.UTF8String, options[key].UTF8String);
    }
    NSString *version = nil;
    if (_fn.initialize(core) >= 0) {
        char *text = _fn.get_property_string(core, "mpv-version");
        if (text) {
            version = @(text);
            _fn.free(text);
        }
    }
    _fn.terminate_destroy(core);
    return version;
}

@end

// MARK: - node ↔ 物件

static id ObjectFromNode(const mpv_node *node) {
    switch (node->format) {
    case MPV_FORMAT_STRING:
        return node->u.string ? @(node->u.string) : nil;
    case MPV_FORMAT_FLAG:
        return @(node->u.flag != 0);
    case MPV_FORMAT_INT64:
        return @(node->u.int64);
    case MPV_FORMAT_DOUBLE:
        return @(node->u.double_);
    case MPV_FORMAT_NODE_ARRAY: {
        NSMutableArray *array = [NSMutableArray array];
        for (int i = 0; node->u.list && i < node->u.list->num; i++) {
            id value = ObjectFromNode(&node->u.list->values[i]);
            [array addObject:value ?: [NSNull null]];
        }
        return array;
    }
    case MPV_FORMAT_NODE_MAP: {
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (int i = 0; node->u.list && i < node->u.list->num; i++) {
            id value = ObjectFromNode(&node->u.list->values[i]);
            if (value && node->u.list->keys[i]) map[@(node->u.list->keys[i])] = value;
        }
        return map;
    }
    default:
        return nil;
    }
}

// MARK: - 事件

@interface MPVEvent ()
@property (readwrite) MPVEventKind kind;
@property (readwrite) int64_t playlistEntryID;
@property (readwrite) MPVEndReason endReason;
@property (readwrite) int errorCode;
@property (readwrite, nullable) NSString *errorText;
@property (readwrite, nullable) NSString *propertyName;
@property (readwrite, nullable) id propertyValue;
@end

@implementation MPVEvent
@end

// MARK: - core

@interface MPVCore () {
    mpv_handle *_handle;
    dispatch_queue_t _control;
    atomic_int _wakeupPending;
    void (^_eventHandler)(MPVEvent *);
    NSLock *_handlerLock;
}
- (void)scheduleDrain;
- (mpv_handle *)rawHandle;
@end

static void MPVWakeup(void *context) {
    // 可能從 mpv 的任何執行緒進來，甚至從我們自己的 API 呼叫裡面。
    // 這裡只把工作丟出去；合併重複喚醒，讓 control queue 上永遠最多排著一份。
    MPVCore *core = (__bridge MPVCore *)context;
    [core scheduleDrain];
}

@implementation MPVCore

- (nullable instancetype)initWithLibrary:(MPVLibraryHandle *)library
                                 options:(NSDictionary<NSString *, NSString *> *)options
                                   error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _library = library;
    _handlerLock = [NSLock new];
    _control = dispatch_queue_create("app.foldwall.mpv.control", DISPATCH_QUEUE_SERIAL);

    MPVFunctions *fn = &library->_fn;
    _handle = fn->create();
    if (!_handle) {
        if (error) *error = MPVError(3, @"mpv_create failed");
        return nil;
    }
    for (NSString *key in options) {
        int rc = fn->set_option_string(_handle, key.UTF8String, options[key].UTF8String);
        // 舊版沒有的選項（例如 0.38 沒有 load-select）不算失敗：那些都是「多關一個
        // 內建 script」的保險，沒有那個選項就代表那個 script 也不存在。
        if (rc == MPV_ERROR_OPTION_NOT_FOUND) continue;
        if (rc < 0) {
            if (error) {
                *error = MPVError(4, [NSString stringWithFormat:@"option %@=%@: %s", key,
                                      options[key], fn->error_string(rc)]);
            }
            fn->terminate_destroy(_handle);
            _handle = NULL;
            return nil;
        }
    }
    int rc = fn->initialize(_handle);
    if (rc < 0) {
        if (error) *error = MPVError(5, [NSString stringWithFormat:@"mpv_initialize: %s", fn->error_string(rc)]);
        fn->terminate_destroy(_handle);
        _handle = NULL;
        return nil;
    }
    fn->set_wakeup_callback(_handle, MPVWakeup, (__bridge void *)self);
    return self;
}

- (void)setEventHandler:(nullable void (^)(MPVEvent *))handler {
    [_handlerLock lock];
    _eventHandler = [handler copy];
    [_handlerLock unlock];
}

- (void)scheduleDrain {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&_wakeupPending, &expected, 1)) return;   // 已經排了一份
    dispatch_async(_control, ^{ [self drainEvents]; });
}

- (void)drainEvents {
    // 先清旗標再撈：撈的途中又被喚醒會再排一份，那份多半撈到空的，沒關係。
    atomic_store(&_wakeupPending, 0);
    MPVFunctions *fn = &_library->_fn;
    mpv_handle *handle = _handle;
    if (!handle) return;
    for (;;) {
        mpv_event *event = fn->wait_event(handle, 0);
        if (!event || event->event_id == MPV_EVENT_NONE) break;
        MPVEvent *copy = [self eventFrom:event];
        if (!copy) continue;
        [_handlerLock lock];
        void (^handler)(MPVEvent *) = _eventHandler;
        [_handlerLock unlock];
        if (handler) handler(copy);
        if (copy.kind == MPVEventKindShutdown) break;
    }
}

- (nullable MPVEvent *)eventFrom:(mpv_event *)event {
    MPVFunctions *fn = &_library->_fn;
    MPVEvent *copy = [MPVEvent new];
    switch (event->event_id) {
    case MPV_EVENT_START_FILE: {
        copy.kind = MPVEventKindStartFile;
        mpv_event_start_file *start = event->data;
        copy.playlistEntryID = start ? start->playlist_entry_id : 0;
        return copy;
    }
    case MPV_EVENT_FILE_LOADED:
        copy.kind = MPVEventKindFileLoaded;
        return copy;
    case MPV_EVENT_END_FILE: {
        copy.kind = MPVEventKindEndFile;
        mpv_event_end_file *end = event->data;
        if (end) {
            copy.playlistEntryID = end->playlist_entry_id;
            copy.endReason = (MPVEndReason)end->reason;
            copy.errorCode = end->error;
            if (end->reason == MPV_END_FILE_REASON_ERROR) copy.errorText = @(fn->error_string(end->error));
        }
        return copy;
    }
    case MPV_EVENT_PROPERTY_CHANGE: {
        copy.kind = MPVEventKindPropertyChange;
        mpv_event_property *property = event->data;
        if (!property || !property->name) return nil;
        copy.propertyName = @(property->name);
        switch (property->format) {
        case MPV_FORMAT_STRING:
            copy.propertyValue = property->data ? @(*(char **)property->data) : nil;
            break;
        case MPV_FORMAT_FLAG:
            copy.propertyValue = property->data ? @(*(int *)property->data != 0) : nil;
            break;
        case MPV_FORMAT_INT64:
            copy.propertyValue = property->data ? @(*(int64_t *)property->data) : nil;
            break;
        case MPV_FORMAT_DOUBLE:
            copy.propertyValue = property->data ? @(*(double *)property->data) : nil;
            break;
        case MPV_FORMAT_NODE:
            copy.propertyValue = property->data ? ObjectFromNode((mpv_node *)property->data) : nil;
            break;
        default:
            copy.propertyValue = nil;   // MPV_FORMAT_NONE：屬性目前沒值
        }
        return copy;
    }
    case MPV_EVENT_SHUTDOWN:
        copy.kind = MPVEventKindShutdown;
        return copy;
    default:
        return nil;
    }
}

- (int)observeProperty:(NSString *)name format:(MPVPropertyFormat)format {
    if (!_handle) return MPV_ERROR_UNINITIALIZED;
    return _library->_fn.observe_property(_handle, 0, name.UTF8String, (mpv_format)format);
}

- (nullable NSDictionary<NSString *, id> *)command:(NSArray<NSString *> *)arguments
                                              error:(NSError **)error {
    if (!_handle) {
        if (error) *error = MPVError(6, @"core destroyed");
        return nil;
    }
    MPVFunctions *fn = &_library->_fn;
    NSUInteger count = arguments.count;
    mpv_node *values = calloc(count, sizeof(mpv_node));
    for (NSUInteger i = 0; i < count; i++) {
        values[i].format = MPV_FORMAT_STRING;
        values[i].u.string = (char *)arguments[i].UTF8String;   // 只借用，mpv 會自己複製
    }
    mpv_node_list list = { .num = (int)count, .values = values, .keys = NULL };
    mpv_node args = { .format = MPV_FORMAT_NODE_ARRAY, .u.list = &list };
    mpv_node result = { .format = MPV_FORMAT_NONE };
    int rc = fn->command_node(_handle, &args, &result);
    free(values);
    if (rc < 0) {
        if (error) {
            *error = MPVError(rc, [NSString stringWithFormat:@"%@: %s",
                                   [arguments componentsJoinedByString:@" "], fn->error_string(rc)]);
        }
        return nil;
    }
    id object = ObjectFromNode(&result);
    fn->free_node_contents(&result);
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

- (int)setString:(NSString *)value forProperty:(NSString *)name {
    if (!_handle) return MPV_ERROR_UNINITIALIZED;
    return _library->_fn.set_property_string(_handle, name.UTF8String, value.UTF8String);
}

- (int)setFlag:(BOOL)value forProperty:(NSString *)name {
    if (!_handle) return MPV_ERROR_UNINITIALIZED;
    int flag = value ? 1 : 0;
    return _library->_fn.set_property(_handle, name.UTF8String, MPV_FORMAT_FLAG, &flag);
}

- (int)setDouble:(double)value forProperty:(NSString *)name {
    if (!_handle) return MPV_ERROR_UNINITIALIZED;
    return _library->_fn.set_property(_handle, name.UTF8String, MPV_FORMAT_DOUBLE, &value);
}

- (nullable NSString *)stringForProperty:(NSString *)name {
    if (!_handle) return nil;
    char *text = _library->_fn.get_property_string(_handle, name.UTF8String);
    if (!text) return nil;
    NSString *value = @(text);
    _library->_fn.free(text);
    return value;
}

- (nullable NSNumber *)doubleForProperty:(NSString *)name {
    if (!_handle) return nil;
    double value = 0;
    if (_library->_fn.get_property(_handle, name.UTF8String, MPV_FORMAT_DOUBLE, &value) < 0) return nil;
    return @(value);
}

- (nullable NSNumber *)int64ForProperty:(NSString *)name {
    if (!_handle) return nil;
    int64_t value = 0;
    if (_library->_fn.get_property(_handle, name.UTF8String, MPV_FORMAT_INT64, &value) < 0) return nil;
    return @(value);
}

- (nullable NSNumber *)flagForProperty:(NSString *)name {
    if (!_handle) return nil;
    int value = 0;
    if (_library->_fn.get_property(_handle, name.UTF8String, MPV_FORMAT_FLAG, &value) < 0) return nil;
    return @(value != 0);
}

- (NSString *)errorString:(int)code {
    return @(_library->_fn.error_string(code));
}

- (void)destroy {
    mpv_handle *handle = _handle;
    if (!handle) return;
    // 先關 callback，之後 mpv 不會再叫我們；再把已經排在 control queue 上的那份跑完，
    // 不然它會在 handle 沒了之後才醒來。
    _library->_fn.set_wakeup_callback(handle, NULL, NULL);
    [self setEventHandler:nil];
    dispatch_sync(_control, ^{});
    _handle = NULL;
    _library->_fn.terminate_destroy(handle);
}

- (mpv_handle *)rawHandle {
    return _handle;
}

@end

// MARK: - view

@interface MPVOpenGLView () {
@public
    NSOpenGLContext *_context;
    atomic_int _drawableWidth;
    atomic_int _drawableHeight;
}
@end

@implementation MPVOpenGLView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAAccelerated,
        NSOpenGLPFAColorSize, 24,
        0,
    };
    NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    _context = [[NSOpenGLContext alloc] initWithFormat:format shareContext:nil];
    GLint swapInterval = 1;   // 跟 vsync 走，report_swap 才有意義
    [_context setValues:&swapInterval forParameter:NSOpenGLContextParameterSwapInterval];
    self.wantsBestResolutionOpenGLSurface = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(globalFrameDidChange:)
                                               name:NSViewGlobalFrameDidChangeNotification object:self];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSView *)hitTest:(NSPoint)point {
    return nil;   // 桌布不吃滑鼠事件
}

- (BOOL)isOpaque {
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        [_context setView:self];
        [self updateDrawable];
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self updateDrawable];
}

// 環境光開著時這個 view 只佔影片那一塊，位置會跟著影片比例動。
- (void)setFrameOrigin:(NSPoint)newOrigin {
    [super setFrameOrigin:newOrigin];
    [self updateDrawable];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateDrawable];
}

- (void)globalFrameDidChange:(NSNotification *)note {
    [self updateDrawable];
}

/// 框或縮放比變了：在 CGL 鎖底下讓 context 跟上，再把新的可繪尺寸交給渲染執行緒。
- (void)updateDrawable {
    CGLContextObj cgl = _context.CGLContextObj;
    NSSize pixels = [self convertRectToBacking:self.bounds].size;
    CGLLockContext(cgl);
    [_context update];
    CGLUnlockContext(cgl);
    atomic_store(&_drawableWidth, (int)pixels.width);
    atomic_store(&_drawableHeight, (int)pixels.height);
}

// 不畫：畫面是渲染執行緒直接 flush 到 surface 上的。這裡什麼都不做，
// 也就不會有人在主執行緒把 context 設成 current。
- (void)drawRect:(NSRect)dirtyRect {
}

@end

// MARK: - renderer

/// mpv 的 get_proc_address：從 OpenGL.framework 拿 GL 函式。app 自己沒 link OpenGL，
/// 所以不用 RTLD_DEFAULT，直接開那個 framework。
static void *MPVGLProcAddress(void *context, const char *name) {
    static void *opengl;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        opengl = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_NOW | RTLD_LOCAL);
    });
    return opengl ? dlsym(opengl, name) : NULL;
}

// MARK: - 環境光取樣

@implementation MPVFrameSample
- (instancetype)initWithPixels:(NSData *)pixels width:(int)width height:(int)height {
    self = [super init];
    if (!self) return nil;
    _pixels = pixels;
    _width = width;
    _height = height;
    return self;
}
@end

/// 取樣用到的 GL 函式。app 沒 link OpenGL，跟 mpv 一樣從 framework dlsym。
typedef struct {
    void (*GenFramebuffers)(GLsizei, GLuint *);
    void (*DeleteFramebuffers)(GLsizei, const GLuint *);
    void (*BindFramebuffer)(GLenum, GLuint);
    void (*FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
    GLenum (*CheckFramebufferStatus)(GLenum);
    void (*GenTextures)(GLsizei, GLuint *);
    void (*DeleteTextures)(GLsizei, const GLuint *);
    void (*BindTexture)(GLenum, GLuint);
    void (*TexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
    void (*TexParameteri)(GLenum, GLenum, GLint);
    void (*BlitFramebuffer)(GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum);
    void (*ReadBuffer)(GLenum);
    void (*ReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *);
    void (*GenBuffers)(GLsizei, GLuint *);
    void (*DeleteBuffers)(GLsizei, const GLuint *);
    void (*BindBuffer)(GLenum, GLuint);
    void (*BufferData)(GLenum, GLsizeiptr, const void *, GLenum);
    void *(*MapBuffer)(GLenum, GLenum);
    GLboolean (*UnmapBuffer)(GLenum);
} MPVSampleGL;

static BOOL MPVLoadSampleGL(MPVSampleGL *gl) {
#define GLLOAD(field) \
    do { \
        *(void **)&gl->field = MPVGLProcAddress(NULL, "gl" #field); \
        if (!gl->field) return NO; \
    } while (0)
    GLLOAD(GenFramebuffers);
    GLLOAD(DeleteFramebuffers);
    GLLOAD(BindFramebuffer);
    GLLOAD(FramebufferTexture2D);
    GLLOAD(CheckFramebufferStatus);
    GLLOAD(GenTextures);
    GLLOAD(DeleteTextures);
    GLLOAD(BindTexture);
    GLLOAD(TexImage2D);
    GLLOAD(TexParameteri);
    GLLOAD(BlitFramebuffer);
    GLLOAD(ReadBuffer);
    GLLOAD(ReadPixels);
    GLLOAD(GenBuffers);
    GLLOAD(DeleteBuffers);
    GLLOAD(BindBuffer);
    GLLOAD(BufferData);
    GLLOAD(MapBuffer);
    GLLOAD(UnmapBuffer);
#undef GLLOAD
    return YES;
}

/// 縮圖邊長。環境光只看邊緣色，長寬比不重要（座標是正規化的）。
static const int MPVSampleSize = 64;
/// 縮小的中間層數上限：每層最多縮 4 倍，線性取樣才不會跳過太多像素。
enum { MPVSampleMaxStages = 6 };
/// 環境光更新上限：每秒 12 次。原片照自己的幀率走。
static const double MPVSampleInterval = 1.0 / 12.0;

@interface MPVRenderer () {
    MPVCore *_core;
    MPVOpenGLView *_view;   // 只為了握住 context 的壽命；渲染執行緒只讀它的原子欄位
    CGLContextObj _cgl;
    mpv_render_context *_render;
    dispatch_queue_t _queue;
    atomic_int _updatePending;
    atomic_bool _expectFirstFrame;
    atomic_uint_fast64_t _renderedFrames;
    void (^_firstFrameHandler)(void);
    NSLock *_handlerLock;

    // 環境光取樣。以下 GL 物件只在渲染佇列上碰。
    MPVSampleGL _gl;
    BOOL _glLoaded;
    BOOL _glUnavailable;
    int _stageCount;
    int _stageWidth[MPVSampleMaxStages];
    int _stageHeight[MPVSampleMaxStages];
    GLuint _stageFBO[MPVSampleMaxStages];
    GLuint _stageTexture[MPVSampleMaxStages];
    int _sourceWidth;
    int _sourceHeight;
    GLuint _pbo[2];
    uint64_t _sampleCount;
    double _lastSampleTime;
    MPVFrameSample *_latestSample;   // _handlerLock 保護
}
- (void)scheduleRender;
@end

static void MPVRenderUpdate(void *context) {
    MPVRenderer *renderer = (__bridge MPVRenderer *)context;
    [renderer scheduleRender];
}

@implementation MPVRenderer

- (nullable instancetype)initWithCore:(MPVCore *)core
                                 view:(MPVOpenGLView *)view
                                error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _core = core;
    _view = view;
    _cgl = view->_context.CGLContextObj;
    _handlerLock = [NSLock new];
    // 畫面跟著 vsync，優先權要跟 UI 一樣高，否則被壓在背景 QoS 底下會掉格。
    dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    _queue = dispatch_queue_create("app.foldwall.mpv.render", attributes);

    __block int rc = 0;
    __block mpv_render_context *render = NULL;
    MPVFunctions *fn = &core.library->_fn;
    mpv_handle *handle = [core rawHandle];
    CGLContextObj cgl = _cgl;
    // render context 要在它之後每次渲染都用的那條執行緒、那個 GL context 底下建。
    dispatch_sync(_queue, ^{
        CGLLockContext(cgl);
        CGLSetCurrentContext(cgl);
        mpv_opengl_init_params gl = { .get_proc_address = MPVGLProcAddress, .get_proc_address_ctx = NULL };
        int advanced = 1;
        mpv_render_param params[] = {
            { MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL },
            { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl },
            // 我們遵守 render.h 的規則（渲染執行緒不等 core），換來直接渲染到 texture。
            { MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced },
            { 0, NULL },
        };
        rc = fn->render_context_create(&render, handle, params);
        CGLUnlockContext(cgl);
    });
    if (rc < 0 || !render) {
        if (error) *error = MPVError(7, [NSString stringWithFormat:@"mpv_render_context_create: %s", fn->error_string(rc)]);
        return nil;
    }
    _render = render;
    // advanced control 要求 update callback 要「夠快」設好，不然 core 會等我們。
    fn->render_context_set_update_callback(render, MPVRenderUpdate, (__bridge void *)self);
    return self;
}

- (uint64_t)renderedFrames {
    return atomic_load(&_renderedFrames);
}

- (void)setFirstFrameHandler:(nullable void (^)(void))handler {
    [_handlerLock lock];
    _firstFrameHandler = [handler copy];
    [_handlerLock unlock];
}

- (void)expectFirstFrame {
    atomic_store(&_expectFirstFrame, true);
}

- (void)scheduleRender {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&_updatePending, &expected, 1)) return;
    dispatch_async(_queue, ^{ [self renderIfUpdated]; });
}

- (void)redraw {
    dispatch_async(_queue, ^{ [self renderFrame]; });
}

/// 渲染佇列上：問 mpv 有沒有新格，有才畫。
- (void)renderIfUpdated {
    atomic_store(&_updatePending, 0);
    if (!_render) return;
    uint64_t flags = _core.library->_fn.render_context_update(_render);
    if (flags & MPV_RENDER_UPDATE_FRAME) [self renderFrame];
}

/// 渲染佇列上：把目前這格畫到預設 framebuffer、flush、回報 swap。
- (void)renderFrame {
    if (!_render) return;
    MPVFunctions *fn = &_core.library->_fn;
    int width = atomic_load(&_view->_drawableWidth);
    int height = atomic_load(&_view->_drawableHeight);
    if (width <= 0 || height <= 0) return;

    CGLLockContext(_cgl);
    CGLSetCurrentContext(_cgl);
    mpv_opengl_fbo fbo = { .fbo = 0, .w = width, .h = height, .internal_format = 0 };
    int flipY = 1;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &fbo },
        { MPV_RENDER_PARAM_FLIP_Y, &flipY },
        { 0, NULL },
    };
    int rc = fn->render_context_render(_render, params);
    if (rc >= 0 && self.samplingEnabled) {
        [self captureSampleFromWidth:width height:height];
    } else if (!self.samplingEnabled && _stageCount > 0) {
        [self releaseSampleResources];
    }
    CGLFlushDrawable(_cgl);
    fn->render_context_report_swap(_render);
    CGLUnlockContext(_cgl);
    if (rc < 0) return;

    atomic_fetch_add(&_renderedFrames, 1);
    bool expected = true;
    if (atomic_compare_exchange_strong(&_expectFirstFrame, &expected, false)) {
        [_handlerLock lock];
        void (^handler)(void) = _firstFrameHandler;
        [_handlerLock unlock];
        if (handler) dispatch_async(dispatch_get_main_queue(), handler);
    }
}

// MARK: 環境光取樣（渲染佇列上、GL context current）

- (nullable MPVFrameSample *)takeSample {
    [_handlerLock lock];
    MPVFrameSample *sample = _latestSample;
    _latestSample = nil;
    [_handlerLock unlock];
    return sample;
}

/// 依來源尺寸排好縮小鏈：每層縮 4 倍，最後一層是 64×64。
- (BOOL)prepareStagesForWidth:(int)width height:(int)height {
    if (_stageCount > 0 && width == _sourceWidth && height == _sourceHeight) return YES;
    [self releaseStages];
    int w = width, h = height;
    int count = 0;
    while (count < MPVSampleMaxStages - 1 && (w > MPVSampleSize * 4 || h > MPVSampleSize * 4)) {
        w = w > MPVSampleSize * 4 ? w / 4 : w;
        h = h > MPVSampleSize * 4 ? h / 4 : h;
        _stageWidth[count] = w;
        _stageHeight[count] = h;
        count++;
    }
    _stageWidth[count] = MPVSampleSize;
    _stageHeight[count] = MPVSampleSize;
    count++;

    _gl.GenFramebuffers(count, _stageFBO);
    _gl.GenTextures(count, _stageTexture);
    BOOL complete = YES;
    for (int i = 0; i < count; i++) {
        _gl.BindTexture(GL_TEXTURE_2D, _stageTexture[i]);
        _gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        _gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        _gl.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, _stageWidth[i], _stageHeight[i], 0,
                       GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        _gl.BindFramebuffer(GL_FRAMEBUFFER, _stageFBO[i]);
        _gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _stageTexture[i], 0);
        if (_gl.CheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) complete = NO;
    }
    _gl.BindTexture(GL_TEXTURE_2D, 0);
    _gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
    _stageCount = count;
    _sourceWidth = width;
    _sourceHeight = height;

    if (!_pbo[0]) {
        _gl.GenBuffers(2, _pbo);
        for (int i = 0; i < 2; i++) {
            _gl.BindBuffer(GL_PIXEL_PACK_BUFFER, _pbo[i]);
            _gl.BufferData(GL_PIXEL_PACK_BUFFER, MPVSampleSize * MPVSampleSize * 4, NULL, GL_STREAM_READ);
        }
        _gl.BindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    }
    _sampleCount = 0;
    if (!complete) [self releaseSampleResources];
    return complete;
}

- (void)captureSampleFromWidth:(int)width height:(int)height {
    if (_glUnavailable) return;
    double now = CACurrentMediaTime();
    if (now - _lastSampleTime < MPVSampleInterval) return;
    _lastSampleTime = now;
    if (!_glLoaded) {
        _glLoaded = YES;
        if (!MPVLoadSampleGL(&_gl)) {
            _glUnavailable = YES;   // 拿不到就不做環境光，影片照播
            return;
        }
    }
    if (![self prepareStagesForWidth:width height:height]) return;

    // 預設 framebuffer（剛畫好的 back buffer）一層層縮到 64×64。
    _gl.BindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    _gl.ReadBuffer(GL_BACK);
    int srcW = width, srcH = height;
    for (int i = 0; i < _stageCount; i++) {
        _gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, _stageFBO[i]);
        _gl.BlitFramebuffer(0, 0, srcW, srcH, 0, 0, _stageWidth[i], _stageHeight[i],
                            GL_COLOR_BUFFER_BIT, GL_LINEAR);
        _gl.BindFramebuffer(GL_READ_FRAMEBUFFER, _stageFBO[i]);
        _gl.ReadBuffer(GL_COLOR_ATTACHMENT0);
        srcW = _stageWidth[i];
        srcH = _stageHeight[i];
    }

    // 這一次排進 PBO（非同步），讀回的是上一次排的那份——那份早就畫完了，不等 GPU。
    GLuint write = _pbo[_sampleCount % 2];
    GLuint read = _pbo[(_sampleCount + 1) % 2];
    _gl.BindBuffer(GL_PIXEL_PACK_BUFFER, write);
    _gl.ReadPixels(0, 0, MPVSampleSize, MPVSampleSize, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    if (_sampleCount > 0) {
        _gl.BindBuffer(GL_PIXEL_PACK_BUFFER, read);
        void *mapped = _gl.MapBuffer(GL_PIXEL_PACK_BUFFER, GL_READ_ONLY);
        if (mapped) {
            NSData *pixels = [NSData dataWithBytes:mapped length:MPVSampleSize * MPVSampleSize * 4];
            _gl.UnmapBuffer(GL_PIXEL_PACK_BUFFER);
            MPVFrameSample *sample = [[MPVFrameSample alloc] initWithPixels:pixels
                                                                      width:MPVSampleSize
                                                                     height:MPVSampleSize];
            [_handlerLock lock];
            _latestSample = sample;
            [_handlerLock unlock];
        }
    }
    _sampleCount++;

    // 還原成 mpv 期待的預設狀態（render_gl.h「OpenGL state」）。
    _gl.BindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    _gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
    _gl.ReadBuffer(GL_BACK);
}

- (void)releaseStages {
    if (_stageCount == 0) return;
    _gl.DeleteFramebuffers(_stageCount, _stageFBO);
    _gl.DeleteTextures(_stageCount, _stageTexture);
    memset(_stageFBO, 0, sizeof(_stageFBO));
    memset(_stageTexture, 0, sizeof(_stageTexture));
    _stageCount = 0;
    _sourceWidth = 0;
    _sourceHeight = 0;
}

- (void)releaseSampleResources {
    if (!_glLoaded || _glUnavailable) return;
    [self releaseStages];
    if (_pbo[0]) {
        _gl.DeleteBuffers(2, _pbo);
        _pbo[0] = _pbo[1] = 0;
    }
    _sampleCount = 0;
    [_handlerLock lock];
    _latestSample = nil;
    [_handlerLock unlock];
}

- (void)shutdown {
    mpv_render_context *render = _render;
    if (!render) return;
    MPVFunctions *fn = &_core.library->_fn;
    // 先拿掉 callback：之後 mpv 不會再叫 scheduleRender。已經排在佇列上的那份
    // 會在底下的 dispatch_sync 之前跑完，而它看到的 _render 還在，沒關係——
    // free 是在同一條佇列上、排在它後面。
    fn->render_context_set_update_callback(render, NULL, NULL);
    [self setFirstFrameHandler:nil];
    CGLContextObj cgl = _cgl;
    dispatch_sync(_queue, ^{
        CGLLockContext(cgl);
        CGLSetCurrentContext(cgl);
        [self releaseSampleResources];
        fn->render_context_free(render);
        CGLSetCurrentContext(NULL);
        CGLUnlockContext(cgl);
        self->_render = NULL;
    });
}

@end
