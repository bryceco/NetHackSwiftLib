#import "NetHackBridge.h"
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

// Forward-declare libnh symbols; resolved at link time from libnh.a.
typedef void (*shim_callback_t)(const char *name, void *ret_ptr, const char *fmt, ...);
extern void shim_graphics_set_callback(shim_callback_t cb);
extern int  nhmain(int argc, char *argv[]);

// ---------------------------------------------------------------------------
// Path prefix table — mirrors the relevant prefix of struct instance_globals_f
// (include/decl.h).  Only the first two fields are declared here; the struct
// in libnh.a has many more, but we never touch them through this view.
// ---------------------------------------------------------------------------
#define NH_PREFIX_COUNT   10   // PREFIX_COUNT  (include/hack.h)
#define NH_DATAPREFIX      4   // DATAPREFIX
#define NH_SYSCONFPREFIX   7   // SYSCONFPREFIX

struct _nh_gf_paths {
    void *ftrap;                        // struct trap *ftrap  (one pointer)
    char *fqn_prefix[NH_PREFIX_COUNT];  // char *fqn_prefix[PREFIX_COUNT]
};
extern struct _nh_gf_paths gf;

static void
nhbridge_set_paths(const char *playground, const char *resources)
{
    int i;
    for (i = 0; i < NH_PREFIX_COUNT; i++)
        gf.fqn_prefix[i] = strdup(playground);
    gf.fqn_prefix[NH_DATAPREFIX]    = strdup(resources);
    gf.fqn_prefix[NH_SYSCONFPREFIX] = strdup(resources);
}

// NetHack's input buffer size (see include/global.h)
#define BUFSZ 256

// ---------------------------------------------------------------------------
// NHInputRequest — private interface
// ---------------------------------------------------------------------------

@interface NHInputRequest ()
@property (nonatomic) dispatch_semaphore_t semaphore;
- (instancetype)initWithReturnPointer:(nullable void *)returnPointer;
- (void)waitForFulfillment;
@end

@implementation NHInputRequest

- (instancetype)initWithReturnPointer:(nullable void *)returnPointer {
    self = [super init];
    if (self) {
        _returnPointer = returnPointer;
        _semaphore = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)fulfill {
    dispatch_semaphore_signal(_semaphore);
}

- (void)waitForFulfillment {
    dispatch_semaphore_wait(_semaphore, DISPATCH_TIME_FOREVER);
}

@end

// ---------------------------------------------------------------------------
// NHLineInputRequest — private interface + implementation
// ---------------------------------------------------------------------------

@interface NHLineInputRequest ()
- (instancetype)initWithBuffer:(char *)bufp prompt:(NSString *)prompt;
@end

@implementation NHLineInputRequest {
    char *_bufp;
}

- (instancetype)initWithBuffer:(char *)bufp prompt:(NSString *)prompt {
    self = [super initWithReturnPointer:NULL];
    if (self) {
        _bufp = bufp;
        _prompt = prompt;
    }
    return self;
}

- (void)fulfill {
    // Called when the delegate invokes -fulfill with no argument;
    // treat as an empty response.
    [self fulfill:@""];
}

- (void)fulfill:(NSString *)response {
    strlcpy(_bufp, response.UTF8String, BUFSZ);
    [super fulfill];
}

- (void)cancel {
    // ESC followed by NUL signals cancellation to NetHack.
    _bufp[0] = '\033';
    _bufp[1] = '\0';
    [super fulfill];
}

@end

// ---------------------------------------------------------------------------
// NHKeyInputRequest — private interface + implementation
// ---------------------------------------------------------------------------

@implementation NHKeyInputRequest

- (void)fulfillWithKey:(int)key {
    *(int *)self.returnPointer = key;
    [super fulfill];
}

@end

// ---------------------------------------------------------------------------
// NHKeyOrMouseInputRequest — private interface + implementation
// ---------------------------------------------------------------------------

@interface NHKeyOrMouseInputRequest ()
- (instancetype)initWithReturnPointer:(int *)retPtr
                                    x:(int16_t *)xp
                                    y:(int16_t *)yp
                                  mod:(int *)modp;
@end

@implementation NHKeyOrMouseInputRequest {
    int16_t *_xp;
    int16_t *_yp;
    int *_modp;
}

- (instancetype)initWithReturnPointer:(int *)retPtr
                                    x:(int16_t *)xp
                                    y:(int16_t *)yp
                                  mod:(int *)modp {
    self = [super initWithReturnPointer:retPtr];
    if (self) {
        _xp = xp;
        _yp = yp;
        _modp = modp;
    }
    return self;
}

- (void)fulfillWithKey:(int)key {
    *(int *)self.returnPointer = key;
    [super fulfill];
}

- (void)fulfillWithMouseX:(int)x y:(int)y modifier:(int)mod {
    *(int *)self.returnPointer = 0;  // 0 = mouse/position event
    if (_xp)   *_xp   = (int16_t)x;
    if (_yp)   *_yp   = (int16_t)y;
    if (_modp) *_modp = mod;
    [super fulfill];
}

@end

// ---------------------------------------------------------------------------
// NetHackBridge — private interface
// ---------------------------------------------------------------------------

@interface NetHackBridge ()
/// Dispatch an output event to the delegate on the main thread.
/// Non-blocking: the NetHack thread continues immediately.
- (void)dispatchOutput:(void (^)(void))block;
/// Dispatch a blocking input request to the delegate on the main thread,
/// then block the NetHack thread until [request fulfill] is called.
- (void)dispatchInput:(NHInputRequest *)request block:(void (^)(void))block;
@end

// ---------------------------------------------------------------------------
// C callback — runs on the NetHack background thread.
// ---------------------------------------------------------------------------

static NetHackBridge *_activeBridge = nil;

static void nethackCallback(const char *name, void *ret_ptr, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);

    // Dispatch on window function name.
    // All names carry the "shim_" prefix from winshim.c's VDECLCB/DECLCB macros.
    // See vendor/NetHack/doc/window.txt for semantics and argument types.
    // See vendor/NetHack/win/shim/winshim.c for the exact fmt strings.
    //
    // Output (non-blocking):
    //   [_activeBridge dispatchOutput:^{ ... }];
    //
    // Input (blocking):
    //   NHSomeRequest *req = [[NHSomeRequest alloc] initWith...];
    //   [_activeBridge dispatchInput:req block:^{ ... }];

    if (false) {
        // placeholder — keeps the else-if chain well-formed as cases are added

    // -----------------------------------------------------------------------
    // Initialisation / shutdown
    // -----------------------------------------------------------------------

    } else if (strcmp(name, "shim_init_nhwindows") == 0) {
        // fmt = "vpp": void return, int *argcp, char **argv.
        // argcp and argv are not forwarded — the delegate has no use for them.
        (void)va_arg(args, void *);  // argcp
        (void)va_arg(args, void *);  // argv
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate initWindows];
        }];

    } else if (strcmp(name, "shim_status_init") == 0) {
        // fmt = "v": void return, no arguments.
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate initStatus];
        }];

    } else if (strcmp(name, "shim_exit_nhwindows") == 0) {
        // fmt = "vs": void return, const char *str (may be NULL).
        const char *str = va_arg(args, const char *);
        NSString *msg = str ? @(str) : nil;
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate exitWindowsWithMessage:msg];
        }];

    } else if (strcmp(name, "shim_suspend_nhwindows") == 0) {
        // fmt = "vs": void return, const char *str.
        const char *str = va_arg(args, const char *);
        NSString *msg = str ? @(str) : nil;
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate suspendWindowsWithMessage:msg];
        }];

    } else if (strcmp(name, "shim_resume_nhwindows") == 0) {
        // fmt = "v": void return, no arguments.
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate resumeWindows];
        }];

    // -----------------------------------------------------------------------
    // Window lifecycle
    // -----------------------------------------------------------------------

    } else if (strcmp(name, "shim_create_nhwindow") == 0) {
        // fmt = "ii": int return (winid), int argument (window type).
        // Allocates a new window ID, writes it to ret_ptr, then notifies
        // the delegate synchronously so it can set up its UI for this window.
        // The ID must be written before this callback returns because the shim
        // reads ret immediately after shim_graphics_callback() returns.
        int type = va_arg(args, int);

        static int nextWindowID = 1;
        int windowID = nextWindowID++;
        *(int *)ret_ptr = windowID;

        NHWindowType windowType = (NHWindowType)type;
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate createNhwindow:windowID type:windowType];
        }];

    } else if (strcmp(name, "shim_clear_nhwindow") == 0) {
        // fmt = "vi": void return, winid.
        int window = va_arg(args, int);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate clearNhwindow:window];
        }];

    } else if (strcmp(name, "shim_display_nhwindow") == 0) {
        // fmt = "vib": void return, winid, boolean blocking.
        // When blocking=true NetHack expects to wait until the user dismisses
        // the window. That requires a new request type and window-close
        // coordination — not yet implemented; will abort if blocking is set.
        int window   = va_arg(args, int);
        int blocking = va_arg(args, int);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
			[delegate displayNhwindow:window blocking:blocking];
        }];

    } else if (strcmp(name, "shim_destroy_nhwindow") == 0) {
        // fmt = "vi": void return, winid.
        int window = va_arg(args, int);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate destroyNhwindow:window];
        }];

    // -----------------------------------------------------------------------
    // Text output
    // -----------------------------------------------------------------------

    } else if (strcmp(name, "shim_raw_print") == 0) {
        // fmt = "vs": void return, one string argument.
        const char *str = va_arg(args, const char *);
        puts(str);
        NSString *text = @(str);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate rawPrint:text];
        }];

    } else if (strcmp(name, "shim_raw_print_bold") == 0) {
        // fmt = "vs": void return, one string argument.
        const char *str = va_arg(args, const char *);
        puts(str);
        NSString *text = @(str);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate rawPrintBold:text];
        }];

    } else if (strcmp(name, "shim_curs") == 0) {
        // fmt = "viii": void return, winid, x (column), y (row).
        int window = va_arg(args, int);
        int x      = va_arg(args, int);
        int y      = va_arg(args, int);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate moveCursorIn:window x:x y:y];
        }];

    } else if (strcmp(name, "shim_putstr") == 0) {
        // fmt = "viis": void return, winid, attr, string.
        int window      = va_arg(args, int);
        int attr        = va_arg(args, int);
        const char *str = va_arg(args, const char *);
        puts(str);
        NSString *text = @(str);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate putStringIn:window string:text attribute:(NHTextAttribute)attr];
        }];

    } else if (strcmp(name, "shim_display_file") == 0) {
        // fmt = "vsb": void return, const char *name, boolean complain.
        const char *filename = va_arg(args, const char *);
        int complain         = va_arg(args, int);
        NSString *file = @(filename);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate displayFile:file complain:(BOOL)complain];
        }];

    // -----------------------------------------------------------------------
    // Map
    // -----------------------------------------------------------------------

    } else if (strcmp(name, "shim_print_glyph") == 0) {
        // fmt = "vi11pp": void return, winid, coordxy x, coordxy y,
        //   const glyph_info *glyphinfo, const glyph_info *bkglyphinfo.
        // coordxy is int16_t and is passed by value; it is promoted to int
        // in the variadic call. glyphinfo pointers are valid for this call only.
        int window              = va_arg(args, int);
        int x                   = va_arg(args, int);   // coordxy promoted to int
        int y                   = va_arg(args, int);   // coordxy promoted to int
        const void *glyphinfo   = va_arg(args, const void *);
        const void *bkglyphinfo = va_arg(args, const void *);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate printGlyphIn:window
              x:x
                          y:y
                  glyphInfo:glyphinfo
        backgroundGlyphInfo:bkglyphinfo];
        }];

    } else if (strcmp(name, "shim_cliparound") == 0) {
        // fmt = "vii": void return, int x, int y.
        int x = va_arg(args, int);
        int y = va_arg(args, int);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate clipAround:x y:y];
        }];

    // -----------------------------------------------------------------------
    // Menus
    // -----------------------------------------------------------------------

    } else if (strcmp(name, "shim_start_menu") == 0) {
        // fmt = "vii": void return, winid, unsigned long mbehavior.
        int window             = va_arg(args, int);
        unsigned long behavior = va_arg(args, unsigned long);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate startMenuIn:window behavior:behavior];
        }];

    } else if (strcmp(name, "shim_add_menu") == 0) {
        // fmt = "vipi00iisi"
        // winid, glyph_info*, ANY_P*, char ch, char gch, int attr, int clr,
        // const char *str, unsigned int itemflags.
        // char args are promoted to int in the variadic call.
        int window             = va_arg(args, int);
        const void *glyphinfo  = va_arg(args, const void *);
        const void *identifier = va_arg(args, const void *);
        int ch                 = va_arg(args, int);   // char promoted
        int gch                = va_arg(args, int);   // char promoted
        int attr               = va_arg(args, int);
        int clr                = va_arg(args, int);
        const char *str        = va_arg(args, const char *);
        unsigned int itemflags = va_arg(args, unsigned int);
        NSString *text = @(str);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate addMenuItemIn:window
        accel:(char)ch
                  groupAccel:(char)gch
                        attr:attr
                       color:clr
                      string:text
                       flags:itemflags
                   glyphInfo:glyphinfo
                  identifier:identifier];
        }];

    } else if (strcmp(name, "shim_end_menu") == 0) {
        // fmt = "vis": void return, winid, const char *prompt (may be NULL).
        int window         = va_arg(args, int);
        const char *prompt = va_arg(args, const char *);
        NSString *promptStr = prompt ? @(prompt) : nil;
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate endMenuIn:window prompt:promptStr];
        }];

    } else if (strcmp(name, "shim_select_menu") == 0) {
        // fmt = "iiip": int return, winid, int how, MENU_ITEM_P **menu_list.
        // Tricky: blocking; returns count of selected items and fills *menu_list.
        // Requires a new request type and MENU_ITEM_P bridging — not yet implemented.
        assert(0 && "shim_select_menu not yet implemented");

    } else if (strcmp(name, "shim_message_menu") == 0) {
        // fmt = "ciis": char return, char let, int how, const char *mesg.
        // Tricky: blocking; returns the character selected by the user.
        // Not yet implemented.
        assert(0 && "shim_message_menu not yet implemented");

    // -----------------------------------------------------------------------
    // Status bar
    // -----------------------------------------------------------------------

    } else if (strcmp(name, "shim_status_enablefield") == 0) {
        // fmt = "vippb": void return, int fieldidx, const char *nm,
        //   const char *fmt, boolean enable.
        int fieldidx        = va_arg(args, int);
        const char *nm      = va_arg(args, const char *);
        const char *fmt_str = va_arg(args, const char *);
        int enable          = va_arg(args, int);
        NSString *nameStr   = @(nm);
        NSString *fmtStr    = @(fmt_str);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate enableStatusField:fieldidx
                                 name:nameStr
                               format:fmtStr
                              enabled:(BOOL)enable];
        }];

    } else if (strcmp(name, "shim_status_update") == 0) {
        // fmt = "vipiiip": void return, int fldidx, genericptr_t ptr,
        //   int chg, int percent, int color, unsigned long *colormasks.
        int fldidx                   = va_arg(args, int);
        const void *ptr              = va_arg(args, const void *);
        int chg                      = va_arg(args, int);
        int percent                  = va_arg(args, int);
        int color                    = va_arg(args, int);
        const unsigned long *masks   = va_arg(args, const unsigned long *);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate updateStatusField:fldidx
                                    ptr:ptr
                                 change:chg
                                percent:percent
                                  color:color
                             colorMasks:masks];
        }];

    // -----------------------------------------------------------------------
    // Blocking input
    // -----------------------------------------------------------------------

    } else if (strcmp(name, "shim_nhgetch") == 0) {
        // fmt = "i": int return, no arguments.
        // Blocking input: return a single keypress.
        NHKeyInputRequest *req = [[NHKeyInputRequest alloc] initWithReturnPointer:ret_ptr];
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchInput:req block:^{
            [delegate needsKeyInput:req];
        }];

    } else if (strcmp(name, "shim_nh_poskey") == 0) {
        // fmt = "ippp": int return, coordxy *x, coordxy *y, int *mod.
        // Blocking input: return a keypress (non-zero) or a map-position click (0).
        int16_t *xp   = va_arg(args, int16_t *);
        int16_t *yp   = va_arg(args, int16_t *);
        int     *modp = va_arg(args, int *);
        NHKeyOrMouseInputRequest *req =
            [[NHKeyOrMouseInputRequest alloc] initWithReturnPointer:ret_ptr
                                                                  x:xp
                                                                  y:yp
                                                                mod:modp];
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchInput:req block:^{
            [delegate needsKeyOrMouseInput:req];
        }];

    } else if (strcmp(name, "shim_getlin") == 0) {
        // fmt = "vsp": void return, const char *query, char *bufp.
        // Blocking input: ask the user for a line of text.
        const char *query = va_arg(args, const char *);
        char *bufp        = va_arg(args, char *);
        NHLineInputRequest *req = [[NHLineInputRequest alloc] initWithBuffer:bufp
                                                                      prompt:@(query)];
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchInput:req block:^{
            [delegate needsLineInput:req];
        }];

    } else if (strcmp(name, "shim_yn_function") == 0) {
        // fmt = "css0": char return, const char *query, const char *resp, char def.
        // Tricky: blocking; returns the character the user chose from resp.
        // Not yet implemented.
        assert(0 && "shim_yn_function not yet implemented");

    } else if (strcmp(name, "shim_doprev_message") == 0) {
        // fmt = "iv": int return, no arguments.
        // Tricky: blocking; scrolls back through message history.
        // Not yet implemented.
        assert(0 && "shim_doprev_message not yet implemented");

    } else if (strcmp(name, "shim_get_ext_cmd") == 0) {
        // fmt = "iv": int return, no arguments.
        // Tricky: blocking; returns the index of the extended command chosen.
        // Not yet implemented.
        assert(0 && "shim_get_ext_cmd not yet implemented");

    } else if (strcmp(name, "shim_player_selection_or_tty") == 0) {
        // fmt = "b": boolean return, no arguments.
        // Tricky: blocking; returns whether the player completed character selection.
        // Not yet implemented.
        assert(0 && "shim_player_selection_or_tty not yet implemented");

    } else if (strcmp(name, "shim_ctrl_nhwindow") == 0) {
        // fmt = "viip": win_request_info * return, winid, int request,
        //   win_request_info *wri.
		return 0;

    } else if (strcmp(name, "shim_getmsghistory") == 0) {
        // fmt = "sb": char * return, boolean init.
        // Tricky: returns a pointer into a static rotating buffer of message history.
        // Not yet implemented.
        assert(0 && "shim_getmsghistory not yet implemented");

    } else if (strcmp(name, "set_shim_font_name") == 0) {
        // fmt = "2is": short return, winid window_type, char *font_name.
        // Tricky: non-standard short return value.
        // Not yet implemented.
        assert(0 && "set_shim_font_name not yet implemented");

    } else if (strcmp(name, "shim_get_color_string") == 0) {
        // fmt = "sv": char * return, no arguments.
        // Tricky: returns a char * (pointer-sized return).
        // Not yet implemented.
        assert(0 && "shim_get_color_string not yet implemented");

    // -----------------------------------------------------------------------
    // Misc / no-ops
    // -----------------------------------------------------------------------

    } else if (strcmp(name, "shim_get_nh_event") == 0) {
        // fmt = "v": no-op in virtually all window ports.

    } else if (strcmp(name, "shim_askname") == 0) {
        // fmt = "v": no-op — player name is obtained via getlin.

    } else if (strcmp(name, "shim_mark_synch") == 0) {
        // fmt = "v": no-op — signal to flush pending output.

    } else if (strcmp(name, "shim_wait_synch") == 0) {
        // fmt = "v": no-op — synchronisation point.

    } else if (strcmp(name, "shim_nhbell") == 0) {
        // fmt = "v": no-op — ring the terminal bell.

    } else if (strcmp(name, "shim_delay_output") == 0) {
        // fmt = "v": no-op — no artificial delays in this port.

    } else if (strcmp(name, "shim_number_pad") == 0) {
        // fmt = "vi": void return, int state. Ignored.
        (void)va_arg(args, int);

    } else if (strcmp(name, "shim_change_color") == 0) {
        // fmt = "viii": void return, int color, long rgb, int reverse. Ignored.
        (void)va_arg(args, int);
        (void)va_arg(args, long);
        (void)va_arg(args, int);

    } else if (strcmp(name, "shim_change_background") == 0) {
        // fmt = "vi": void return, int white_or_black. Ignored.
        (void)va_arg(args, int);

    } else if (strcmp(name, "shim_preference_update") == 0) {
        // fmt = "vp": void return, const char *pref. Ignored.
        (void)va_arg(args, const void *);

    } else if (strcmp(name, "shim_update_positionbar") == 0) {
        // fmt = "vs": void return, char *posbar.
        const char *posbar = va_arg(args, const char *);
        NSString *bar = @(posbar);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate updatePositionBar:bar];
        }];

    } else if (strcmp(name, "shim_update_inventory") == 0) {
        // fmt = "vi": void return, int (unused argument).
        (void)va_arg(args, int);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate updateInventory];
        }];

    } else if (strcmp(name, "shim_putmsghistory") == 0) {
        // fmt = "vsb": void return, const char *msg, boolean restoring.
        const char *msg = va_arg(args, const char *);
        int restoring   = va_arg(args, int);
        NSString *msgStr = msg ? @(msg) : nil;
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate putMessageHistory:msgStr restoring:(BOOL)restoring];
        }];

    } else if (strcmp(name, "shim_player_selection") == 0) {
        // fmt = "v": void return, no arguments.
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate requestPlayerSelection];
        }];

    } else {
        assert(false);
    }

    va_end(args);
}

// ---------------------------------------------------------------------------
// NetHackBridge
// ---------------------------------------------------------------------------

@implementation NetHackBridge

- (void)runWithArguments:(NSArray<NSString *> *)arguments
              completion:(nullable void (^)(int))completion {
    _activeBridge = self;
    shim_graphics_set_callback(nethackCallback);

    int argc = (int)arguments.count;
    char **argv = (char **)malloc((size_t)argc * sizeof(char *));
    for (int i = 0; i < argc; i++) {
        argv[i] = strdup(arguments[i].UTF8String);
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int result = nhmain(argc, argv);

        for (int i = 0; i < argc; i++) free(argv[i]);
        free(argv);
        _activeBridge = nil;

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    });
}

- (void)dispatchOutput:(void (^)(void))block {
    // Use dispatch_sync so each output callback fully completes before the
    // NetHack thread issues the next shim call. This preserves ordering and
    // prevents races where a later callback (e.g. start_menu) runs before the
    // delegate has finished processing the preceding one (e.g. create_nhwindow).
    dispatch_sync(dispatch_get_main_queue(), block);
}

- (void)dispatchInput:(NHInputRequest *)request block:(void (^)(void))block {
    dispatch_sync(dispatch_get_main_queue(), block);
    [request waitForFulfillment];
}

@end
