#import "AUModelManager.h"
#import "AUCore.h"
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>

NSNotificationName const AUModelsDidChangeNotification = @"AUModelsDidChangeNotification";

static const NSTimeInterval kIdleUnload = 300;

#pragma mark - the manager

@interface AUModelEntry : NSObject
@property (nonatomic, copy) NSString *modelID, *title, *license;
@property (nonatomic) NSInteger version;
@property (nonatomic) uint64_t approximateSize;
@property (nonatomic) AUModelState state;
@property (nonatomic) double progress;
@property (nonatomic, copy) NSString *lastError;
@property (nonatomic, strong) MLModel *loaded;
@property (nonatomic) CFTimeInterval lastUse;
@property (nonatomic) NSTimeInterval idle;   // unloaded after this long unused
@end

@implementation AUModelEntry
@end

@implementation AUModelManager {
    NSDictionary<NSString *, AUModelEntry *> *_entries;
    NSLock *_lock;
    NSURLSession *_session;
    dispatch_queue_t _work;
    NSTimer *_idleTimer;
}

+ (instancetype)shared {
    static AUModelManager *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [AUModelManager new]; });
    return shared;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _lock = [NSLock new];
    _work = dispatch_queue_create("aura.models", DISPATCH_QUEUE_SERIAL);
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 30;
    configuration.timeoutIntervalForResource = 600;
    configuration.waitsForConnectivity = NO;
    configuration.HTTPAdditionalHeaders = @{@"User-Agent": @"Aura/" AURA_VERSION " (iOS; CFNetwork)"};
    _session = [NSURLSession sessionWithConfiguration:configuration];
    AUModelEntry *depth = [AUModelEntry new];
    depth.modelID = AUModelDepth;
    depth.version = 1;
    depth.title = @"Depth Anything V2 Small (P8)";
    depth.license = @"Apache-2.0 · Apple Core ML";
    depth.approximateSize = 25247952;
    AUModelEntry *upscale = [AUModelEntry new];
    upscale.modelID = AUModelUpscale;
    upscale.version = 1;
    upscale.title = @"Real-ESRGAN general x4v3";
    upscale.license = @"BSD-3-Clause · xinntao";
    upscale.approximateSize = 2492805;
    AUModelEntry *inpaint = [AUModelEntry new];
    inpaint.modelID = AUModelInpaint;
    inpaint.version = 1;
    inpaint.title = @"Big-LaMa (дорисовка)";
    inpaint.license = @"Apache-2.0 · advimman/lama";
    inpaint.approximateSize = 52000000;
    inpaint.idle = 30;   // big: let go as soon as the cover is done
    depth.idle = kIdleUnload;
    upscale.idle = kIdleUnload;
    _entries = @{depth.modelID: depth, upscale.modelID: upscale, inpaint.modelID: inpaint};
    for (AUModelEntry *entry in _entries.allValues) {
        entry.state = [NSFileManager.defaultManager fileExistsAtPath:[self compiledURL:entry].path] ? AUModelReady : AUModelMissing;
    }
    // Models of earlier versions this one no longer uses (the fp16 inpainting model of 0.5) are let go.
    NSMutableSet *known = [NSMutableSet set];
    for (AUModelEntry *entry in _entries.allValues) [known addObject:[self compiledURL:entry].lastPathComponent];
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:[self root] includingPropertiesForKeys:nil options:0 error:nil]) {
        if ([url.lastPathComponent hasSuffix:@".mlmodelc"] && ![known containsObject:url.lastPathComponent]) {
            [NSFileManager.defaultManager removeItemAtURL:url error:nil];
            AULog(@"model %@ no longer used: removed", url.lastPathComponent);
        }
    }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(memoryWarning)
                                               name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_idleTimer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(unloadIdle) userInfo:nil repeats:YES];
        self->_idleTimer.tolerance = 5;
    });
    return self;
}

- (BOOL)serverConfigured {
    return strlen(AURA_MODELS_URL) > 0;
}

- (NSURL *)root {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *root = [[support URLByAppendingPathComponent:@"Aura" isDirectory:YES] URLByAppendingPathComponent:@"Models" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

- (NSURL *)compiledURL:(AUModelEntry *)entry {
    return [[self root] URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-v%ld.mlmodelc", entry.modelID, (long)entry.version] isDirectory:YES];
}

- (AUModelEntry *)entry:(NSString *)modelID {
    return _entries[modelID];
}

- (void)changed:(AUModelEntry *)entry {
    NSString *modelID = entry.modelID;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:AUModelsDidChangeNotification object:modelID];
    });
}

- (NSString *)titleOf:(NSString *)modelID { return [self entry:modelID].title ?: modelID; }
- (NSString *)licenseOf:(NSString *)modelID { return [self entry:modelID].license ?: @""; }

- (AUModelState)stateOf:(NSString *)modelID {
    [_lock lock];
    AUModelState state = [self entry:modelID].state;
    [_lock unlock];
    return state;
}

- (double)progressOf:(NSString *)modelID {
    [_lock lock];
    double progress = [self entry:modelID].progress;
    [_lock unlock];
    return progress;
}

- (NSString *)lastErrorOf:(NSString *)modelID {
    [_lock lock];
    NSString *error = [self entry:modelID].lastError;
    [_lock unlock];
    return error;
}

- (uint64_t)bytesOnDiskOf:(NSString *)modelID {
    AUModelEntry *entry = [self entry:modelID];
    if (!entry) return 0;
    uint64_t total = 0;
    NSDirectoryEnumerator *walk = [NSFileManager.defaultManager enumeratorAtURL:[self compiledURL:entry]
                                                     includingPropertiesForKeys:@[NSURLFileSizeKey] options:0 errorHandler:nil];
    for (NSURL *url in walk) {
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        total += size.unsignedLongLongValue;
    }
    return total;
}

- (NSString *)statusTextOf:(NSString *)modelID {
    AUModelEntry *entry = [self entry:modelID];
    switch ([self stateOf:modelID]) {
        case AUModelMissing: return [NSString stringWithFormat:@"не скачана · %@", AUBytes(entry.approximateSize)];
        case AUModelDownloading: return [NSString stringWithFormat:@"качается %.0f%%", [self progressOf:modelID] * 100];
        case AUModelCompiling: return @"компилируется…";
        case AUModelReady: {
            [_lock lock];
            BOOL loaded = entry.loaded != nil;
            [_lock unlock];
            return [NSString stringWithFormat:@"%@ · %@", AUBytes([self bytesOnDiskOf:modelID]), loaded ? @"в памяти" : @"готова"];
        }
        case AUModelFailed: return [NSString stringWithFormat:@"ошибка: %@", [self lastErrorOf:modelID] ?: @"?"];
    }
    return @"";
}

#pragma mark - download and compile

- (void)ensure:(NSString *)modelID {
    AUModelEntry *entry = [self entry:modelID];
    if (!entry) return;
    [_lock lock];
    BOOL start = entry.state == AUModelMissing || entry.state == AUModelFailed;
    if (start) {
        entry.state = AUModelDownloading;
        entry.progress = 0;
        entry.lastError = nil;
    }
    [_lock unlock];
    if (!start) return;
    [self changed:entry];
    dispatch_async(_work, ^{ [self fetch:entry]; });
}

- (void)fail:(AUModelEntry *)entry reason:(NSString *)reason {
    AULog(@"model %@: %@", entry.modelID, reason);
    [_lock lock];
    entry.state = AUModelFailed;
    entry.lastError = reason;
    [_lock unlock];
    [self changed:entry];
}

// Runs on _work: one model at a time, file after file, each checked against the manifest before it is kept.
- (void)fetch:(AUModelEntry *)entry {
    if (!self.serverConfigured) return [self fail:entry reason:@"no model server in this build"];
    CFTimeInterval started = CACurrentMediaTime();
    NSURL *base = [[NSURL URLWithString:@(AURA_MODELS_URL)] URLByAppendingPathComponent:entry.modelID isDirectory:YES];
    NSString *error = nil;
    NSData *manifestData = [self syncData:[base URLByAppendingPathComponent:@"manifest.json"] error:&error];
    if (!manifestData) return [self fail:entry reason:[@"manifest: " stringByAppendingString:error ?: @"?"]];
    AUManifest *manifest = [AUManifest manifestWithData:manifestData error:&error];
    if (!manifest) return [self fail:entry reason:error];
    if (![manifest.modelID isEqualToString:entry.modelID] || manifest.version != entry.version) {
        return [self fail:entry reason:[NSString stringWithFormat:@"server has %@ v%ld", manifest.modelID, (long)manifest.version]];
    }
    NSURL *staging = [[self root] URLByAppendingPathComponent:[@".staging-" stringByAppendingString:entry.modelID] isDirectory:YES];
    NSFileManager *files = NSFileManager.defaultManager;
    [files removeItemAtURL:staging error:nil];
    uint64_t done = 0;
    for (AUManifestFile *file in manifest.files) {
        NSURL *target = [staging URLByAppendingPathComponent:file.path];
        [files createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *source = [base URLByAppendingPathComponent:file.path];
        if (![self syncDownload:source to:target error:&error]) {
            [files removeItemAtURL:staging error:nil];
            return [self fail:entry reason:[NSString stringWithFormat:@"%@: %@", file.path.lastPathComponent, error]];
        }
        NSDictionary *attributes = [files attributesOfItemAtPath:target.path error:nil];
        if (attributes.fileSize != file.size || ![AUSHA256OfFile(target) isEqualToString:file.sha256]) {
            [files removeItemAtURL:staging error:nil];
            return [self fail:entry reason:[NSString stringWithFormat:@"%@ failed its checksum", file.path.lastPathComponent]];
        }
        done += file.size;
        [_lock lock];
        entry.progress = manifest.size ? (double)done / manifest.size : 1;
        [_lock unlock];
        [self changed:entry];
    }
    double downloadMs = (CACurrentMediaTime() - started) * 1000;
    [_lock lock];
    entry.state = AUModelCompiling;
    [_lock unlock];
    [self changed:entry];
    NSURL *package = [staging URLByAppendingPathComponent:manifest.package isDirectory:YES];
    CFTimeInterval compileStarted = CACurrentMediaTime();
    dispatch_semaphore_t compiled = dispatch_semaphore_create(0);
    __block NSURL *compiledURL = nil;
    __block NSError *compileError = nil;
    [MLModel compileModelAtURL:package completionHandler:^(NSURL *url, NSError *e) {
        compiledURL = url;
        compileError = e;
        dispatch_semaphore_signal(compiled);
    }];
    dispatch_semaphore_wait(compiled, DISPATCH_TIME_FOREVER);
    if (!compiledURL) {
        [files removeItemAtURL:staging error:nil];
        return [self fail:entry reason:[@"compile: " stringByAppendingString:compileError.localizedDescription ?: @"?"]];
    }
    NSURL *final = [self compiledURL:entry];
    [files removeItemAtURL:final error:nil];
    NSError *moveError = nil;
    if (![files moveItemAtURL:compiledURL toURL:final error:&moveError]) {
        [files removeItemAtURL:staging error:nil];
        return [self fail:entry reason:[@"store: " stringByAppendingString:moveError.localizedDescription ?: @"?"]];
    }
    [final setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    [files removeItemAtURL:staging error:nil];
    [_lock lock];
    entry.state = AUModelReady;
    entry.progress = 1;
    [_lock unlock];
    AULog(@"model %@ v%ld ready: %@ fetched in %.0f ms, compiled in %.0f ms, %@ on disk", entry.modelID, (long)entry.version,
          AUBytes(manifest.size), downloadMs, (CACurrentMediaTime() - compileStarted) * 1000, AUBytes([self bytesOnDiskOf:entry.modelID]));
    [self changed:entry];
}

- (NSData *)syncData:(NSURL *)url error:(NSString **)error {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *result = nil;
    __block NSString *failure = nil;
    [[_session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *e) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (status == 200 && data.length) result = data;
        else failure = e.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)status];
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (error) *error = failure;
    return result;
}

- (BOOL)syncDownload:(NSURL *)url to:(NSURL *)target error:(NSString **)error {
    for (int attempt = 0; attempt < 3; attempt++) {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL ok = NO;
        __block NSString *failure = nil;
        [[_session downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *e) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (location && status == 200) {
                [NSFileManager.defaultManager removeItemAtURL:target error:nil];
                NSError *moveError = nil;
                ok = [NSFileManager.defaultManager moveItemAtURL:location toURL:target error:&moveError];
                if (!ok) failure = moveError.localizedDescription;
            } else {
                failure = e.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)status];
            }
            dispatch_semaphore_signal(done);
        }] resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (ok) return YES;
        if (error) *error = failure;
        [NSThread sleepForTimeInterval:1.5 * (attempt + 1)];
    }
    return NO;
}

#pragma mark - load and unload

- (MLModel *)modelFor:(NSString *)modelID {
    AUModelEntry *entry = [self entry:modelID];
    if (!entry) return nil;
    [_lock lock];
    MLModel *model = entry.loaded;
    AUModelState state = entry.state;
    if (model) entry.lastUse = CACurrentMediaTime();
    [_lock unlock];
    if (model) return model;
    if (state != AUModelReady) {
        if (state == AUModelMissing) [self ensure:modelID];
        return nil;
    }
    CFTimeInterval started = CACurrentMediaTime();
    MLModelConfiguration *configuration = [MLModelConfiguration new];
    // CPU and Neural Engine for all: LaMa's Fourier matrices carry their own scale now, so its fp16 sums stay small
    // (summed first and scaled after they overflowed into noise on the phone); the GPU is not there for a
    // backgrounded app, which is when a locked phone moves to the next track.
    configuration.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
    NSError *error = nil;
    model = [MLModel modelWithContentsOfURL:[self compiledURL:entry] configuration:configuration error:&error];
    if (!model) {
        AULog(@"model %@ failed to load: %@; it is fetched again", modelID, error.localizedDescription);
        [NSFileManager.defaultManager removeItemAtURL:[self compiledURL:entry] error:nil];
        [_lock lock];
        entry.state = AUModelMissing;
        [_lock unlock];
        [self changed:entry];
        return nil;
    }
    double ms = (CACurrentMediaTime() - started) * 1000;
    AUStatRecord([@"load." stringByAppendingString:modelID], ms);
    AULog(@"model %@ loaded in %.0f ms (CPU + Neural Engine), footprint %@", modelID, ms, AUBytes(AUFootprint()));
    [_lock lock];
    if (!entry.loaded) entry.loaded = model;
    model = entry.loaded;
    entry.lastUse = CACurrentMediaTime();
    [_lock unlock];
    [self changed:entry];
    return model;
}

- (void)unloadIdle {
    CFTimeInterval now = CACurrentMediaTime();
    [_lock lock];
    NSMutableArray *dropped = [NSMutableArray array];
    for (AUModelEntry *entry in _entries.allValues) {
        if (entry.loaded && now - entry.lastUse > entry.idle) {
            entry.loaded = nil;
            [dropped addObject:entry.modelID];
        }
    }
    [_lock unlock];
    if (dropped.count) AULog(@"models unloaded when idle: %@", [dropped componentsJoinedByString:@", "]);
}

- (void)unloadAll {
    [_lock lock];
    for (AUModelEntry *entry in _entries.allValues) entry.loaded = nil;
    [_lock unlock];
}

- (void)memoryWarning {
    AULog(@"memory warning at %@: models unloaded", AUBytes(AUFootprint()));
    [self unloadAll];
}

- (void)deleteAll {
    [self unloadAll];
    [_lock lock];
    for (AUModelEntry *entry in _entries.allValues) {
        if (entry.state == AUModelDownloading || entry.state == AUModelCompiling) continue;
        [NSFileManager.defaultManager removeItemAtURL:[self compiledURL:entry] error:nil];
        entry.state = AUModelMissing;
        entry.progress = 0;
    }
    [_lock unlock];
    for (AUModelEntry *entry in _entries.allValues) [self changed:entry];
    AULog(@"models deleted");
}

@end
