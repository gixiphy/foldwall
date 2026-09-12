//  MPVBridge.h
//  libmpv 的橋接層。**所有 C 指標、callback、OpenGL 都關在這裡**，Swift 端只看到
//  幾個物件：載入好的函式庫、一個 core、一個 renderer、一個 view。
//
//  libmpv 用 dlopen 在執行期載入，不在連結期綁定：app 沒有 mpv 也要能啟動。
//  函式一律用 dlsym 取，這個檔案不 link 任何 mpv 符號；標頭只用型別與常數
//  （ThirdParty/mpv，ISC 授權，釘死 v0.40.0）。
//
//  執行緒規則（照 render.h 的契約）：
//  - mpv 的一般 API 執行緒安全，但 mpv_wait_event 一個 handle 只能有一條執行緒在等——
//    這裡是 core 自己的序列佇列（control queue）。
//  - mpv_render_* 全部在 renderer 自己的序列佇列上呼叫，GL context 在那條執行緒 current；
//    那條執行緒**不呼叫任何其他 libmpv API**，也不等主執行緒。
//  - 兩個 callback（wakeup、render update）只把工作丟到對應佇列，自己什麼都不做。
//  - 主執行緒只管 NSView／NSWindow。

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const MPVBridgeErrorDomain;

/// 已 dlopen 的 libmpv。一個行程只開一次、握到行程結束（見 MPVRuntime 的說明）。
NS_SWIFT_SENDABLE
@interface MPVLibraryHandle : NSObject

/// dlopen 加 dlsym 一整組符號。任何一個缺就失敗；`error` 的
/// `NSLocalizedDescription` 是 dlerror() 原文（給 MPVRuntime.classifyLoadError 分類）。
+ (nullable instancetype)openAtPath:(NSString *)path error:(NSError **)error;

/// `mpv_client_api_version()`：**執行期載入的那份**的 API 版本，跟標頭不一定同。
@property (readonly) unsigned long clientAPIVersion;

/// 開一個暫時 core 讀 `mpv-version`，讀完就銷毀。`options` 用 MPVRuntime.probeOptions：
/// 不接輸出、**內建 script 全關**（否則 LuaJIT 在 Hardened Runtime 底下會把整個
/// app SIGKILL）。載入後第一件事就是看版本夠不夠，不必等到真的播才知道。
- (nullable NSString *)probeVersionStringWithOptions:(NSDictionary<NSString *, NSString *> *)options
    NS_SWIFT_NAME(probeVersionString(options:));

@end

typedef NS_ENUM(NSInteger, MPVEventKind) {
    MPVEventKindStartFile = 1,
    MPVEventKindFileLoaded,
    MPVEventKindEndFile,
    MPVEventKindPropertyChange,
    MPVEventKindShutdown,
};

/// 對應 mpv_end_file_reason 的值。
typedef NS_ENUM(NSInteger, MPVEndReason) {
    MPVEndReasonEndOfFile = 0,
    MPVEndReasonStop = 2,
    MPVEndReasonQuit = 3,
    MPVEndReasonError = 4,
    MPVEndReasonRedirect = 5,
};

/// 對應 mpv_format 的值。
typedef NS_ENUM(NSInteger, MPVPropertyFormat) {
    MPVPropertyFormatString = 1,
    MPVPropertyFormatFlag = 3,
    MPVPropertyFormatInt64 = 4,
    MPVPropertyFormatDouble = 5,
    MPVPropertyFormatNode = 6,
};

/// 一則 mpv 事件，已經從 C 結構抄成不可變物件，可以跨執行緒丟。
NS_SWIFT_SENDABLE
@interface MPVEvent : NSObject
@property (readonly) MPVEventKind kind;
/// start／end file 帶的 playlist entry id。`loadfile` 的回傳值也是這個 id，
/// 拿它對才分得出「播完的是哪一支」——同一支被重播時 URL 分不出來。
@property (readonly) int64_t playlistEntryID;
@property (readonly) MPVEndReason endReason;
/// endReason 是 Error 時的 mpv 錯誤碼。
@property (readonly) int errorCode;
@property (readonly, nullable) NSString *errorText;
@property (readonly, nullable) NSString *propertyName;
/// NSString／NSNumber／NSDictionary／NSArray；屬性目前沒值就是 nil。
@property (readonly, nullable) id propertyValue;
@end

/// 一個 mpv core（`mpv_create`＋`mpv_initialize`）。每台螢幕一個。
NS_SWIFT_SENDABLE
@interface MPVCore : NSObject

/// 建好並初始化。`options` 全部在 initialize 之前用 `mpv_set_option_string` 設。
- (nullable instancetype)initWithLibrary:(MPVLibraryHandle *)library
                                 options:(NSDictionary<NSString *, NSString *> *)options
                                   error:(NSError **)error;

@property (readonly) MPVLibraryHandle *library;

/// 事件回呼。**在 core 的 control queue 上呼叫**，不在主執行緒；
/// 收到的人自己跳回主執行緒。設 nil 就不再送。
- (void)setEventHandler:(nullable void (NS_SWIFT_SENDABLE ^)(MPVEvent *event))handler;

/// `mpv_observe_property`。值以 MPVEventKindPropertyChange 送來。
- (int)observeProperty:(NSString *)name format:(MPVPropertyFormat)format;

/// 同步下指令（`mpv_command_node`）。回傳指令的結果（`loadfile` 會回
/// `playlist_entry_id`），沒有結果就是空字典；失敗回 nil 並填 error。
- (nullable NSDictionary<NSString *, id> *)command:(NSArray<NSString *> *)arguments
                                              error:(NSError **)error;

- (int)setString:(NSString *)value forProperty:(NSString *)name;
- (int)setFlag:(BOOL)value forProperty:(NSString *)name;
- (int)setDouble:(double)value forProperty:(NSString *)name;

- (nullable NSString *)stringForProperty:(NSString *)name;
- (nullable NSNumber *)doubleForProperty:(NSString *)name;
- (nullable NSNumber *)int64ForProperty:(NSString *)name;
- (nullable NSNumber *)flagForProperty:(NSString *)name;

- (NSString *)errorString:(int)code;

/// `mpv_terminate_destroy`。**會等 core 收乾淨，別在主執行緒叫。**
/// renderer 要先 shutdown（render.h：render context 必須先於 core 釋放）。
- (void)destroy;

@end

/// 放進桌布視窗的 view。hitTest 回 nil（點擊穿透），自己帶一個 NSOpenGLContext，
/// 框改變時在 CGL 鎖底下 update。**主執行緒以外不碰它**——renderer 只拿它的
/// CGL context 與（原子的）可繪尺寸。
@interface MPVOpenGLView : NSView
- (instancetype)initWithFrame:(NSRect)frame;
@end

/// 一台螢幕的渲染執行緒：收 mpv 的 update callback、在自己的佇列上
/// `mpv_render_context_render`、flush、report_swap。
NS_SWIFT_SENDABLE
@interface MPVRenderer : NSObject

/// 在渲染佇列上建 render context（GL context 在那條執行緒 current）。
/// 要在主執行緒呼叫（會讀 view）；失敗回 nil。
- (nullable instancetype)initWithCore:(MPVCore *)core
                                 view:(MPVOpenGLView *)view
                                error:(NSError **)error;

/// 真的畫出去幾格。**是 render 呼叫數，不是螢幕實際出畫數**——診斷不要拿它當掉幀證據。
@property (readonly) uint64_t renderedFrames;

/// 第一格。`expectFirstFrame` 之後的下一次成功渲染，在主執行緒叫一次。
- (void)setFirstFrameHandler:(nullable void (NS_SWIFT_SENDABLE ^)(void))handler;
- (void)expectFirstFrame;

/// 框改了之後把最後一格再畫一次，不必等 mpv 送新格。
- (void)redraw;

/// 拿掉 callback、在渲染佇列上 free render context。同步；之後 core 才可以 destroy。
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
