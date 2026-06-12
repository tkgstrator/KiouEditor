#import "Internal.h"
#import <os/log.h>

// ===========================================================================
// Logging.m — os_log channel + dual file log.
//
// Two file destinations:
//   g_logFile  = NSTemporaryDirectory() — app sandbox temp
//   g_logFile2 = /var/tmp/kiou_editor.log — root-accessible retrieval
// ===========================================================================

static os_log_t g_log = NULL;
static NSString *g_logFile  = nil;
static NSString *g_logFile2 = nil;

static void file_log_path(NSString *path, NSString *msg) {
    if (!path) return;
    @try {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                          [df stringFromDate:[NSDate date]], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

void file_log(NSString *msg) {
    NSLog(@"[KiouEditor] %@", msg);
    if (g_log) {
        os_log(g_log, "%{public}s", msg.UTF8String);
    }
    if (g_logFile)  file_log_path(g_logFile, msg);
    if (g_logFile2) file_log_path(g_logFile2, msg);
}

void logging_init(void) {
    g_log = os_log_create("com.neconome.shogi.kioueditor", "editor");
    g_logFile  = [NSTemporaryDirectory()
                  stringByAppendingPathComponent:@"kiou_editor.log"];
    g_logFile2 = @"/var/tmp/kiou_editor.log";
}
