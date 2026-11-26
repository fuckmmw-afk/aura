#import "AUVideoCover.h"
#import "Core/AUCore.h"
#import "Core/AUTaurus.h"
#import <Accelerate/Accelerate.h>

NSNotificationName const AUVideoCoverDidChangeNotification = @"AUVideoCoverDidChangeNotification";

static const double kMaxSeconds = 40;    // a video cover is a short loop; anything longer is a clip or a song
static const double kClipSeconds = 15;   // what goes to the lock screen at most

static NSMutableDictionary<NSString *, AVURLAsset *> *sVideos;   // track URI -> its video
static NSMutableArray<NSString *> *sOrder;
static NSHashTable<AVAsset *> *sChecked;

static void remember(NSString *uri, AVURLAsset *asset) {
    if (!sVideos) {
        sVideos = [NSMutableDictionary dictionary];
        sOrder = [NSMutableArray array];
    }
    AVURLAsset *known = sVideos[uri];
    if ([known.URL isEqual:asset.URL]) return;
    sVideos[uri] = asset;
    [sOrder removeObject:uri];
    [sOrder addObject:uri];
    while (sOrder.count > 24) {
        [sVideos removeObjectForKey:sOrder.firstObject];
        [sOrder removeObjectAtIndex:0];
    }
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AULog(@"video cover for %@: %.0f x %.0f, %.1f s, %@", [uri substringFromIndex:uri.length > 8 ? uri.length - 8 : 0], track.naturalSize.width,
          track.naturalSize.height, CMTimeGetSeconds(asset.duration), asset.URL.isFileURL ? @"a local file" : asset.URL.host ?: asset.URL.scheme);
    [NSNotificationCenter.defaultCenter postNotificationName:AUVideoCoverDidChangeNotification object:nil userInfo:@{@"uri": uri}];
}

void AUVideoCoverPlayerStarted(AVPlayer *player) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ AUVideoCoverPlayerStarted(player); });
        return;
    }
    AVURLAsset *asset = (AVURLAsset *)player.currentItem.asset;
    if (![asset isKindOfClass:AVURLAsset.class]) return;
    if (!sChecked) sChecked = [NSHashTable weakObjectsHashTable];
    if ([sChecked containsObject:asset]) return;
    [sChecked addObject:asset];
    NSString *uri = AUTaurusTrackURI();
    if (!uri.length) return;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
        NSError *error = nil;
        if ([asset statusOfValueForKey:@"tracks" error:&error] != AVKeyValueStatusLoaded) return;
        if (![asset tracksWithMediaType:AVMediaTypeVideo].count) return;   // the music itself
        double seconds = CMTimeGetSeconds(asset.duration);
        if (!(seconds > 0.5 && seconds <= kMaxSeconds)) {
            AULog(@"video cover: a %.0f s video is not a cover (a clip?), left alone", seconds);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            // Still the track that was playing when the video started.
            if (![AUTaurusTrackURI() isEqualToString:uri]) return;
            remember(uri, asset);
        });
    }];
}

AVURLAsset *AUVideoCoverFor(NSString *uri) {
    return uri.length ? sVideos[uri] : nil;
}

#pragma mark - the clip

// A remote file is fetched first (AVAssetReader reads local files and the app's own resource loaders, not the network).
static AVURLAsset *readable(AVURLAsset *asset) {
    NSURL *url = asset.URL;
    if (url.isFileURL) return asset;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) return asset;   // the app's own loader
    if ([url.pathExtension.lowercaseString isEqualToString:@"m3u8"]) {
        AULog(@"video cover: a stream (m3u8), cannot be read for the lock screen");
        return nil;
    }
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *folder = [[caches URLByAppendingPathComponent:@"Aura" isDirectory:YES] URLByAppendingPathComponent:@"Video" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *extension = url.pathExtension.length ? url.pathExtension : @"mp4";
    NSURL *local = [folder URLByAppendingPathComponent:[AUSHA1(url.absoluteString) stringByAppendingPathExtension:extension]];
    if (![NSFileManager.defaultManager fileExistsAtPath:local.path]) {
        __block NSData *data = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
            NSInteger code = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (code == 200 && body.length < 60 * 1024 * 1024) data = body;
            else AULog(@"video cover: download failed (%ld, %@)", (long)code, error.localizedDescription ?: @"-");
            dispatch_semaphore_signal(done);
        }];
        [task resume];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)));
        if (!data || ![data writeToURL:local atomically:YES]) return nil;
    }
    return [AVURLAsset URLAssetWithURL:local options:nil];
}

// The quarter turns the track's preferred transform asks for.
static int quarterTurns(CGAffineTransform t) {
    double angle = atan2(t.b, t.a);
    int turns = (int)lround(angle / M_PI_2);
    return ((turns % 4) + 4) % 4;
}

BOOL AUVideoCoverWrite(AVURLAsset *source, NSURL *file, CGSize size, UIImage **poster) {
    double started = AUNowMs();
    AVURLAsset *asset = readable(source);
    if (!asset) return NO;
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) {
        AULog(@"video cover: no video track to read");
        return NO;
    }
    NSError *error = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    }];
    output.alwaysCopiesSampleData = NO;
    if (!reader || ![reader canAddOutput:output]) {
        AULog(@"video cover: cannot read it: %@", error.localizedDescription ?: @"?");
        return NO;
    }
    [reader addOutput:output];
    reader.timeRange = CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(kClipSeconds, 600));
    if (![reader startReading]) {
        AULog(@"video cover: reading would not start: %@", reader.error.localizedDescription ?: @"?");
        return NO;
    }

    int32_t width = (int32_t)size.width, height = (int32_t)size.height;
    NSURL *partial = [file URLByAppendingPathExtension:@"partial.mp4"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    float fps = track.nominalFrameRate > 1 ? track.nominalFrameRate : 30;
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(6000000), AVVideoMaxKeyFrameIntervalKey: @((int)lroundf(fps))},
    }];
    input.expectsMediaDataInRealTime = NO;
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
        }];
    if (!writer || ![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) {
        AULog(@"video cover: the writer would not start: %@", writer.error.localizedDescription ?: @"?");
        [reader cancelReading];
        return NO;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    int turns = quarterTurns(track.preferredTransform);
    NSMutableData *turned = nil;
    BOOL ok = YES, first = YES;
    CMTime start = kCMTimeInvalid, last = kCMTimeZero;
    int frames = 0;
    while (ok) {
        @autoreleasepool {
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (!sample) break;
            CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
            CMTime time = CMSampleBufferGetPresentationTimeStamp(sample);
            if (!image) {
                CFRelease(sample);
                continue;
            }
            if (!CMTIME_IS_VALID(start)) start = time;
            CMTime at = CMTimeSubtract(time, start);
            CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
            vImage_Buffer src = {CVPixelBufferGetBaseAddress(image), CVPixelBufferGetHeight(image), CVPixelBufferGetWidth(image),
                                 CVPixelBufferGetBytesPerRow(image)};
            if (turns) {
                // Upright first: the turns of the preferred transform, on the CPU.
                BOOL side = turns % 2 == 1;
                size_t w = side ? src.height : src.width, h = side ? src.width : src.height;
                if (turned.length < w * h * 4) turned = [NSMutableData dataWithLength:w * h * 4];
                vImage_Buffer up = {turned.mutableBytes, h, w, w * 4};
                Pixel_8888 black = {0, 0, 0, 255};
                vImageRotate90_ARGB8888(&src, &up, (uint8_t)((4 - turns) % 4), black, kvImageNoFlags);
                src = up;
            }
            // Aspect fill: the middle of the picture at the clip's 3:4.
            double scale = MAX((double)width / src.width, (double)height / src.height);
            size_t cropW = MIN(src.width, (size_t)lround(width / scale)), cropH = MIN(src.height, (size_t)lround(height / scale));
            size_t x = (src.width - cropW) / 2, y = (src.height - cropH) / 2;
            vImage_Buffer crop = {(uint8_t *)src.data + y * src.rowBytes + x * 4, cropH, cropW, src.rowBytes};
            while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) [NSThread sleepForTimeInterval:0.002];
            CVPixelBufferRef buffer = NULL;
            ok = writer.status == AVAssetWriterStatusWriting && adaptor.pixelBufferPool
                && CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) == kCVReturnSuccess;
            if (ok) {
                CVPixelBufferLockBaseAddress(buffer, 0);
                vImage_Buffer dst = {CVPixelBufferGetBaseAddress(buffer), (vImagePixelCount)height, (vImagePixelCount)width, CVPixelBufferGetBytesPerRow(buffer)};
                vImageScale_ARGB8888(&crop, &dst, NULL, kvImageHighQualityResampling);
                if (first && poster) {
                    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                    CGContextRef c = CGBitmapContextCreate(dst.data, width, height, 8, dst.rowBytes, space,
                                                           kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
                    CGColorSpaceRelease(space);
                    CGImageRef cg = c ? CGBitmapContextCreateImage(c) : NULL;
                    if (cg) *poster = [UIImage imageWithCGImage:cg];
                    if (cg) CGImageRelease(cg);
                    if (c) CGContextRelease(c);
                }
                first = NO;
                CVPixelBufferUnlockBaseAddress(buffer, 0);
                ok = [adaptor appendPixelBuffer:buffer withPresentationTime:at];
                CVPixelBufferRelease(buffer);
                last = at;
                frames++;
            }
            CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
            CFRelease(sample);
        }
    }
    if (reader.status == AVAssetReaderStatusFailed) {
        AULog(@"video cover: reading failed: %@", reader.error.localizedDescription ?: @"?");
        ok = NO;
    }
    [reader cancelReading];
    if (!ok || frames < 2) {
        AULog(@"video cover: clip not written (%d frames): %@", frames, writer.error.localizedDescription ?: @"?");
        [writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [input markAsFinished];
    [writer endSessionAtSourceTime:CMTimeAdd(last, CMTimeMakeWithSeconds(1.0 / fps, 600))];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        AULog(@"video cover: clip not finished: %@", writer.error.localizedDescription ?: @"?");
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    BOOL moved = [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
    AULog(@"video cover: lock screen clip %dx%d, %d frames (%.1f s) in %.0f ms", width, height, frames, CMTimeGetSeconds(last), AUNowMs() - started);
    return moved;
}
