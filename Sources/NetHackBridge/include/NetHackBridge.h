#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Opaque window identifier assigned by NetHack.
typedef int NHWindowID;

/// NetHack window types, passed to create_nhwindow().
typedef NS_ENUM(int, NHWindowType) {
    NHWindowTypeMessage = 1,  ///< Top line — chat / message log.
    NHWindowTypeStatus  = 2,  ///< Deprecated bottom-status (avoid new use).
    NHWindowTypeMap     = 3,  ///< Main dungeon grid.
    NHWindowTypeMenu    = 4,  ///< Inventory / selection menus.
    NHWindowTypeText    = 5,  ///< Full-screen help / text display.
};

/// Text-rendering attribute flags passed to putstr().
typedef NS_ENUM(int, NHTextAttribute) {
    NHTextAttributeNone      = 0,
    NHTextAttributeBold      = 1,
    NHTextAttributeDim       = 2,
    NHTextAttributeItalic    = 3,
    NHTextAttributeUnderline = 4,
    NHTextAttributeBlink     = 5,
    NHTextAttributeInverse   = 7,
};


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
// NHKeyInputRequest  (nhgetch)
//
// NetHack needs a single keypress. The delegate must call -fulfillWithKey:.
// ---------------------------------------------------------------------------
@interface NHKeyInputRequest : NHInputRequest

/// Return `key` to NetHack and unblock.
- (void)fulfillWithKey:(int)key;

@end


// ---------------------------------------------------------------------------
// NHKeyOrMouseInputRequest  (nh_poskey)
//
// NetHack needs a keypress or a map-position click. The delegate must call
// exactly one of -fulfillWithKey: or -fulfillWithMouseX:y:modifier:.
// ---------------------------------------------------------------------------
@interface NHKeyOrMouseInputRequest : NHInputRequest

/// Return a keyboard `key` to NetHack and unblock.
- (void)fulfillWithKey:(int)key;

/// Return a map-click to NetHack: writes 0 as the key return value and fills
/// in the x/y/modifier output pointers, then unblocks.
- (void)fulfillWithMouseX:(int)x y:(int)y modifier:(int)mod;

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

/// raw_print — plain string, typically startup messages or errors.
- (void)nethackBridge:(NetHackBridge *)bridge didPrintString:(NSString *)string;

/// raw_print_bold — same as raw_print but displayed in bold/standout.
- (void)nethackBridge:(NetHackBridge *)bridge didPrintBoldString:(NSString *)string;

/// curs — move the displayable cursor to (x, y) in the given window.
/// 1 <= x < cols, 0 <= y < rows.
- (void)nethackBridge:(NetHackBridge *)bridge
  didMoveCursorInWindow:(NHWindowID)window
                      x:(int)x
                      y:(int)y;

/// putstr — print a string with a text attribute into a window.
- (void)nethackBridge:(NetHackBridge *)bridge
               window:(NHWindowID)window
         didPutString:(NSString *)string
            attribute:(NHTextAttribute)attribute;

// --- Input callbacks ---

/// getlin — NetHack needs a line of text from the user.
/// Call [request fulfill:responseString] or [request cancel] when done.
- (void)nethackBridge:(NetHackBridge *)bridge needsLineInput:(NHLineInputRequest *)request;

/// nhgetch — NetHack needs a single keypress.
/// Call [request fulfillWithKey:keyCode] when done.
- (void)nethackBridge:(NetHackBridge *)bridge needsKeyInput:(NHKeyInputRequest *)request;

/// nh_poskey — NetHack needs a keypress or a map-position click.
/// Call [request fulfillWithKey:] or [request fulfillWithMouseX:y:modifier:] when done.
- (void)nethackBridge:(NetHackBridge *)bridge needsKeyOrMouseInput:(NHKeyOrMouseInputRequest *)request;

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
