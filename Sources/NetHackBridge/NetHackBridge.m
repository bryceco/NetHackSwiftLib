#import "NetHackBridge.h"
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>

// Forward-declare libnh symbols; resolved at link time from libnh.a.
typedef void (*shim_callback_t)(const char *name, void *ret_ptr, const char *fmt, ...);
extern void shim_graphics_set_callback(shim_callback_t cb);
extern int  nhmain(int argc, char *argv[]);

// NetHack's input buffer size (see include/global.h)
#define BUFSZ 256

// ---------------------—-----------------------------------------------------
// NHInputRequest - private interface
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
    // See vendor/NetHack/doc/window.txt for the complete list and per-function
    // argument types.
    //
    // Output (non-blocking):
    //   [_activeBridge dispatchOutput:^{
    //       [_activeBridge.delegate nethackBridge:_activeBridge ...];
    //   }];
    //
    // Input (blocking):
    //   NHSomeRequest *req = [[NHSomeRequest alloc] initWithReturnPointer:ret_ptr ...];
    //   [_activeBridge dispatchInput:req block:^{
    //       [_activeBridge.delegate nethackBridge:_activeBridge needs...:req];
    //   }];
    if (false) {
        // placeholder — keeps the else-if chain well-formed as cases are added

    } else if (strcmp(name, "raw_print") == 0) {
        // fmt = "vs": void return, one string argument.
        // Non-blocking output: display a plain string (e.g. startup messages).
        const char *str = va_arg(args, const char *);
        NSString *text = @(str);
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchOutput:^{
            [delegate nethackBridge:_activeBridge didPrintString:text];
        }];

    } else if (strcmp(name, "getlin") == 0) {
        // fmt = "vsp": void return, one string (query/prompt), one pointer (char buf).
        // Blocking input: ask the user for a line of text.
        const char *query = va_arg(args, const char *);
        char *bufp = va_arg(args, char *);
        NHLineInputRequest *req = [[NHLineInputRequest alloc] initWithBuffer:bufp
                                                                      prompt:@(query)];
        id<NetHackBridgeDelegate> delegate = _activeBridge.delegate;
        [_activeBridge dispatchInput:req block:^{
            [delegate nethackBridge:_activeBridge needsLineInput:req];
        }];
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
    dispatch_async(dispatch_get_main_queue(), block);
}

- (void)dispatchInput:(NHInputRequest *)request block:(void (^)(void))block {
    dispatch_sync(dispatch_get_main_queue(), block);
    [request waitForFulfillment];
}

@end
