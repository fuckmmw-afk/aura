// A model's manifest on the server: every file of its .mlpackage with size and sha256. Foundation only (Mac tests).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One file of a model as its manifest lists it; parsed and checked here, the Mac tests read it too.
@interface AUManifestFile : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic) uint64_t size;
@property (nonatomic, copy) NSString *sha256;
@end

@interface AUManifest : NSObject
@property (nonatomic, copy) NSString *modelID, *package;
@property (nonatomic) NSInteger version;
@property (nonatomic) uint64_t size;
@property (nonatomic, copy) NSArray<AUManifestFile *> *files;
// nil when the JSON is not a manifest or a path would leave the model's folder.
+ (nullable instancetype)manifestWithData:(NSData *)data error:(NSString *_Nullable *_Nullable)error;
@end

NSString *AUSHA256OfFile(NSURL *url);

// "spotify:image:ab67…#exact" -> "spotify:image:ab67…", and whether it was the exact picture.
NSString *AUPictureKeyFromIdentity(NSString *identity, BOOL *_Nullable exact);

NS_ASSUME_NONNULL_END
