#import "NetHackBridge.h"
#include <string.h>
#include <stdlib.h>

// Forward-declare libnh entry points; resolved at link time from libnh.a.
extern int  nhmain(int argc, char *argv[]);
extern void nhswift_set_callbacks(const nhswift_callbacks *cb);
extern void nhswift_set_paths(const char *hackdir, const char *playground);

// ---------------------------------------------------------------------------
// NHEquipItem
// ---------------------------------------------------------------------------

@implementation NHEquipItem

- (instancetype)initWithCSlot:(const nhswift_inven_slot *)slot {
    self = [super init];
    if (self) {
        _slot      = (NHEquipSlot)slot->slot;
        _glyph     = slot->glyph;
        _isCursed  = (BOOL)slot->cursed;
        _isBlessed = (BOOL)slot->blessed;
        _bucKnown  = (BOOL)slot->bknown;
        _name      = @(slot->name);
    }
    return self;
}

@end

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
// NHPlayerSelection
// ---------------------------------------------------------------------------

@implementation NHPlayerSelection

- (instancetype)init {
    self = [super init];
    if (self) {
        _roleIndex   = NHSWIFT_ROLE_RANDOM;
        _raceIndex   = NHSWIFT_ROLE_RANDOM;
        _genderIndex = NHSWIFT_ROLE_RANDOM;
        _alignIndex  = NHSWIFT_ROLE_RANDOM;
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
    // Block this thread permanently so the exit() that NetHack calls after
    // returning from exit_nhwindows never executes.
    dispatch_semaphore_wait(dispatch_semaphore_create(0), DISPATCH_TIME_FOREVER);
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

static int cb_playerSelection(const nhswift_playerOptions *opts,
                              nhswift_playerSelection *result)
{
    // Convert C option tables to Obj-C arrays so the Swift delegate receives
    // plain strings/numbers without needing to know about nhswift_playerOptions.
    NSMutableArray<NSString *> *roles      = [NSMutableArray arrayWithCapacity:(NSUInteger)opts->roleCount];
    NSMutableArray<NSNumber *> *roleGlyphs = [NSMutableArray arrayWithCapacity:(NSUInteger)opts->roleCount];
    NSMutableArray<NSString *> *races      = [NSMutableArray arrayWithCapacity:(NSUInteger)opts->raceCount];
    NSMutableArray<NSNumber *> *raceGlyphs = [NSMutableArray arrayWithCapacity:(NSUInteger)opts->raceCount];
    NSMutableArray<NSString *> *genders    = [NSMutableArray arrayWithCapacity:(NSUInteger)opts->genderCount];
    NSMutableArray<NSString *> *aligns     = [NSMutableArray arrayWithCapacity:(NSUInteger)opts->alignCount];

    for (int i = 0; i < opts->roleCount;   i++) {
        [roles      addObject:@(opts->roles[i])];
        [roleGlyphs addObject:@(opts->roleGlyphs[i])];
    }
    for (int i = 0; i < opts->raceCount;   i++) {
        [races      addObject:@(opts->races[i])];
        [raceGlyphs addObject:@(opts->raceGlyphs[i])];
    }
    for (int i = 0; i < opts->genderCount; i++) [genders addObject:@(opts->genders[i])];
    for (int i = 0; i < opts->alignCount;  i++) [aligns  addObject:@(opts->aligns[i])];

    // dispatchOutput uses dispatch_sync; the delegate runs a modal event loop
    // and returns with a filled NHPlayerSelection when the user confirms.
    __block NHPlayerSelection *selection = nil;
    [_activeBridge dispatchOutput:^{
        selection = [_activeDelegate requestPlayerSelectionWithRoles:roles
                                                          roleGlyphs:roleGlyphs
                                                               races:races
                                                          raceGlyphs:raceGlyphs
                                                            genders:genders
                                                             aligns:aligns];
    }];

    if (!selection) return 0;  // fall back to built-in dialog

    result->roleIndex   = (int)selection.roleIndex;
    result->raceIndex   = (int)selection.raceIndex;
    result->genderIndex = (int)selection.genderIndex;
    result->alignIndex  = (int)selection.alignIndex;
    if (selection.playerName.length > 0) {
        strncpy(result->playerName, selection.playerName.UTF8String,
                sizeof(result->playerName) - 1);
        result->playerName[sizeof(result->playerName) - 1] = '\0';
    }
    return 1;
}

static void cb_askName(char *buf, int bufsize) {
    // Name is supplied via the playerSelection result; write empty string so
    // NetHack uses whatever plname was already set (e.g. from $USER or
    // the playerName field in nhswift_playerSelection).
	printf("cb_askName\n");
    if (buf && bufsize > 0)
		buf[0] = '\0';
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

static void flushPendingGlyphs(void);  // defined below, after the batch struct

static void cb_clearWindow(int window) {
    [_activeBridge dispatchOutput:^{
        [_activeDelegate clearNhwindow:window];
    }];
}

static void cb_displayWindow(int window, int blocking) {
    // Flush any printGlyph calls that were batched since the last displayWindow.
    flushPendingGlyphs();
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

// Glyph batch accumulator — filled on the game thread, flushed once per
// cb_displayWindow call via a single dispatch_sync.  Never accessed from
// the main thread while the game thread is running, so no lock is needed.
typedef struct {
    int window, x, y;
    nhswift_glyph gi, bkgi;
} PendingGlyph;

static PendingGlyph *sPendingGlyphs    = NULL;
static int           sPendingGlyphCount = 0;
static int           sPendingGlyphCap   = 0;

static void flushPendingGlyphs(void) {
    if (sPendingGlyphCount == 0) return;
    int count        = sPendingGlyphCount;
    PendingGlyph *batch = sPendingGlyphs;
    sPendingGlyphs    = NULL;
    sPendingGlyphCount = 0;
    sPendingGlyphCap   = 0;
    [_activeBridge dispatchOutput:^{
        for (int i = 0; i < count; i++) {
            [_activeDelegate printGlyphIn:batch[i].window
                                        x:batch[i].x
                                        y:batch[i].y
                                glyphInfo:&batch[i].gi
                      backgroundGlyphInfo:&batch[i].bkgi];
        }
        free(batch);
    }];
}

static void cb_printGlyph(int window, int x, int y,
                           const nhswift_glyph *gi,
                           const nhswift_glyph *bkgi) {
    // Accumulate on the game thread; dispatched to main thread in bulk by
    // cb_displayWindow.  This avoids a dispatch_sync round-trip per tile
    // (up to ~1,600 per turn on a full map).
    if (sPendingGlyphCount >= sPendingGlyphCap) {
        sPendingGlyphCap = sPendingGlyphCap ? sPendingGlyphCap * 2 : 2048;
        sPendingGlyphs = realloc(sPendingGlyphs, (size_t)sPendingGlyphCap * sizeof(PendingGlyph));
    }
    sPendingGlyphs[sPendingGlyphCount++] = (PendingGlyph){ window, x, y, *gi, *bkgi };
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

// add_menu callback — appends one item to the in-progress menu in `window`.
//   glyphInfo  — glyph info for the item's tile; gi->glyph == -1 (NO_GLYPH) means no icon.
//                Pointer is only valid for the duration of this call.
//   accel      — accelerator (inventory letter, e.g. 'a'); 0 if the item has no hotkey.
//   grpAccel   — group accelerator for bulk-selection of a category; 0 if unused.
//   attr       — text attribute bitmask (ATR_BOLD, ATR_DIM, …).
//   color      — color index (CLR_*).
//   string     — display label; may be NULL (treated as empty string).
//   itemflags  — MENU_ITEMFLAGS_* bitmask (e.g. MENU_ITEMFLAGS_SELECTED for pre-checked).
//   identifier — opaque `anything` value from NetHack, returned unchanged in selectMenu
//                to identify which items the user chose.
static void cb_addMenu(int window, const nhswift_glyph *glyphInfo,
                       int accel, int grpAccel, int attr, int color,
                       const char *string, unsigned int itemflags,
                       uintptr_t identifier) {
    NSString *nsString = string ? @(string) : @"";
    [_activeBridge dispatchOutput:^{
        [_activeDelegate addMenuItemIn:window
                                 accel:(char)accel
                            groupAccel:(char)grpAccel
                                  attr:attr
                                 color:color
                                string:nsString
                                 flags:itemflags
								 glyph:glyphInfo->glyph
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
    NSLog(@"cb_messageMenu needs a delegate function (let=%d how=%d mesg=%s)", let, how, mesg ? mesg : "");
    (void)let; (void)how; (void)mesg;
    return 0;
}

// --- Input ---

static int cb_getChar(void) {
    __block int result = 0;
    [_activeBridge dispatchInput:^(void (^done)(void)) {
        [_activeDelegate needKeyInput:^(int key) {
            result = key;
            done();
        }];
    }];
    return result;
}

static int cb_posKey(int *x, int *y, int *mod) {
    __block int result = 0;
    [_activeBridge dispatchInput:^(void (^done)(void)) {
        [_activeDelegate needKeyOrMouseInput:^(int key, int mx, int my, int mmod) {
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
    NSString *queryStr = query ? @(query) : @"";
    NSString *respStr  = resp  ? @(resp)  : @"";
    __block int result = def;
    [_activeBridge dispatchInput:^(void (^done)(void)) {
        [_activeDelegate needYnInput:queryStr
                            responses:respStr
                      defaultResponse:def
                           completion:^(int choice) {
            result = choice;
            done();
        }];
    }];
    return result;
}

static void cb_getLine(const char *query, char *buf, int bufsize) {
    NSString *promptStr = query ? @(query) : @"";
    [_activeBridge dispatchInput:^(void (^done)(void)) {
        [_activeDelegate needLineInput:promptStr
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

static int cb_getExtCmd(const nhswift_extcmd *cmds, int count) {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSString *> *descs = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *keys  = [NSMutableArray arrayWithCapacity:count];
    for (int i = 0; i < count; i++) {
        [names addObject:@(cmds[i].name)];
        [descs addObject:@(cmds[i].desc)];
        [keys  addObject:@((uint8_t)cmds[i].key)];
    }

    __block int result = -1;
    [_activeBridge dispatchInput:^(void (^done)(void)) {
        [_activeDelegate needExtCmdNames:names
                            descriptions:descs
                                    keys:keys
                              completion:^(int cmdIndex) {
            result = cmdIndex;
            done();
        }];
    }];
    return result;
}

static int cb_prevMessage(void) {
    NSLog(@"cb_prevMessage needs a delegate function");
    return 0;
}

// --- Misc / no-ops ---

static void cb_getEvent(void)    {}

static void cb_markSynch(void) {
	// nothing to do
}

/*
wait_synch()    -- Wait until all pending output is complete (*flush*() for
				   streams goes here).
				-- May also deal with exposure events etc. so that the
				   display is OK when return from wait_synch().
*/
static void cb_waitSynch(void) {
    BOOL hadGlyphs = (sPendingGlyphCount > 0);
    flushPendingGlyphs();
    if (hadGlyphs) {
        [_activeBridge dispatchOutput:^{
            [_activeDelegate waitSynch];
        }];
    }
}

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

static void cb_delayOutput(void) {
    cb_waitSynch();   // flush pending glyphs so the frame is visible before the pause
    usleep(50000);    // 50 ms — enough for animation to be perceptible
}

static void cb_preferenceUpdate(const char *pref) {
    (void)pref;  // Ignored.
}

static void cb_updateInventory(const nhswift_inven_slot *slots, int count) {
    NSMutableArray<NHEquipItem *> *items = [NSMutableArray arrayWithCapacity:count];
    for (int i = 0; i < count; i++) {
        [items addObject:[[NHEquipItem alloc] initWithCSlot:&slots[i]]];
    }
    [_activeBridge dispatchOutput:^{
        [_activeDelegate updateInventory:items];
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

static void cb_statusEnableField(NHStatusField fieldidx, const char *nm,
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
                            int chg, int percent, NHColor color,
                            const unsigned long *colormasks)
{
    // fldidx is int (not NHStatusField) so ARM64 passes it correctly; cast
    // here where NSInteger sign-extends the 32-bit value properly.
    NHStatusField field = (NHStatusField)fldidx;
    // text and colormasks are valid only for this call; dispatchOutput is
    // synchronous so the delegate receives them while they are still live.
    NSString *textStr = text ? @(text) : nil;
    [_activeBridge dispatchOutput:^{
        [_activeDelegate updateStatusField:field
                                      text:textStr
                                  condBits:(NHCondition)condbits
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

    // Use QOS_CLASS_USER_INTERACTIVE to avoid priority inversion when
	// display modal windows.
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
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
    dispatch_sync(dispatch_get_main_queue(),
				  block);
}

- (void)dispatchInput:(void (^)(void (^)(void)))block {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        block(^{ dispatch_semaphore_signal(sem); });
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
}

+ (NSInteger)tileIndexForGlyph:(NSInteger)glyph {
    return (NSInteger)nhswift_glyph_to_tile(glyph);
}

+ (BOOL)isValidRole:(NSInteger)roleIndex {
    return (BOOL)nhswift_validrole((int)roleIndex);
}

+ (BOOL)isValidRace:(NSInteger)raceIndex forRole:(NSInteger)roleIndex {
    return (BOOL)nhswift_validrace((int)roleIndex, (int)raceIndex);
}

+ (BOOL)isValidGender:(NSInteger)genderIndex forRole:(NSInteger)roleIndex race:(NSInteger)raceIndex {
    return (BOOL)nhswift_validgend((int)roleIndex, (int)raceIndex, (int)genderIndex);
}

+ (BOOL)isValidAlign:(NSInteger)alignIndex forRole:(NSInteger)roleIndex race:(NSInteger)raceIndex {
    return (BOOL)nhswift_validalign((int)roleIndex, (int)raceIndex, (int)alignIndex);
}

@end
