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

    } else if (strcmp(name, "shim_init_nhwindows") == 0) {
        // fmt = "vpp": void return, int *argcp, char **argv.
        // The windowing system has nothing to initialise on this side.

    } else if (strcmp(name, "shim_status_init") == 0) {
        // fmt = "v": void return, no arguments.

    } else if (strcmp(name, "shim_create_nhwindow") == 0) {
        // fmt = "ii": int return (winid), int argument (window type).
        // Allocates a new window ID, writes it to ret_ptr, then notifies
        // the delegate asynchronously so it can set up its UI for this window.
        // The ID must be written before this callback returns because the shim
        // reads ret immediately after shim_graphics_callback() returns.
        int type = va_arg(args, int);

        static int nextWindowID = 1;
        int windowID = nextWindowID++;
        *(int *)ret_ptr = windowID;

        NHWindowType windowType = (NHWindowType)type;
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate nethackBridge:_activeBridge
                    didCreateWindow:windowID
                             ofType:windowType];
        }];

    } else if (strcmp(name, "shim_raw_print") == 0) {
        // fmt = "vs": void return, one string argument.
        // Non-blocking output: display a plain string (e.g. startup messages).
        const char *str = va_arg(args, const char *);
		puts(str);
        NSString *text = @(str);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate nethackBridge:_activeBridge didPrintString:text];
        }];

    } else if (strcmp(name, "shim_raw_print_bold") == 0) {
        // fmt = "vs": void return, one string argument.
        const char *str = va_arg(args, const char *);
		puts(str);
        NSString *text = @(str);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate nethackBridge:_activeBridge didPrintBoldString:text];
        }];

    } else if (strcmp(name, "shim_curs") == 0) {
        // fmt = "viii": void return, winid, x (column), y (row).
        int window = va_arg(args, int);
        int x      = va_arg(args, int);
        int y      = va_arg(args, int);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate nethackBridge:_activeBridge didMoveCursorInWindow:window x:x y:y];
        }];

    } else if (strcmp(name, "shim_putstr") == 0) {
        // fmt = "viis": void return, winid, attr, string.
        int window     = va_arg(args, int);
        int attr       = va_arg(args, int);
        const char *str = va_arg(args, const char *);
		puts(str);
        NSString *text = @(str);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate nethackBridge:_activeBridge
                             window:window
                       didPutString:text
                          attribute:(NHTextAttribute)attr];
        }];

    } else if (strcmp(name, "shim_get_nh_event") == 0) {
        // fmt = "v": no-op in virtually all window ports; just consume.

    } else if (strcmp(name, "shim_nhgetch") == 0) {
        // fmt = "i": int return, no arguments.
        // Blocking input: return a single keypress.
        NHKeyInputRequest *req = [[NHKeyInputRequest alloc] initWithReturnPointer:ret_ptr];
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchInput:req block:^{
            [delegate nethackBridge:_activeBridge needsKeyInput:req];
        }];

    } else if (strcmp(name, "shim_nh_poskey") == 0) {
        // fmt = "ippp": int return, coordxy *x, coordxy *y, int *mod.
        // Blocking input: return a keypress (non-zero) or a map-position click (0).
        int16_t *xp  = va_arg(args, int16_t *);
        int16_t *yp  = va_arg(args, int16_t *);
        int     *modp = va_arg(args, int *);
        NHKeyOrMouseInputRequest *req =
            [[NHKeyOrMouseInputRequest alloc] initWithReturnPointer:ret_ptr
                                                                  x:xp
                                                                  y:yp
                                                                mod:modp];
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchInput:req block:^{
            [delegate nethackBridge:_activeBridge needsKeyOrMouseInput:req];
        }];

    } else if (strcmp(name, "shim_getlin") == 0) {
        // fmt = "vsp": void return, one string (query/prompt), one pointer (char buf).
        // Blocking input: ask the user for a line of text.
        const char *query = va_arg(args, const char *);
        char *bufp        = va_arg(args, char *);
        NHLineInputRequest *req = [[NHLineInputRequest alloc] initWithBuffer:bufp
                                                                      prompt:@(query)];
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchInput:req block:^{
            [delegate nethackBridge:_activeBridge needsLineInput:req];
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
