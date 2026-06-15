#import "OCRManager.h"
#import "ScreenManager.h"
#import "MCPLogger.h"
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>

#define OCR_LOG(fmt, ...) [MCPLogger log:@"[OCR] " fmt, ##__VA_ARGS__]

@implementation OCRManager

+ (instancetype)sharedInstance {
    static OCRManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[OCRManager alloc] init];
    });
    return instance;
}

static double OCRNum(NSDictionary *d, NSString *k) {
    id v = d[k];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0.0;
}

- (NSDictionary *)recognizeTextWithLanguages:(NSArray<NSString *> *)languages
                               minConfidence:(double)minConfidence
                                      region:(NSDictionary *)region
                                       error:(NSString **)error {
    if (error) *error = nil;

    if (@available(iOS 13.0, *)) {
        UIImage *image = [[ScreenManager sharedInstance] captureScreenImage];
        if (!image || !image.CGImage) {
            if (error) *error = @"Failed to capture screen for OCR";
            return nil;
        }

        // UIImage.size is in points and matches the screen's logical size; OCR results are
        // mapped back to these points so the returned rect/tap are tap_screen-ready.
        CGFloat W = image.size.width;
        CGFloat H = image.size.height;

        __block NSArray<VNRecognizedTextObservation *> *observations = nil;
        __block NSError *visionError = nil;

        VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *req, NSError *err) {
            visionError = err;
            observations = (NSArray<VNRecognizedTextObservation *> *)req.results;
        }];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.usesLanguageCorrection = YES;
        if (languages.count > 0) {
            request.recognitionLanguages = languages;
        } else {
            request.recognitionLanguages = @[@"zh-Hans", @"en-US"];
        }

        // Limit OCR to a region of interest if provided (Vision uses normalized, origin bottom-left).
        if ([region isKindOfClass:[NSDictionary class]] && region.count > 0 && W > 0 && H > 0) {
            double rx = OCRNum(region, @"x"), ry = OCRNum(region, @"y");
            double rw = OCRNum(region, @"width"), rh = OCRNum(region, @"height");
            if (rw > 0 && rh > 0) {
                double nx = rx / W;
                double nw = rw / W;
                double nh = rh / H;
                double ny = 1.0 - (ry + rh) / H; // flip Y
                request.regionOfInterest = CGRectMake(MAX(0, nx), MAX(0, ny), MIN(1, nw), MIN(1, nh));
            }
        }

        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage options:@{}];
        NSError *performError = nil;
        BOOL ok = [handler performRequests:@[request] error:&performError];
        if (!ok || visionError) {
            NSString *msg = (performError ?: visionError).localizedDescription ?: @"Vision OCR failed";
            if (error) *error = msg;
            OCR_LOG(@"failed: %@", msg);
            return nil;
        }

        NSMutableArray<NSDictionary *> *texts = [NSMutableArray array];
        for (VNRecognizedTextObservation *obs in observations) {
            VNRecognizedText *top = [[obs topCandidates:1] firstObject];
            if (!top) continue;
            double conf = top.confidence;
            if (conf < minConfidence) continue;

            NSString *str = top.string ?: @"";
            if (str.length == 0) continue;

            // boundingBox is normalized (0..1), origin bottom-left. Map to screen points.
            CGRect bb = obs.boundingBox;
            double x = bb.origin.x * W;
            double w = bb.size.width * W;
            double h = bb.size.height * H;
            double y = (1.0 - bb.origin.y - bb.size.height) * H; // flip Y to top-left origin

            int ix = (int)round(x), iy = (int)round(y);
            int iw = (int)round(w), ih = (int)round(h);

            [texts addObject:@{
                @"text": str,
                @"confidence": @(round(conf * 100) / 100.0),
                @"rect": @{@"x": @(ix), @"y": @(iy), @"width": @(iw), @"height": @(ih)},
                @"tap": @{@"x": @(ix + iw / 2), @"y": @(iy + ih / 2)}
            }];
        }

        OCR_LOG(@"ok count=%lu langs=%@", (unsigned long)texts.count, request.recognitionLanguages);
        return @{
            @"texts": texts,
            @"count": @(texts.count),
            @"screen": @{@"width": @((int)round(W)), @"height": @((int)round(H))}
        };
    }

    if (error) *error = @"OCR requires iOS 13 or later";
    return nil;
}

@end
