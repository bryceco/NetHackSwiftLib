#import "NetHackBridge.h"
#include <string.h>
#include <stdlib.h>

// Forward-declare libnh entry points; resolved at link time from libnh.a.
extern int  nhmain(int argc, char *argv[]);
extern void nhswift_set_callbacks(const nhswift_callbacks *cb);
extern void nhswift_set_paths(const char *hackdir, const char *playground);

// ---------------------------------------------------------------------------
// NHMenuSelection
// ---------------------------------------------------------------------------

@implementation NHMenuSelection

- (instancetype)initWithIdentifier:(uintptr_t)identifier count:(long)count {
    self = [super init];
    if (self) {
        _identifier = identifier;
        _count = count;
    }
    return self;
}

@end

// ---------------------------------------------------------------------------
// NetHackBridge — private interface
// ---------------------------------------------------------------------------

@interface NetHackBridge ()
/// Filesystem paths stored from runWithHackdirURL:; used by cb_initWindows.
/// Both paths are guaranteed to end with '/'.
@property (nonatomic, copy) NSString *hackdirPath;
@property (nonatomic, copy) NSString *playgroundPath;
/// Dispatch an output event to the delegate on the main thread and wait for
/// it to complete before returning (preserves ordering between callbacks).
- (void)dispatchOutput:(void (^)(void))block;
/// Dispatch a blocking input request to the delegate on the main thread.
/// `block` receives a `done` callback; when the delegate has obtained user
/// input and wants to unblock the NetHack thread it calls done().
- (void)dispatchInput:(void (^)(void (^done)(void)))block;
@end

// ---------------------------------------------------------------------------
// C callbacks — run on the NetHack background (game) thread.
// These are installed into nhswift_callbacks and called directly by libnh.
// ---------------------------------------------------------------------------

static NetHackBridge          *_activeBridge   = nil;
static id<NetHackBridgeDelegate> _activeDelegate = nil;

// --- Lifecycle ---

static void cb_initWindows(int *argcp, char **argv) {
    // Set paths on the NetHack thread, before the delegate sees initWindows.
    nhswift_set_paths(_activeBridge.hackdirPath.fileSystemRepresentation,
                      _activeBridge.playgroundPath.fileSystemRepresentation);
    [_activeBridge dispatchOutput:^{
        [_activeDelegate initWindows];
    }];
}

static void cb_exitWindows(const char *lastgasp) {
    NSString *msg = lastgasp ? @(lastgasp) : nil;
    [_activeBridge dispatchOutput:^{
        [_activeDelegate exitWindowsWithMessage:msg];
    }];
}

static void cb_suspendWindows(const char *str) {
    NSString *msg = str ? @(str) : nil;
    [_activeBridge dispatchOutput:^{
        [_activeDelegate suspendWindowsWithMessage:msg];
    }];
}

static void cb_resumeWindows(void) {
    [_activeBridge dispatchOutput:^{
        [_activeDelegate resumeWindows];
    }];
}

// --- Character creation ---

static int cb_playerSelection(void) {
    // Return 1 to let NetHack run its own built-in selection dialog.
    // Change to 0 once we populate flags.initrole/initrace/initgend/initalign
    // ourselves (e.g. via a custom PlayerSelectionView modal).
    return 1;
}

static void cb_askName(char *buf, int bufsize) {
    // Write an empty string so NetHack prompts for the name via getLine.
    if (buf && bufsize > 0) buf[0] = '\0';
}

// --- Window lifecycle ---

static int cb_createWindow(int type) {
    // Assign a stable window ID and notify the delegate synchronously so it
    // can set up any bookkeeping for this window before the next callback.
    static int nextWindowID = 1;
    int windowID = nextWindowID++;
    NHWindowType windowType = (NHWindowType)type;
    [_activeBridge dispatchOutput:^{
        [_activeDelegate createNhwindow:windowID type:windowType];
    }];
    return windowID;
}

static void cb_clearWindow(int window) {
    [_activeBridge dispatchOutput:^{
        [_activeDelegate clearNhwindow:window];
    }];
}

static void cb_displayWindow(int window, int blocking) {
    // When blocking=1, the delegate is expected to show a modal panel
    // (e.g. via NSApp.runModal).  dispatch_sync keeps the game thread
    // paused until the delegate returns, which happens after stopModal.
    [_activeBridge dispatchOutput:^{
        [_activeDelegate displayNhwindow:window blocking:(BOOL)blocking];
    }];
}

static void cb_destroyWindow(int window) {
    [_activeBridge dispatchOutput:^{
        [_activeDelegate destroyNhwindow:window];
    }];
}

static void cb_moveCursor(int window, int x, int y) {
    [_activeBridge dispatchOutput:^{
        [_activeDelegate moveCursorIn:window x:x y:y];
    }];
}

static void cb_putString(int window, int attr, const char *str) {
    NSString *text = str ? @(str) : @"";
    [_activeBridge dispatchOutput:^{
        [_activeDelegate putStringIn:window
                              string:text
                           attribute:(NHTextAttribute)attr];
    }];
}

static void cb_displayFile(const char *name, int complain) {
    NSString *file = name ? @(name) : @"";
    [_activeBridge dispatchOutput:^{
        [_activeDelegate displayFile:file complain:(BOOL)complain];
    }];
}

// --- Map ---

static void cb_printGlyph(int window, int x, int y,
                           const nhswift_glyph *gi,
                           const nhswift_glyph *bkgi) {
    // Pointers are valid only for this call; dispatchOutput is synchronous
    // so the delegate receives them while they are still live.
    [_activeBridge dispatchOutput:^{
        [_activeDelegate printGlyphIn:window
                                    x:x
                                    y:y
                            glyphInfo:(const void *)gi
                  backgroundGlyphInfo:(const void *)bkgi];
    }];
}

static void cb_clipAround(int x, int y) {
    [_activeBridge dispatchOutput:^{
        [_activeDelegate clipAroundX:x y:y];
    }];
}

// --- Menus ---

static void cb_startMenu(int window, unsigned long mbehavior) {
    [_activeBridge dispatchOutput:^{
        [_activeDelegate startMenuIn:window behavior:mbehavior];
    }];
}

static void cb_addMenu(int window, const nhswift_glyph *gi,
                       int ch, int gch, int attr, int clr,
                       const char *str, unsigned int itemflags,
                       uintptr_t identifier) {
    NSString *text = str ? @(str) : @"";
    [_activeBridge dispatchOutput:^{
        [_activeDelegate addMenuItemIn:window
                                 accel:(char)ch
                            groupAccel:(char)gch
                                  attr:attr
                                 color:clr
                                string:text
                                 flags:itemflags
                             glyphInfo:(const void *)gi
                            identifier:identifier];
    }];
}

static void cb_endMenu(int window, const char *prompt) {
    NSString *promptStr = prompt ? @(prompt) : nil;
    [_activeBridge dispatchOutput:^{
        [_activeDelegate endMenuIn:window prompt:promptStr];
    }];
}

static int cb_selectMenu(int window, int how,
                         nhswift_menu_item **out_items) {
    __block int result = NHSWIFT_MENU_CANCELLED;
    [_activeBridge dispatchInput:^(void (^done)(void)) {
        [_activeDelegate selectMenuIn:window
                                  how:how
                           completion:^(NSArray<NHMenuSelection *> *selections) {
            if (!selections) {
                result = NHSWIFT_MENU_CANCELLED;
            } else {
                NSInteger n = (NSInteger)selections.count;
                if (n > 0 && out_items) {
                    nhswift_menu_item *items = (nhswift_menu_item *)
                        malloc((size_t)n * sizeof(nhswift_menu_item));
                    for (NSInteger i = 0; i < n; i++) {
                        items[i].identifier = selections[i].identifier;
                        items[i].count      = selections[i].count;
                        items[i].itemflags  = 0;
                    }
                    *out_items = items;
                }
                result = (int)n;
            }
            done();
        }];
    }];
    return result;
}

static int cb_messageMenu(int let, int how, const char *mesg) {
    // Not handled; return 0 so the library falls back to its default.
    (void)let; (void)how; (void)mesg;
    return 0;
}

// --- Input ---

static int cb_getChar(void) {
    __block int result = 0;
    [_activeBridge dispatchInput:^(void (^done)(void)) {
        [_activeDelegate needsKeyInput:^(int key) {
            result = key;
            done();
        }];
    }];
    return result;
}

static int cb_posKey(int *x, int *y, int *mod) {
    __block int result = 0;
    [_activeBridge dispatchInput:^(void (^done)(void)) {
        [_activeDelegate needsKeyOrMouseInput:^(int key, int mx, int my, int mmod) {
            result = key;
            if (key == 0) {   // map-position click
                if (x)   *x   = mx;
                if (y)   *y   = my;
                if (mod) *mod = mmod;
            }
            done();
        }];
    }];
    return result;
}

static int cb_ynFunction(const char *query, const char *resp, int def) {
    // Not yet implemented; return the default character.
    (void)query; (void)resp;
    return def;
}

static void cb_getLine(const char *query, char *buf, int bufsize) {
    NSString *promptStr = query ? @(query) : @"";
    [_activeBridge dispatchInput:^(void (^done)(void)) {
        [_activeDelegate needsLineInput:promptStr
                             completion:^(NSString *response) {
            if (response) {
                strlcpy(buf, response.UTF8String, (size_t)bufsize);
            } else {
                // nil = cancel; ESC + NUL signals cancellation to NetHack.
                if (bufsize > 1) { buf[0] = '\033'; buf[1] = '\0'; }
            }
            done();
        }];
    }];
}

static int cb_getExtCmd(void) {
    // Not yet implemented.
    return -1;
}

static int cb_prevMessage(void) {
    // Not yet implemented.
    return 0;
}

// --- Misc / no-ops ---

static void cb_getEvent(void)    {}
static void cb_markSynch(void)   {}
static void cb_waitSynch(void)   {}
static void cb_delayOutput(void) {}
static void cb_bell(void)        {}

static void cb_rawPrint(const char *str) {
    NSString *text = str ? @(str) : @"";
    [_activeBridge dispatchOutput:^{
        [_activeDelegate rawPrint:text];
    }];
}

static void cb_rawPrintBold(const char *str) {
    NSString *text = str ? @(str) : @"";
    [_activeBridge dispatchOutput:^{
        [_activeDelegate rawPrintBold:text];
    }];
}

static void cb_preferenceUpdate(const char *pref) {
    (void)pref;  // Ignored.
}

static void cb_updateInventory(int arg) {
    (void)arg;
    [_activeBridge dispatchOutput:^{
        [_activeDelegate updateInventory];
    }];
}

static void cb_updatePositionBar(const char *posbar) {
    NSString *bar = posbar ? @(posbar) : @"";
    [_activeBridge dispatchOutput:^{
        [_activeDelegate updatePositionBar:bar];
    }];
}

// --- Message history ---

static int cb_getMsgHistory(int init, char *buf, int bufsize) {
    (void)init; (void)buf; (void)bufsize;
    // No message history to save.
    return 0;
}

static void cb_putMsgHistory(const char *msg, int restoring) {
    NSString *msgStr = msg ? @(msg) : nil;
    [_activeBridge dispatchOutput:^{
        [_activeDelegate putMessageHistory:msgStr restoring:(BOOL)restoring];
    }];
}

// --- Status ---

static void cb_statusInit(void) {
    [_activeBridge dispatchOutput:^{
        [_activeDelegate initStatus];
    }];
}

static void cb_statusEnableField(int fieldidx, const char *nm,
                                 const char *fmt, int enable)
{
    NSString *nameStr = nm  ? @(nm)  : @"";
    NSString *fmtStr  = fmt ? @(fmt) : @"";
    [_activeBridge dispatchOutput:^{
        [_activeDelegate enableStatusField:fieldidx
                                      name:nameStr
                                    format:fmtStr
                                   enabled:(BOOL)enable];
    }];
}

static void cb_statusUpdate(int fldidx, const char *text, long condbits,
                            int chg, int percent, int color,
                            const unsigned long *colormasks)
{
    // text and colormasks are valid only for this call; dispatchOutput is
    // synchronous so the delegate receives them while they are still live.
    NSString *textStr = text ? @(text) : nil;
    [_activeBridge dispatchOutput:^{
        [_activeDelegate updateStatusField:fldidx
                                      text:textStr
                                  condBits:condbits
                                    change:chg
                                   percent:percent
                                     color:color
                                colorMasks:colormasks];
    }];
}

// ---------------------------------------------------------------------------
// Callback table
// ---------------------------------------------------------------------------

static const nhswift_callbacks kBridgeCallbacks = {
    .initWindows       = cb_initWindows,
    .exitWindows       = cb_exitWindows,
    .suspendWindows    = cb_suspendWindows,
    .resumeWindows     = cb_resumeWindows,
    .playerSelection   = cb_playerSelection,
    .askName           = cb_askName,
    .createWindow      = cb_createWindow,
    .clearWindow       = cb_clearWindow,
    .displayWindow     = cb_displayWindow,
    .destroyWindow     = cb_destroyWindow,
    .moveCursor        = cb_moveCursor,
    .putString         = cb_putString,
    .displayFile       = cb_displayFile,
    .printGlyph        = cb_printGlyph,
    .clipAround        = cb_clipAround,
    .startMenu         = cb_startMenu,
    .addMenu           = cb_addMenu,
    .endMenu           = cb_endMenu,
    .selectMenu        = cb_selectMenu,
    .messageMenu       = cb_messageMenu,
    .getChar           = cb_getChar,
    .posKey            = cb_posKey,
    .ynFunction        = cb_ynFunction,
    .getLine           = cb_getLine,
    .getExtCmd         = cb_getExtCmd,
    .prevMessage       = cb_prevMessage,
    .numberPad         = NULL,       // no-op default from winswift.c
    .getEvent          = cb_getEvent,
    .markSynch         = cb_markSynch,
    .waitSynch         = cb_waitSynch,
    .delayOutput       = cb_delayOutput,
    .bell              = cb_bell,
    .rawPrint          = cb_rawPrint,
    .rawPrintBold      = cb_rawPrintBold,
    .preferenceUpdate  = cb_preferenceUpdate,
    .updateInventory   = cb_updateInventory,
    .updatePositionBar = cb_updatePositionBar,
    .getMsgHistory     = cb_getMsgHistory,
    .putMsgHistory     = cb_putMsgHistory,
    .statusInit        = cb_statusInit,
    .statusEnableField = cb_statusEnableField,
    .statusUpdate      = cb_statusUpdate,
    .changeColor       = NULL,       // unused unless built with CHANGE_COLOR
    .getColorString    = NULL,       // unused unless built with CHANGE_COLOR
};

// ---------------------------------------------------------------------------
// NetHackBridge
// ---------------------------------------------------------------------------

@implementation NetHackBridge

- (void)runWithHackdirURL:(NSURL *)hackdirURL
            playgroundURL:(NSURL *)playgroundURL
               completion:(nullable void (^)(int))completion
{
    NSString *hackdir    = hackdirURL.path;
    NSString *playground = playgroundURL.path;
    if (![hackdir hasSuffix:@"/"])    hackdir    = [hackdir    stringByAppendingString:@"/"];
    if (![playground hasSuffix:@"/"]) playground = [playground stringByAppendingString:@"/"];
    self.hackdirPath    = hackdir;
    self.playgroundPath = playground;
    _activeBridge   = self;
    _activeDelegate = self.delegate;
    nhswift_set_callbacks(&kBridgeCallbacks);

	// nhmain takes argv[] but we have no additional arguments to pass now
	// that paths are set via nhswift_set_paths (called inside cb_initWindows).
	int argc = 1;
	char *progname = strdup("nethack");
	char **argv = malloc(2 * sizeof(char *));
	argv[0] = progname;
	argv[1] = NULL;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int result = nhmain(argc, argv);
        free(argv[0]);
        free(argv);

        _activeBridge   = nil;
        _activeDelegate = nil;

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    });
}

- (void)dispatchOutput:(void (^)(void))block {
    // Use dispatch_sync so each output callback fully completes before the
    // NetHack thread issues the next one.  This preserves ordering and
    // prevents races on shared model objects.
    dispatch_sync(dispatch_get_main_queue(), block);
}

- (void)dispatchInput:(void (^)(void (^)(void)))block {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        block(^{ dispatch_semaphore_signal(sem); });
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
}

@end
