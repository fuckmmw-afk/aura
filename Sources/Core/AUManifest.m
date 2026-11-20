#import "AUManifest.h"
#import <CommonCrypto/CommonDigest.h>

#pragma mark - manifest

@implementation AUManifestFile
@end

@implementation AUManifest

+ (instancetype)manifestWithData:(NSData *)data error:(NSString **)error {
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error) *error = @"manifest is not a JSON object";
        return nil;
    }
    NSDictionary *root = json;
    AUManifest *manifest = [AUManifest new];
    manifest.modelID = [root[@"id"] isKindOfClass:NSString.class] ? root[@"id"] : nil;
    manifest.package = [root[@"package"] isKindOfClass:NSString.class] ? root[@"package"] : nil;
    manifest.version = [root[@"version"] respondsToSelector:@selector(integerValue)] ? [root[@"version"] integerValue] : 0;
    NSArray *files = [root[@"files"] isKindOfClass:NSArray.class] ? root[@"files"] : nil;
    if (!manifest.modelID.length || !manifest.package.length || ![manifest.package hasSuffix:@".mlpackage"] || !files.count) {
        if (error) *error = @"manifest lacks id, package or files";
        return nil;
    }
    NSMutableArray *parsed = [NSMutableArray array];
    uint64_t total = 0;
    for (NSDictionary *entry in files) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        AUManifestFile *file = [AUManifestFile new];
        file.path = [entry[@"path"] isKindOfClass:NSString.class] ? entry[@"path"] : @"";
        file.size = [entry[@"size"] respondsToSelector:@selector(unsignedLongLongValue)] ? [entry[@"size"] unsignedLongLongValue] : 0;
        file.sha256 = [entry[@"sha256"] isKindOfClass:NSString.class] ? [entry[@"sha256"] lowercaseString] : @"";
        BOOL inside = [file.path hasPrefix:[manifest.package stringByAppendingString:@"/"]] && ![file.path containsString:@".."]
            && ![file.path hasPrefix:@"/"] && ![file.path containsString:@"\\"];
        if (!inside || file.sha256.length != 64) {
            if (error) *error = [NSString stringWithFormat:@"bad file entry %@", file.path];
            return nil;
        }
        total += file.size;
        [parsed addObject:file];
    }
    manifest.files = parsed;
    manifest.size = total;
    return manifest;
}

@end

NSString *AUSHA256OfFile(NSURL *url) {
    NSInputStream *stream = [NSInputStream inputStreamWithURL:url];
    [stream open];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[64 * 1024];
    NSInteger read;
    while ((read = [stream read:buffer maxLength:sizeof(buffer)]) > 0) CC_SHA256_Update(&context, buffer, (CC_LONG)read);
    [stream close];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

NSString *AUPictureKeyFromIdentity(NSString *identity, BOOL *exact) {
    NSRange hash = [identity rangeOfString:@"#" options:NSBackwardsSearch];
    if (exact) *exact = hash.location != NSNotFound && [[identity substringFromIndex:hash.location] isEqualToString:@"#exact"];
    return hash.location == NSNotFound ? identity : [identity substringToIndex:hash.location];
}
