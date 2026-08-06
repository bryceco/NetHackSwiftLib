#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// NHInputRequest
//
// Created by the library for each blocking callback. The NetHack thread holds
// this object and waits on it; the delegate receives it on the main thread,
// arranges for user input, then calls -fulfill to unblock the NetHack thread.
// ---------------------------------------------------------------------------
@interface NHInputRequest : NSObject

/// Pointer to the storage where a return value must be written before calling
/// -fulfill, if the callback has a non-void return type. May be NULL.
@property (nonatomic, readonly) void * _Nullable returnPointer;

/// Unblock the NetHack thread. Must be called exactly once from the main thread.
- (void)fulfill;

@end


// ---------------------------------------------------------------------------
// NHLineInputRequest  (getlin)
//
// NetHack wants a line of text from the user. The delegate must call
// -fulfill: with the user's response, or -cancel to send ESC.
// ---------------------------------------------------------------------------
@interface NHLineInputRequest : NHInputRequest

/// The prompt to display to the user.
@property (nonatomic, readonly) NSString *prompt;

/// Write `response` into the buffer and unblock NetHack.
/// Responses longer than 255 bytes are truncated.
- (void)fulfill:(NSString *)response;

/// Signal cancellation (writes ESC + NUL into the buffer) and unblock NetHack.
- (void)cancel;

@end


// ---------------------------------------------------------------------------
// NetHackBridgeDelegate
//
// Output callbacks are dispatched asynchronously to the main thread.
// Input callbacks are dispatched synchronously: the NetHack thread blocks
// until the delegate calls the appropriate fulfill method on the request.
// Failing to call fulfill will hang the game.
// ---------------------------------------------------------------------------
@class NetHackBridge;

@protocol NetHackBridgeDelegate <NSObject>

// --- Output callbacks ---

/// NetHack wants to print a plain string directly to the screen (e.g. startup
/// messages and errors). Append a newline when displaying.
- (void)nethackBridge:(NetHackBridge *)bridge didPrintString:(NSString *)string;

// --- Input callbacks ---

/// NetHack needs a line of text from the user.
/// Call [request fulfill:responseString] or [request cancel] when done.
- (void)nethackBridge:(NetHackBridge *)bridge needsLineInput:(NHLineInputRequest *)request;

@end


// ---------------------------------------------------------------------------
// NetHackBridge
// ---------------------------------------------------------------------------
@interface NetHackBridge : NSObject

@property (nonatomic, weak, nullable) id<NetHackBridgeDelegate> delegate;

/// Start NetHack on a background thread and return immediately.
/// `completion` is called on the main thread when the game ends.
- (void)runWithArguments:(NSArray<NSString *> *)arguments
              completion:(nullable void (^)(int exitCode))completion;

@end

NS_ASSUME_NONNULL_END
