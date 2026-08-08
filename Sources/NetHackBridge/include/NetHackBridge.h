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
// NHMenuSelection
//
// Represents one item chosen by the user in response to a selectMenuIn:
// call.  The identifier is an opaque copy of the anything value originally
// passed to addMenuItemIn:; count is the selection multiplier (-1 = all).
// ---------------------------------------------------------------------------
@interface NHMenuSelection : NSObject
@property (nonatomic) NSData *identifier;
@property (nonatomic) long count;
- (instancetype)initWithIdentifier:(NSData *)identifier count:(long)count;
@end


// ---------------------------------------------------------------------------
// NetHackBridgeDelegate
//
// Output callbacks are dispatched synchronously to the main thread (the
// NetHack thread waits for each to complete before issuing the next shim
// call, preserving ordering and preventing data races on shared models).
// Input callbacks additionally block until the delegate calls its completion.
// Failing to call the completion on an input request will hang the game.
// ---------------------------------------------------------------------------
@protocol NetHackBridgeDelegate <NSObject>

// --- Window lifecycle ---

/// create_nhwindow — NetHack created a new window of the given type.
/// The window ID is assigned by the bridge and will be used in subsequent
/// calls (putstr, curs, display_nhwindow, etc.).
- (void)createNhwindow:(NHWindowID)window type:(NHWindowType)type;

/// clear_nhwindow — erase the contents of a window without closing it.
- (void)clearNhwindow:(NHWindowID)window;

/// display_nhwindow (non-blocking) — make the window visible.
/// The blocking variant (blocking=true) is not yet implemented in the bridge.
- (void)displayNhwindow:(NHWindowID)window blocking:(BOOL)blocking;

/// destroy_nhwindow — the window is being closed; free associated resources.
- (void)destroyNhwindow:(NHWindowID)window;

// --- Text output ---

/// raw_print — plain string, typically startup messages or errors.
- (void)rawPrint:(NSString *)string;

/// raw_print_bold — same as raw_print but displayed in bold/standout.
- (void)rawPrintBold:(NSString *)string;

/// curs — move the displayable cursor to (x, y) in the given window.
/// 1 <= x < cols, 0 <= y < rows.
- (void)moveCursorIn:(NHWindowID)window x:(int)x y:(int)y;

/// putstr — print a string with a text attribute into a window.
- (void)putStringIn:(NHWindowID)window
        string:(NSString *)string
     attribute:(NHTextAttribute)attribute;

/// display_file — display a named file (e.g. help text) to the user.
- (void)displayFile:(NSString *)filename complain:(BOOL)complain;

// --- Map ---

/// print_glyph — render one map cell.
/// glyphInfo and backgroundGlyphInfo are pointers to NetHack glyph_info
/// structs; they are valid only for the duration of this call.
- (void)printGlyphIn:(NHWindowID)window
  x:(int)x
              y:(int)y
      glyphInfo:(const void *)glyphInfo
backgroundGlyphInfo:(const void *)backgroundGlyphInfo;

/// cliparound — scroll the map so that (x, y) is visible.
- (void)clipAround:(int)x y:(int)y;

// --- Menus ---

/// start_menu — begin accumulating items for a new menu in this window.
- (void)startMenuIn:(NHWindowID)window behavior:(unsigned long)behavior;

/// add_menu — append one item to the in-progress menu.
/// glyphInfo and identifier are opaque NetHack pointers valid for this call only.
- (void)addMenuItemIn:(NHWindowID)window
accel:(char)accel
    groupAccel:(char)groupAccel
          attr:(int)attr
         color:(int)color
        string:(NSString *)string
         flags:(unsigned int)flags
     glyphInfo:(const void *)glyphInfo
    identifier:(NSData *)identifier;

/// end_menu — finalise the current menu with an optional prompt string.
- (void)endMenuIn:(NHWindowID)window prompt:(nullable NSString *)prompt;

/// select_menu — present the built menu and wait for the user to select items.
/// how: 0 = PICK_NONE (display only), 1 = PICK_ONE, 2 = PICK_ANY.
/// Call completion(selections) with the chosen items, or completion(nil) to cancel.
- (void)selectMenuIn:(NHWindowID)window
                 how:(int)how
          completion:(void (^)(NSArray<NHMenuSelection *> * _Nullable selections))completion;

// --- Status bar ---

/// status_enablefield — configure which status fields are active and how they
/// are formatted.
- (void)enableStatusField:(int)fieldIndex
                     name:(NSString *)name
                   format:(NSString *)format
                  enabled:(BOOL)enabled;

/// status_update — the value of one status field has changed.
/// ptr is a NetHack genericptr_t valid for this call only.
/// colorMasks is an array of unsigned longs valid for this call only.
- (void)updateStatusField:(int)fieldIndex
                      ptr:(const void *)ptr
                   change:(int)change
                  percent:(int)percent
                    color:(int)color
               colorMasks:(const unsigned long * _Nullable)colorMasks;

// --- Misc output ---

/// update_positionbar — update the optional position-bar widget string.
- (void)updatePositionBar:(NSString *)positionBar;

/// update_inventory — the contents of the player's inventory have changed.
- (void)updateInventory;

/// putmsghistory — replay a previous message into history when restoring a save.
- (void)putMessageHistory:(nullable NSString *)message restoring:(BOOL)restoring;

/// player_selection — NetHack is about to ask the player to choose
/// character role, race, alignment, and gender.
- (void)requestPlayerSelection;

/// init_nhwindows — the windowing system is being initialised.
- (void)initWindows;

/// status_init — the status-bar subsystem is being initialised.
- (void)initStatus;

/// exit_nhwindows — the windowing system is shutting down.
- (void)exitWindowsWithMessage:(nullable NSString *)message;

/// suspend_nhwindows — the windowing system is being temporarily suspended
/// (e.g. for a shell-out).
- (void)suspendWindowsWithMessage:(nullable NSString *)message;

/// resume_nhwindows — the windowing system has resumed after suspension.
- (void)resumeWindows;

// --- Blocking input ---

/// getlin — NetHack needs a line of text from the user.
/// Call completion(responseString) to respond, or completion(nil) to cancel.
- (void)needsLineInput:(NSString *)prompt
            completion:(void (^)(NSString * _Nullable response))completion;

/// nhgetch — NetHack needs a single keypress.
/// Call completion(keyCode) when done.
- (void)needsKeyInput:(void (^)(int key))completion;

/// nh_poskey — NetHack needs a keypress or a map-position click.
/// For a key event: call completion(key, 0, 0, 0) with key != 0.
/// For a map click: call completion(0, x, y, modifier).
- (void)needsKeyOrMouseInput:(void (^)(int key, int x, int y, int mod))completion;

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
