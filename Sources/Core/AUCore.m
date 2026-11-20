#import "AUCore.h"
#import <CommonCrypto/CommonDigest.h>
#import <mach/mach.h>
#import <os/lock.h>
#import <os/log.h>
#import <stdatomic.h>

#pragma mark - log

static dispatch_queue_t logQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("aura.log", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

NSURL *AULogURL(void) {
    static NSURL *url;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *dir = [docs URLByAppendingPathComponent:@"Aura" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        url = [dir URLByAppendingPathComponent:@"aura.log"];
    });
    return url;
}

void AULog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log(OS_LOG_DEFAULT, "[aura] %{public}@", line);
    static BOOL toStderr;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ toStderr = getenv("AURA_LOG_STDERR") != NULL; });
    if (toStderr) fprintf(stderr, "[aura] %s\n", line.UTF8String);
    NSDate *now = [NSDate date];
    dispatch_async(logQueue(), ^{
        static NSDateFormatter *formatter;
        static NSFileHandle *handle;
        if (!formatter) {
            formatter = [NSDateFormatter new];
            formatter.dateFormat = @"MM-dd HH:mm:ss.SSS";
        }
        NSURL *url = AULogURL();
        if (!handle) {
            NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
            if ([attributes fileSize] > 1024 * 1024) {
                NSURL *old = [url.URLByDeletingPathExtension URLByAppendingPathExtension:@"1.log"];
                [NSFileManager.defaultManager removeItemAtURL:old error:nil];
                [NSFileManager.defaultManager moveItemAtURL:url toURL:old error:nil];
            }
            if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) [NSData.data writeToURL:url atomically:NO];
            handle = [NSFileHandle fileHandleForWritingAtPath:url.path];
            [handle seekToEndOfFile];
        }
        NSString *text = [NSString stringWithFormat:@"%@ %@\n", [formatter stringFromDate:now], line];
        [handle writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    });
}

#pragma mark - settings

NSNotificationName const AUSettingsDidChangeNotification = @"AUSettingsDidChangeNotification";

BOOL AUEnabled(NSString *key) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return value ? [value boolValue] : YES;
}

BOOL AUFlag(NSString *key) {
    return [NSUserDefaults.standardUserDefaults boolForKey:key];
}

double AUNumber(NSString *key, double fallback) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

void AUSetNumber(NSString *key, double value) {
    [NSUserDefaults.standardUserDefaults setDouble:value forKey:key];
    AUSettingsChanged();
}

NSInteger AUInteger(NSString *key, NSInteger fallback) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

void AUSettingsChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:AUSettingsDidChangeNotification object:nil];
    });
}

#pragma mark - system

NSNotificationName const AUThrottleDidChangeNotification = @"AUThrottleDidChangeNotification";
static _Atomic uint64_t sg_peak;
static _Atomic uint32_t sg_frames;

BOOL AUThrottled(void) {
    return NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious;
}

NSString *AUThermalName(void) {
    switch (NSProcessInfo.processInfo.thermalState) {
        case NSProcessInfoThermalStateNominal: return @"норма";
        case NSProcessInfoThermalStateFair: return @"тёплый";
        case NSProcessInfoThermalStateSerious: return @"горячий (serious)";
        case NSProcessInfoThermalStateCritical: return @"критический";
    }
    return @"?";
}

uint64_t AUFootprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    uint64_t now = info.phys_footprint;
    uint64_t peak = atomic_load(&sg_peak);
    while (now > peak && !atomic_compare_exchange_weak(&sg_peak, &peak, now)) {}
    return now;
}

uint64_t AUPeakFootprint(void) {
    AUFootprint();
    return atomic_load(&sg_peak);
}

NSString *AUBytes(uint64_t bytes) {
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.0f КБ", bytes / 1024.0];
    return [NSString stringWithFormat:@"%.1f МБ", bytes / (1024.0 * 1024.0)];
}

void AUCountFrame(void) {
    atomic_fetch_add(&sg_frames, 1);
}

void AUSystemStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        __block NSProcessInfoThermalState last = NSProcessInfo.processInfo.thermalState;
        [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            NSProcessInfoThermalState state = NSProcessInfo.processInfo.thermalState;
            AULog(@"thermal %ld -> %ld (%@)", (long)last, (long)state, AUThermalName());
            BOOL was = last >= NSProcessInfoThermalStateSerious, now = state >= NSProcessInfoThermalStateSerious;
            last = state;
            if (was != now) [NSNotificationCenter.defaultCenter postNotificationName:AUThrottleDidChangeNotification object:nil];
        }];
        UIDevice.currentDevice.batteryMonitoringEnabled = YES;
        // A line a minute while Spotify is in front: what the 30 minute check is read from.
        static dispatch_source_t timer;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), 60 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
            uint32_t frames = atomic_exchange(&sg_frames, 0);
            AULog(@"telemetry: footprint %@ (peak %@), thermal %@, battery %.0f%%%@, parallax %.1f fps avg, low power %d",
                  AUBytes(AUFootprint()), AUBytes(AUPeakFootprint()), AUThermalName(), UIDevice.currentDevice.batteryLevel * 100,
                  UIDevice.currentDevice.batteryState == UIDeviceBatteryStateCharging ? @" charging" : @"", frames / 60.0,
                  NSProcessInfo.processInfo.lowPowerModeEnabled);
        });
        dispatch_resume(timer);
    });
}

#pragma mark - stats

double AUNowMs(void) {
    return CACurrentMediaTime() * 1000.0;
}

static NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *sg_stats;
static os_unfair_lock sg_statsLock = OS_UNFAIR_LOCK_INIT;

void AUStatRecord(NSString *name, double ms) {
    os_unfair_lock_lock(&sg_statsLock);
    if (!sg_stats) sg_stats = [NSMutableDictionary dictionary];
    NSMutableArray *values = sg_stats[name] ?: (sg_stats[name] = [NSMutableArray array]);
    [values addObject:@(ms)];
    if (values.count > 50) [values removeObjectAtIndex:0];
    os_unfair_lock_unlock(&sg_statsLock);
}

NSString *AUStatText(NSString *name) {
    os_unfair_lock_lock(&sg_statsLock);
    NSArray<NSNumber *> *values = [sg_stats[name] copy];
    os_unfair_lock_unlock(&sg_statsLock);
    if (!values.count) return @"—";
    double sum = 0;
    for (NSNumber *v in values) sum += v.doubleValue;
    return [NSString stringWithFormat:@"%.0f мс (ср. %.0f, n=%lu)", values.lastObject.doubleValue, sum / values.count, (unsigned long)values.count];
}

#pragma mark - helpers

NSString *AUSHA1(NSString *string) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

UIViewController *AUTopViewController(void) {
    UIWindow *key = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) key = window;
        }
    }
    UIViewController *top = key.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

void AUShareFile(NSURL *url) {
    UIViewController *top = AUTopViewController();
    if (!top) return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView = top.view;
    [top presentViewController:share animated:YES completion:nil];
}
