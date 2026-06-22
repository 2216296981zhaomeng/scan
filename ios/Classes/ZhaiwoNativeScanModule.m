#import "ZhaiwoNativeScanModule.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>

static NSInteger const ZWScanCodeCancel = 10;
static NSInteger const ZWScanCodeError = 11;
static NSInteger const ZWScanCodeSuccess = 1000;

@interface ZhaiwoScanViewController : UIViewController <AVCaptureMetadataOutputObjectsDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>

@property (nonatomic, copy) NSDictionary *options;
@property (nonatomic, copy) UniModuleKeepAliveCallback callback;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, assign) BOOL completed;
@property (nonatomic, strong) UILabel *tipLabel;
@property (nonatomic, strong) UIButton *torchButton;
@property (nonatomic, strong) NSDictionary *lastAlbumDebug;
@property (nonatomic, copy) NSString *lastAlbumImageSource;

@end

@interface ZhaiwoNativeScanModule ()

@property (nonatomic, weak) ZhaiwoScanViewController *scanController;

@end

@implementation ZhaiwoNativeScanModule

UNI_EXPORT_METHOD(@selector(mpaasScan:callback:))
UNI_EXPORT_METHOD(@selector(scan:callback:))

- (void)mpaasScan:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self startScan:options callback:callback];
}

- (void)scan:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self startScan:options callback:callback];
}

- (void)startScan:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = [self topViewController];
        if (!presenter) {
            [self invoke:callback result:[self error:@"ViewController unavailable" reason:@"noViewController"]];
            return;
        }
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
            [self invoke:callback result:[self error:@"Camera permission denied" reason:@"cameraDenied"]];
            return;
        }
        if (status == AVAuthorizationStatusNotDetermined) {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!granted) {
                        [self invoke:callback result:[self error:@"Camera permission denied" reason:@"cameraDenied"]];
                        return;
                    }
                    [self presentScanner:options callback:callback from:presenter];
                });
            }];
            return;
        }
        [self presentScanner:options callback:callback from:presenter];
    });
}

- (void)presentScanner:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback from:(UIViewController *)presenter {
    ZhaiwoScanViewController *vc = [[ZhaiwoScanViewController alloc] init];
    vc.options = [options isKindOfClass:[NSDictionary class]] ? options : @{};
    vc.callback = callback;
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    self.scanController = vc;
    [presenter presentViewController:vc animated:YES completion:nil];
}

- (UIViewController *)topViewController {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *item in windowScene.windows) {
                if (item.isKeyWindow) {
                    window = item;
                    break;
                }
            }
            if (window) {
                break;
            }
        }
    }
    if (!window) {
        window = UIApplication.sharedApplication.keyWindow;
    }
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    if ([top isKindOfClass:UINavigationController.class]) {
        top = ((UINavigationController *)top).topViewController;
    }
    if ([top isKindOfClass:UITabBarController.class]) {
        top = ((UITabBarController *)top).selectedViewController;
    }
    return top;
}

- (NSDictionary *)error:(NSString *)message reason:(NSString *)reason {
    return @{
        @"resp_code": @(ZWScanCodeError),
        @"resp_message": message ?: @"scan failed",
        @"resp_result": @"",
        @"source": @"Zhaiwo-NativeScan-iOS",
        @"reason": reason ?: @"error",
        @"canFallback": @YES
    };
}

- (NSDictionary *)error:(NSString *)message reason:(NSString *)reason debug:(NSDictionary *)debug {
    NSMutableDictionary *result = [[self error:message reason:reason] mutableCopy];
    if (debug) {
        result[@"debug"] = debug;
    }
    return result;
}

- (void)invoke:(UniModuleKeepAliveCallback)callback result:(NSDictionary *)result {
    if (callback) {
        callback(result, NO);
    }
}

@end

@implementation ZhaiwoScanViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    [self setupCamera];
    [self setupOverlay];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.session && !self.session.isRunning) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self.session startRunning];
        });
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopSession];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.previewLayer.frame = self.view.bounds;
}

- (void)setupCamera {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device) {
        [self finishWithResult:[self error:@"Camera unavailable" reason:@"cameraUnavailable"]];
        return;
    }
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input || error) {
        [self finishWithResult:[self error:error.localizedDescription ?: @"Camera input failed" reason:@"cameraInputFailed"]];
        return;
    }
    AVCaptureMetadataOutput *output = [[AVCaptureMetadataOutput alloc] init];
    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    if ([session canSetSessionPreset:AVCaptureSessionPresetHigh]) {
        session.sessionPreset = AVCaptureSessionPresetHigh;
    }
    if (![session canAddInput:input] || ![session canAddOutput:output]) {
        [self finishWithResult:[self error:@"Scanner setup failed" reason:@"setupFailed"]];
        return;
    }
    [session addInput:input];
    [session addOutput:output];
    [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
    output.metadataObjectTypes = [self supportedMetadataTypes:output.availableMetadataObjectTypes];
    self.session = session;
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:session];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.previewLayer.frame = self.view.bounds;
    [self.view.layer insertSublayer:self.previewLayer atIndex:0];
}

- (void)setupOverlay {
    UIVisualEffectView *topBar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    topBar.frame = CGRectMake(0, 0, self.view.bounds.size.width, 96);
    topBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:topBar];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(16, 44, 64, 40);
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    [cancel setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(cancelScan) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:cancel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(90, 44, self.view.bounds.size.width - 180, 40)];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    title.text = [self stringOption:@"title" fallback:@"扫码"];
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    CGFloat width = MIN(self.view.bounds.size.width - 72, 300);
    UIView *frame = [[UIView alloc] initWithFrame:CGRectMake((self.view.bounds.size.width - width) / 2.0, 180, width, width)];
    frame.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    frame.layer.borderWidth = 2;
    frame.layer.borderColor = [UIColor colorWithRed:0.47 green:0.88 blue:0.83 alpha:1].CGColor;
    frame.layer.cornerRadius = 12;
    [self.view addSubview:frame];

    self.tipLabel = [[UILabel alloc] initWithFrame:CGRectMake(28, CGRectGetMaxY(frame.frame) + 24, self.view.bounds.size.width - 56, 50)];
    self.tipLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tipLabel.text = [self stringOption:@"viewText" fallback:@"请对准二维码或条形码，保持画面清晰"];
    self.tipLabel.textColor = UIColor.whiteColor;
    self.tipLabel.font = [UIFont systemFontOfSize:15];
    self.tipLabel.textAlignment = NSTextAlignmentCenter;
    self.tipLabel.numberOfLines = 2;
    [self.view addSubview:self.tipLabel];

    self.torchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.torchButton.frame = CGRectMake(40, self.view.bounds.size.height - 92, 124, 48);
    self.torchButton.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.torchButton setTitle:[self stringOption:@"openTorchText" fallback:@"打开手电筒"] forState:UIControlStateNormal];
    [self.torchButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.torchButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.38];
    self.torchButton.layer.cornerRadius = 24;
    [self.torchButton addTarget:self action:@selector(toggleTorch) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.torchButton];

    if (![self boolOption:@"hideAlbum" fallback:NO]) {
        UIButton *album = [UIButton buttonWithType:UIButtonTypeSystem];
        album.frame = CGRectMake(self.view.bounds.size.width - 164, self.view.bounds.size.height - 92, 124, 48);
        album.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin;
        [album setTitle:@"相册" forState:UIControlStateNormal];
        [album setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        album.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.38];
        album.layer.cornerRadius = 24;
        [album addTarget:self action:@selector(openAlbum) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:album];
    }
}

- (NSArray<AVMetadataObjectType> *)supportedMetadataTypes:(NSArray<AVMetadataObjectType> *)available {
    NSMutableArray *types = [NSMutableArray array];
    NSArray *wanted = @[
        AVMetadataObjectTypeQRCode,
        AVMetadataObjectTypeEAN13Code,
        AVMetadataObjectTypeEAN8Code,
        AVMetadataObjectTypeUPCECode,
        AVMetadataObjectTypeCode128Code,
        AVMetadataObjectTypeCode39Code,
        AVMetadataObjectTypeCode39Mod43Code,
        AVMetadataObjectTypeCode93Code,
        AVMetadataObjectTypeInterleaved2of5Code,
        AVMetadataObjectTypeITF14Code,
        AVMetadataObjectTypePDF417Code,
        AVMetadataObjectTypeDataMatrixCode,
        AVMetadataObjectTypeAztecCode
    ];
    for (AVMetadataObjectType type in wanted) {
        if ([available containsObject:type]) {
            [types addObject:type];
        }
    }
    return types.count ? types : available;
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    if (self.completed) {
        return;
    }
    for (AVMetadataObject *object in metadataObjects) {
        if (![object isKindOfClass:AVMetadataMachineReadableCodeObject.class]) {
            continue;
        }
        NSString *value = ((AVMetadataMachineReadableCodeObject *)object).stringValue;
        if (value.length > 0) {
            [self finishWithResult:[self success:value]];
            return;
        }
    }
}

- (void)toggleTorch {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device.hasTorch) {
        return;
    }
    NSError *error = nil;
    if (![device lockForConfiguration:&error]) {
        return;
    }
    device.torchMode = device.torchMode == AVCaptureTorchModeOn ? AVCaptureTorchModeOff : AVCaptureTorchModeOn;
    NSString *title = device.torchMode == AVCaptureTorchModeOn ? [self stringOption:@"closeTorchText" fallback:@"关闭手电筒"] : [self stringOption:@"openTorchText" fallback:@"打开手电筒"];
    [self.torchButton setTitle:title forState:UIControlStateNormal];
    [device unlockForConfiguration];
}

- (void)openAlbum {
    [self stopSession];
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
        [self finishWithResult:[self error:@"Photo library unavailable" reason:@"photoLibraryUnavailable"]];
        return;
    }

    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    if (status == PHAuthorizationStatusDenied || status == PHAuthorizationStatusRestricted) {
        [self finishWithResult:[self error:@"Photo library permission denied" reason:@"photoLibraryDenied"]];
        return;
    }
    if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus newStatus) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (newStatus == PHAuthorizationStatusDenied || newStatus == PHAuthorizationStatusRestricted) {
                    [self finishWithResult:[self error:@"Photo library permission denied" reason:@"photoLibraryDenied"]];
                    return;
                }
                [self presentAlbumPicker];
            });
        }];
        return;
    }

    [self presentAlbumPicker];
}

- (void)presentAlbumPicker {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:^{
        if (self.session && !self.session.isRunning) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self.session startRunning];
            });
        }
    }];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    UIImage *image = [self bestImageFromPickerInfo:info];
    NSString *value = [self scanImage:image];
    NSDictionary *debug = self.lastAlbumDebug ?: @{};
    [picker dismissViewControllerAnimated:YES completion:^{
        if (value.length > 0) {
            [self finishWithResult:[self success:value]];
        } else {
            [self finishWithResult:[self error:@"No scan result" reason:@"emptyResult" debug:debug]];
        }
    }];
}

- (UIImage *)bestImageFromPickerInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    self.lastAlbumImageSource = @"";

    if (@available(iOS 11.0, *)) {
        id imageURL = info[UIImagePickerControllerImageURL];
        if ([imageURL isKindOfClass:NSURL.class]) {
            UIImage *urlImage = [UIImage imageWithContentsOfFile:((NSURL *)imageURL).path];
            if (urlImage && urlImage.CGImage) {
                self.lastAlbumImageSource = @"imageURL";
                return urlImage;
            }
        }
    }

    if (@available(iOS 11.0, *)) {
        id asset = info[UIImagePickerControllerPHAsset];
        if ([asset isKindOfClass:PHAsset.class]) {
            UIImage *dataImage = [self imageDataFromPhotoAsset:(PHAsset *)asset];
            if (dataImage && dataImage.CGImage) {
                self.lastAlbumImageSource = @"phAssetData";
                return dataImage;
            }

            UIImage *assetImage = [self imageFromPhotoAsset:(PHAsset *)asset];
            if (assetImage && assetImage.CGImage) {
                self.lastAlbumImageSource = @"phAssetImage";
                return assetImage;
            }
        }
    }

    id originalImage = info[UIImagePickerControllerOriginalImage];
    if ([originalImage isKindOfClass:UIImage.class]) {
        self.lastAlbumImageSource = @"originalImage";
        return originalImage;
    }

    id editedImage = info[UIImagePickerControllerEditedImage];
    if ([editedImage isKindOfClass:UIImage.class]) {
        self.lastAlbumImageSource = @"editedImage";
        return editedImage;
    }
    return nil;
}

- (UIImage *)imageDataFromPhotoAsset:(PHAsset *)asset {
    __block NSData *data = nil;
    PHImageRequestOptions *options = [[PHImageRequestOptions alloc] init];
    options.synchronous = YES;
    options.networkAccessAllowed = YES;
    options.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
    options.resizeMode = PHImageRequestOptionsResizeModeNone;

    if (@available(iOS 13.0, *)) {
        [[PHImageManager defaultManager] requestImageDataAndOrientationForAsset:asset
                                                                        options:options
                                                                  resultHandler:^(NSData * _Nullable imageData, NSString * _Nullable dataUTI, CGImagePropertyOrientation orientation, NSDictionary * _Nullable info) {
            if (imageData.length > 0) {
                data = imageData;
            }
        }];
    } else {
        [[PHImageManager defaultManager] requestImageDataForAsset:asset
                                                          options:options
                                                    resultHandler:^(NSData * _Nullable imageData, NSString * _Nullable dataUTI, UIImageOrientation orientation, NSDictionary * _Nullable info) {
            if (imageData.length > 0) {
                data = imageData;
            }
        }];
    }

    if (data.length == 0) {
        return nil;
    }
    return [UIImage imageWithData:data];
}

- (UIImage *)imageFromPhotoAsset:(PHAsset *)asset {
    __block UIImage *image = nil;
    PHImageRequestOptions *options = [[PHImageRequestOptions alloc] init];
    options.synchronous = YES;
    options.networkAccessAllowed = YES;
    options.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
    options.resizeMode = PHImageRequestOptionsResizeModeNone;
    [[PHImageManager defaultManager] requestImageForAsset:asset
                                               targetSize:PHImageManagerMaximumSize
                                              contentMode:PHImageContentModeDefault
                                                  options:options
                                            resultHandler:^(UIImage * _Nullable result, NSDictionary * _Nullable info) {
        if (result && result.CGImage) {
            image = result;
        }
    }];
    return image;
}

- (NSString *)scanImage:(UIImage *)image {
    NSMutableDictionary *debug = [NSMutableDictionary dictionary];
    debug[@"imagePicked"] = @(image != nil);
    if (!image.CGImage) {
        debug[@"imageHasCGImage"] = @NO;
        self.lastAlbumDebug = debug;
        return @"";
    }

    debug[@"imageHasCGImage"] = @YES;
    debug[@"imageSize"] = @{ @"width": @(image.size.width), @"height": @(image.size.height), @"scale": @(image.scale) };
    debug[@"cgImageSize"] = @{ @"width": @(CGImageGetWidth(image.CGImage)), @"height": @(CGImageGetHeight(image.CGImage)) };
    debug[@"orientation"] = @(image.imageOrientation);
    debug[@"albumImageSource"] = self.lastAlbumImageSource ?: @"";

    NSArray<UIImage *> *candidates = [self scanCandidateImages:image];
    NSMutableArray *candidateSizes = [NSMutableArray array];
    NSInteger totalVisionObservations = 0;
    NSMutableArray *visionErrors = [NSMutableArray array];
    debug[@"candidateCount"] = @(candidates.count);

    for (UIImage *candidate in candidates) {
        if (!candidate.CGImage) {
            continue;
        }
        [candidateSizes addObject:@{
            @"width": @(candidate.size.width),
            @"height": @(candidate.size.height),
            @"cgWidth": @(CGImageGetWidth(candidate.CGImage)),
            @"cgHeight": @(CGImageGetHeight(candidate.CGImage)),
            @"orientation": @(candidate.imageOrientation)
        }];

        NSInteger observationCount = 0;
        NSString *visionError = @"";
        NSString *visionValue = [self scanImageWithVision:candidate observationCount:&observationCount errorMessage:&visionError];
        totalVisionObservations += observationCount;
        if (visionError.length > 0) {
            [visionErrors addObject:visionError];
        }
        if (visionValue.length > 0) {
            self.lastAlbumDebug = debug;
            return visionValue;
        }
        NSString *coreImageValue = [self scanQRCodeWithCoreImage:candidate];
        if (coreImageValue.length > 0) {
            self.lastAlbumDebug = debug;
            return coreImageValue;
        }
    }

    debug[@"candidateSizes"] = candidateSizes;
    debug[@"visionObservationCount"] = @(totalVisionObservations);
    debug[@"visionErrors"] = visionErrors;
    self.lastAlbumDebug = debug;
    return @"";
}

- (NSArray<UIImage *> *)scanCandidateImages:(UIImage *)image {
    NSMutableArray<UIImage *> *images = [NSMutableArray array];
    [self addScanImage:image toArray:images];

    UIImage *normalized = [self scaledScanImage:image minPixel:0.0 maxPixel:4096.0 interpolation:kCGInterpolationHigh];
    [self addScanImage:normalized toArray:images];

    UIImage *upscaled = [self scaledScanImage:image minPixel:1600.0 maxPixel:4096.0 interpolation:kCGInterpolationNone];
    [self addScanImage:upscaled toArray:images];

    UIImage *large = [self scaledScanImage:image minPixel:2400.0 maxPixel:4096.0 interpolation:kCGInterpolationNone];
    [self addScanImage:large toArray:images];

    NSMutableArray<UIImage *> *baseImages = [images copy].mutableCopy;
    for (UIImage *base in baseImages) {
        UIImage *enhanced = [self contrastScanImage:base];
        [self addScanImage:enhanced toArray:images];

        UIImage *threshold = [self thresholdScanImage:base threshold:0.55];
        [self addScanImage:threshold toArray:images];

        UIImage *rotatedRight = [self image:base rotatedByRadians:M_PI_2];
        UIImage *rotatedDown = [self image:base rotatedByRadians:M_PI];
        UIImage *rotatedLeft = [self image:base rotatedByRadians:-M_PI_2];
        [self addScanImage:rotatedRight toArray:images];
        [self addScanImage:rotatedDown toArray:images];
        [self addScanImage:rotatedLeft toArray:images];
    }
    return images;
}

- (void)addScanImage:(UIImage *)image toArray:(NSMutableArray<UIImage *> *)images {
    if (image && image.CGImage) {
        [images addObject:image];
    }
}

- (UIImage *)scaledScanImage:(UIImage *)image minPixel:(CGFloat)minPixel maxPixel:(CGFloat)maxPixel interpolation:(CGInterpolationQuality)quality {
    if (!image.CGImage) {
        return nil;
    }
    CGSize size = image.size;
    CGFloat largest = MAX(size.width, size.height);
    CGFloat scale = 1.0;
    if (minPixel > 0 && largest < minPixel) {
        scale = minPixel / MAX(largest, 1.0);
    }
    if (largest * scale > maxPixel) {
        scale = maxPixel / MAX(largest, 1.0);
    }
    CGSize targetSize = CGSizeMake(MAX(1.0, floor(size.width * scale)), MAX(1.0, floor(size.height * scale)));

    UIGraphicsBeginImageContextWithOptions(targetSize, YES, 1.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetInterpolationQuality(context, quality);
    [image drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return normalized;
}

- (UIImage *)contrastScanImage:(UIImage *)image {
    if (!image.CGImage) {
        return nil;
    }
    CIImage *input = [[CIImage alloc] initWithCGImage:image.CGImage];
    CIFilter *color = [CIFilter filterWithName:@"CIColorControls"];
    [color setValue:input forKey:kCIInputImageKey];
    [color setValue:@0 forKey:kCIInputSaturationKey];
    [color setValue:@1.8 forKey:kCIInputContrastKey];
    [color setValue:@0.02 forKey:kCIInputBrightnessKey];
    CIImage *output = color.outputImage;
    if (!output) {
        return nil;
    }

    CIFilter *sharp = [CIFilter filterWithName:@"CISharpenLuminance"];
    [sharp setValue:output forKey:kCIInputImageKey];
    [sharp setValue:@0.7 forKey:kCIInputSharpnessKey];
    output = sharp.outputImage ?: output;

    CIContext *context = [CIContext contextWithOptions:nil];
    CGImageRef cgImage = [context createCGImage:output fromRect:output.extent];
    if (!cgImage) {
        return nil;
    }
    UIImage *result = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return result;
}

- (UIImage *)thresholdScanImage:(UIImage *)image threshold:(CGFloat)threshold {
    if (!image.CGImage) {
        return nil;
    }
    size_t width = CGImageGetWidth(image.CGImage);
    size_t height = CGImageGetHeight(image.CGImage);
    if (width == 0 || height == 0) {
        return nil;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width, colorSpace, kCGImageAlphaNone);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        return nil;
    }

    CGContextSetInterpolationQuality(context, kCGInterpolationNone);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image.CGImage);
    unsigned char *data = CGBitmapContextGetData(context);
    size_t bytesPerRow = CGBitmapContextGetBytesPerRow(context);
    unsigned char thresholdByte = (unsigned char)MAX(0, MIN(255, threshold * 255.0));
    if (data) {
        for (size_t y = 0; y < height; y++) {
            unsigned char *row = data + y * bytesPerRow;
            for (size_t x = 0; x < width; x++) {
                row[x] = row[x] > thresholdByte ? 255 : 0;
            }
        }
    }

    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!cgImage) {
        return nil;
    }
    UIImage *result = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return result;
}

- (UIImage *)image:(UIImage *)image rotatedByRadians:(CGFloat)radians {
    if (!image.CGImage) {
        return nil;
    }
    CGRect rect = CGRectMake(0, 0, image.size.width, image.size.height);
    CGRect rotatedRect = CGRectApplyAffineTransform(rect, CGAffineTransformMakeRotation(radians));
    CGSize rotatedSize = CGSizeMake(fabs(rotatedRect.size.width), fabs(rotatedRect.size.height));

    UIGraphicsBeginImageContextWithOptions(rotatedSize, YES, 1.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, rotatedSize.width / 2.0, rotatedSize.height / 2.0);
    CGContextRotateCTM(context, radians);
    [image drawInRect:CGRectMake(-image.size.width / 2.0, -image.size.height / 2.0, image.size.width, image.size.height)];
    UIImage *rotated = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return rotated;
}

- (NSString *)scanQRCodeWithCoreImage:(UIImage *)image {
    if (!image.CGImage) {
        return @"";
    }
    CIImage *ciImage = [[CIImage alloc] initWithCGImage:image.CGImage];
    CIDetector *detector = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
    NSArray<CIFeature *> *features = [detector featuresInImage:ciImage];
    for (CIFeature *feature in features) {
        if ([feature isKindOfClass:CIQRCodeFeature.class]) {
            NSString *value = ((CIQRCodeFeature *)feature).messageString;
            if (value.length > 0) {
                return value;
            }
        }
    }
    return @"";
}

- (NSString *)scanImageWithVision:(UIImage *)image observationCount:(NSInteger *)observationCount errorMessage:(NSString **)errorMessage {
    if (observationCount) {
        *observationCount = 0;
    }
    if (errorMessage) {
        *errorMessage = @"";
    }
    if (@available(iOS 11.0, *)) {
        __block NSString *result = @"";
        __block NSInteger count = 0;
        __block NSString *requestError = @"";
        VNDetectBarcodesRequest *request = [[VNDetectBarcodesRequest alloc] initWithCompletionHandler:^(VNRequest * _Nonnull request, NSError * _Nullable error) {
            if (error) {
                requestError = error.localizedDescription ?: @"Vision barcode request failed";
                return;
            }
            count = request.results.count;
            for (VNObservation *observation in request.results) {
                if (![observation isKindOfClass:VNBarcodeObservation.class]) {
                    continue;
                }
                NSString *value = ((VNBarcodeObservation *)observation).payloadStringValue;
                if (value.length > 0) {
                    result = value;
                    break;
                }
            }
        }];
        @try {
            NSArray<VNBarcodeSymbology> *symbologies = [self supportedVisionBarcodeSymbologiesForRequest:request];
            if (symbologies.count > 0) {
                request.symbologies = symbologies;
            }
        } @catch (NSException *exception) {
            requestError = exception.reason ?: exception.name;
        }
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage orientation:[self cgImageOrientationFromImageOrientation:image.imageOrientation] options:@{}];
        NSError *error = nil;
        [handler performRequests:@[request] error:&error];
        if (observationCount) {
            *observationCount = count;
        }
        if (errorMessage) {
            *errorMessage = requestError.length > 0 ? requestError : (error.localizedDescription ?: @"");
        }
        return result ?: @"";
    }
    if (errorMessage) {
        *errorMessage = @"Vision requires iOS 11.0+";
    }
    return @"";
}

- (NSArray<VNBarcodeSymbology> *)supportedVisionBarcodeSymbologiesForRequest:(VNDetectBarcodesRequest *)request API_AVAILABLE(ios(11.0)) {
    NSArray<VNBarcodeSymbology> *wanted = @[
        VNBarcodeSymbologyQR,
        VNBarcodeSymbologyAztec,
        VNBarcodeSymbologyDataMatrix,
        VNBarcodeSymbologyPDF417,
        VNBarcodeSymbologyEAN13,
        VNBarcodeSymbologyEAN8,
        VNBarcodeSymbologyUPCE,
        VNBarcodeSymbologyCode39,
        VNBarcodeSymbologyCode39Checksum,
        VNBarcodeSymbologyCode39FullASCII,
        VNBarcodeSymbologyCode39FullASCIIChecksum,
        VNBarcodeSymbologyCode93,
        VNBarcodeSymbologyCode128,
        VNBarcodeSymbologyITF14,
        VNBarcodeSymbologyI2of5,
        VNBarcodeSymbologyI2of5Checksum
    ];

    if ([request respondsToSelector:@selector(supportedSymbologiesAndReturnError:)]) {
        NSError *error = nil;
        NSArray<VNBarcodeSymbology> *available = [request supportedSymbologiesAndReturnError:&error];
        if (available.count > 0) {
            NSMutableArray<VNBarcodeSymbology> *supported = [NSMutableArray array];
            for (VNBarcodeSymbology symbology in wanted) {
                if ([available containsObject:symbology]) {
                    [supported addObject:symbology];
                }
            }
            return supported.count > 0 ? supported : available;
        }
    }
    return wanted;
}

- (CGImagePropertyOrientation)cgImageOrientationFromImageOrientation:(UIImageOrientation)orientation {
    switch (orientation) {
        case UIImageOrientationUp:
            return kCGImagePropertyOrientationUp;
        case UIImageOrientationDown:
            return kCGImagePropertyOrientationDown;
        case UIImageOrientationLeft:
            return kCGImagePropertyOrientationLeft;
        case UIImageOrientationRight:
            return kCGImagePropertyOrientationRight;
        case UIImageOrientationUpMirrored:
            return kCGImagePropertyOrientationUpMirrored;
        case UIImageOrientationDownMirrored:
            return kCGImagePropertyOrientationDownMirrored;
        case UIImageOrientationLeftMirrored:
            return kCGImagePropertyOrientationLeftMirrored;
        case UIImageOrientationRightMirrored:
            return kCGImagePropertyOrientationRightMirrored;
    }
    return kCGImagePropertyOrientationUp;
}

- (void)cancelScan {
    [self finishWithResult:[self cancelResult]];
}

- (void)finishWithResult:(NSDictionary *)result {
    if (self.completed) {
        return;
    }
    self.completed = YES;
    [self stopSession];
    UniModuleKeepAliveCallback callback = self.callback;
    [self dismissViewControllerAnimated:YES completion:^{
        if (callback) {
            callback(result, NO);
        }
    }];
}

- (void)stopSession {
    if (self.session && self.session.isRunning) {
        [self.session stopRunning];
    }
}

- (NSDictionary *)success:(NSString *)text {
    return @{
        @"resp_code": @(ZWScanCodeSuccess),
        @"resp_message": @"success",
        @"resp_result": text ?: @"",
        @"result": text ?: @"",
        @"source": @"Zhaiwo-NativeScan-iOS"
    };
}

- (NSDictionary *)cancelResult {
    return @{
        @"resp_code": @(ZWScanCodeCancel),
        @"resp_message": @"cancel",
        @"resp_result": @"",
        @"source": @"Zhaiwo-NativeScan-iOS",
        @"canFallback": @NO
    };
}

- (NSDictionary *)error:(NSString *)message reason:(NSString *)reason {
    return @{
        @"resp_code": @(ZWScanCodeError),
        @"resp_message": message ?: @"scan failed",
        @"resp_result": @"",
        @"source": @"Zhaiwo-NativeScan-iOS",
        @"reason": reason ?: @"error",
        @"canFallback": @YES
    };
}

- (NSDictionary *)error:(NSString *)message reason:(NSString *)reason debug:(NSDictionary *)debug {
    NSMutableDictionary *result = [[self error:message reason:reason] mutableCopy];
    if (debug) {
        result[@"debug"] = debug;
    }
    return result;
}

- (NSString *)stringOption:(NSString *)key fallback:(NSString *)fallback {
    id value = self.options[key];
    if ([value isKindOfClass:NSString.class] && [value length] > 0) {
        return value;
    }
    return fallback ?: @"";
}

- (BOOL)boolOption:(NSString *)key fallback:(BOOL)fallback {
    id value = self.options[key];
    if ([value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    return fallback;
}

@end
